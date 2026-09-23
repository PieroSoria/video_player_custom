import 'dart:convert';
import 'dart:io';

import 'mini_xml.dart';

/// Downloads a whole MPEG-DASH presentation (`.mpd`) into a flat local
/// directory so the cached copy plays back offline.
///
/// `BaseURL` elements are resolved against the (post-redirect) manifest URL
/// and removed from the rewritten output; `SegmentTemplate`
/// media/initialization templates are expanded (following `SegmentTimeline`
/// or `duration`) and replaced by an explicit per-`Representation`
/// `<SegmentList>` pointing at local files. Quality ladder, roles and content
/// descriptors are preserved, so the local manifest still supports quality
/// switching.
///
/// Sources that cannot be cached offline (dynamic/live manifests,
/// `SegmentBase` byte-range addressing, oversized presentations) throw, which
/// the cache treats as "cannot be cached" — playback keeps streaming live.
class DashDownloader {
  DashDownloader({required this.entryDir, this.headers});

  /// Local directory that receives the manifest and every segment.
  final Directory entryDir;

  /// HTTP headers forwarded to every request made by this downloader.
  final Map<String, String>? headers;

  /// Hard cap on the number of segments downloaded per representation, so a
  /// server misconfiguration cannot exhaust disk or time.
  static const int _maxSegmentsPerRepresentation = 5000;

  /// Downloads the DASH presentation rooted at [manifestUrl] and returns the
  /// local master manifest.
  Future<File> download(String manifestUrl) async {
    await entryDir.create(recursive: true);
    final (String text, Uri base) = await _fetchText(manifestUrl);
    final XmlNode? root = parseXml(text);
    if (root == null || root.tag != 'MPD') {
      throw FormatException('Not a DASH manifest: $manifestUrl');
    }
    if (root.attributes['type'] == 'dynamic') {
      throw FormatException('Live DASH manifests are never cached');
    }
    final String revised = await _rebuild(root, base);
    final File master =
        File('${entryDir.path}${Platform.pathSeparator}master.mpd');
    await master.writeAsString(revised, flush: true);
    return master;
  }

  Future<String> _rebuild(XmlNode mpd, Uri base) async {
    final _Indexer index = _Indexer();
    final StringBuffer out = StringBuffer();
    out.write('<MPD${xmlAttributes(mpd)}>');
    for (final XmlNode period in _elementsOf(mpd, 'Period')) {
      out.write('<Period${xmlAttributes(period)}>');
      for (final XmlNode set in _elementsOf(period, 'AdaptationSet')) {
        out.write('<AdaptationSet${xmlAttributes(set)}>');
        for (final XmlNode child in set.children) {
          if (child.tag == 'Representation') {
            out.write(await _renderRepresentation(
                mpd, period, set, child, base, index));
          } else {
            out.write(serializeXml(child, skipTags: _segmentSourceTags));
          }
        }
        out.write('</AdaptationSet>');
      }
      out.write('</Period>');
    }
    out.write('</MPD>');
    return out.toString();
  }

  Future<String> _renderRepresentation(
    XmlNode mpd,
    XmlNode period,
    XmlNode set,
    XmlNode representation,
    Uri base,
    _Indexer index,
  ) async {
    final StringBuffer out = StringBuffer();
    out.write('<Representation${xmlAttributes(representation)}>');

    final _EffectiveTemplate template =
        _mergeTemplate(mpd, period, set, representation);
    final Uri effectiveBase = _resolveBase(mpd, period, set, representation, base);

    final List<String> localSegments = <String>[];
    String? localInitialization;

    if (template.media != null) {
      localInitialization =
          await _downloadInitialization(template, effectiveBase, index);
      final List<(int number, int time)> steps =
          _segmentSteps(mpd, template);
      if (steps.length > _maxSegmentsPerRepresentation) {
        throw FormatException(
            'DASH presentation too large to cache (${steps.length} segments)');
      }
      for (final (int number, int time) in steps) {
        final String media = _substitute(template.media!, number, time, template);
        final Uri absolute = effectiveBase.resolve(media);
        final String name = 'e${index.increment()}${_extensionOf(media)}';
        await _downloadBlob(absolute.toString(), name);
        localSegments.add(name);
      }
    } else {
      final XmlNode? segmentList =
          template.segmentList ??
          _first(_childrenOf(representation, 'SegmentList'));
      if (segmentList == null) {
        throw FormatException(
            'Unsupported DASH structure (no SegmentTemplate/SegmentList) '
            'in Representation ${representation.attributes['id']}');
      }
      final XmlNode? initialization =
          _first(_childrenOf(segmentList, 'Initialization'));
      if (initialization != null && initialization.attributes['sourceURL'] != null) {
        localInitialization = await _downloadSegment(
            initialization.attributes['sourceURL']!, effectiveBase, 'i', index);
      }
      for (final XmlNode segmentUrlNode in _elementsOf(segmentList, 'SegmentURL')) {
        final String media = segmentUrlNode.attributes['media'] ?? '';
        if (media.isEmpty) {
          continue;
        }
        localSegments.add(
            await _downloadSegment(media, effectiveBase, 'e', index));
      }
      if (localSegments.length > _maxSegmentsPerRepresentation) {
        throw FormatException('DASH presentation too large to cache');
      }
    }

    out.write('<SegmentList>');
    if (localInitialization != null && localInitialization.isNotEmpty) {
      out.write('<Initialization sourceURL="$localInitialization"/>');
    }
    for (final String name in localSegments) {
      out.write('<SegmentURL media="$name"/>');
    }
    out.write('</SegmentList>');
    out.write('</Representation>');
    return out.toString();
  }

  Future<String> _downloadInitialization(
    _EffectiveTemplate template,
    Uri base,
    _Indexer index,
  ) async {
    final String? initialization = template.initialization;
    if (initialization == null || initialization.isEmpty) {
      return '';
    }
    final String substituted = _substitute(initialization, null, null, template);
    final Uri absolute = base.resolve(substituted);
    final String ext =
        _extensionOf(substituted, _extensionOf(template.media ?? ''));
    final String name = 'init${index.increment()}$ext';
    await _downloadBlob(absolute.toString(), name);
    return name;
  }

  Future<String> _downloadSegment(
    String raw,
    Uri base,
    String prefix,
    _Indexer index,
  ) async {
    if (raw.isEmpty) {
      throw FormatException('DASH manifest references an empty segment URL');
    }
    final Uri absolute = base.resolve(raw);
    final String name = '$prefix${index.increment()}${_extensionOf(raw)}';
    await _downloadBlob(absolute.toString(), name);
    return name;
  }

  /// Expands the representation's template into the ordered `(number, time)`
  /// segments a player would request. Honors `SegmentTimeline` when present,
  /// otherwise sizes the presentation from `mediaPresentationDuration`.
  List<(int number, int time)> _segmentSteps(
    XmlNode mpd,
    _EffectiveTemplate template,
  ) {
    final int timescale =
        int.tryParse(template.attributes['timescale'] ?? '') ?? 1;
    final int startNumber =
        int.tryParse(template.attributes['startNumber'] ?? '') ?? 1;
    final int pto =
        int.tryParse(template.attributes['presentationTimeOffset'] ?? '') ?? 0;
    final List<(int, int)> steps = <(int, int)>[];

    final XmlNode? timeline = template.timeline;
    if (timeline != null) {
      int previousEnd = pto;
      int number = startNumber;
      for (final XmlNode s in _elementsOf(timeline, 'S')) {
        final int t = int.tryParse(s.attributes['t'] ?? '') ?? previousEnd;
        final int d = int.tryParse(s.attributes['d'] ?? '') ?? 0;
        final int repeats = int.tryParse(s.attributes['r'] ?? '') ?? 0;
        if (repeats < 0 || d <= 0) {
          throw FormatException(
              'Unsupported DASH segment timeline (r=$repeats, d=$d)');
        }
        for (int k = 0; k <= repeats; k++) {
          steps.add((number, t + k * d));
          number += 1;
        }
        previousEnd = t + (repeats + 1) * d;
      }
      return steps;
    }

    final int segmentDuration =
        int.tryParse(template.attributes['duration'] ?? '') ?? 0;
    final double? presentationSeconds =
        _durationSeconds(mpd.attributes['mediaPresentationDuration']);
    if (segmentDuration <= 0 || presentationSeconds == null) {
      throw FormatException(
          'Cannot size a static DASH presentation without a segment duration');
    }
    final int total =
        (presentationSeconds * timescale / segmentDuration).ceil();
    for (int n = 0; n < total; n++) {
      steps.add((startNumber + n, pto + n * segmentDuration));
    }
    return steps;
  }

  /// Merges `SegmentTemplate` attributes from the shallowest scope to the
  /// deepest (Representation wins), keeping the deepest `SegmentTimeline`.
  _EffectiveTemplate _mergeTemplate(
    XmlNode mpd,
    XmlNode period,
    XmlNode set,
    XmlNode representation,
  ) {
    final Map<String, String> merged = <String, String>{};
    XmlNode? timeline;
    for (final XmlNode scope in <XmlNode>[mpd, period, set, representation]) {
      final XmlNode? template = _first(_childrenOf(scope, 'SegmentTemplate'));
      if (template == null) {
        continue;
      }
      merged.addAll(template.attributes);
      final XmlNode? ownTimeline =
          _first(_childrenOf(template, 'SegmentTimeline'));
      if (ownTimeline != null) {
        timeline = ownTimeline;
      }
    }
    final XmlNode? inheritedSegmentList =
        _first(_childrenOf(set, 'SegmentList')) ??
            _first(_childrenOf(period, 'SegmentList'));
    return _EffectiveTemplate(
      attributes: merged,
      timeline: timeline,
      segmentList: inheritedSegmentList,
    );
  }

  /// Resolves the deepest `BaseURL` chain against [base] (the post-redirect
  /// manifest URL).
  Uri _resolveBase(
    XmlNode mpd,
    XmlNode period,
    XmlNode set,
    XmlNode representation,
    Uri base,
  ) {
    Uri effective = base;
    for (final XmlNode scope in <XmlNode>[mpd, period, set, representation]) {
      final XmlNode? baseUrl = _first(_childrenOf(scope, 'BaseURL'));
      if (baseUrl != null && baseUrl.text.isNotEmpty) {
        effective = effective.resolve(baseUrl.text);
      }
    }
    return effective;
  }

  /// `$Variable$` substitution used by DASH segment/initialization templates.
  String _substitute(
    String template,
    int? number,
    int? time,
    _EffectiveTemplate parsed,
  ) {
    String out = template;
    if (out.contains(r'$Number$') && number != null) {
      out = out.replaceAll(r'$Number$', '$number');
    }
    if (out.contains(r'$Time$') && time != null) {
      out = out.replaceAll(r'$Time$', '$time');
    }
    out = out.replaceAll(r'$Bandwidth$', '${parsed.bandwidth}');
    out = out.replaceAll(r'$RepresentationID$', parsed.representationId ?? '');
    return out;
  }

  Future<(String, Uri)> _fetchText(String url) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      headers?.forEach((String key, String value) {
        request.headers.set(key, value);
      });
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
            'VideoPlayerCache: GET $url -> ${response.statusCode}');
      }
      final String text = await response.transform(utf8.decoder).join();
      return (text, _finalUrlOf(response, Uri.parse(url)));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadBlob(String url, String localName) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      headers?.forEach((String key, String value) {
        request.headers.set(key, value);
      });
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
            'VideoPlayerCache: GET $url -> ${response.statusCode}');
      }
      final IOSink sink =
          File('${entryDir.path}${Platform.pathSeparator}$localName')
              .openWrite();
      await response.pipe(sink);
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  static Uri _finalUrlOf(HttpClientResponse response, Uri requestUri) {
    Uri current = requestUri;
    for (final RedirectInfo redirect in response.redirects) {
      current = current.resolve(redirect.location.toString());
    }
    return current;
  }
}

/// Merged segment sourcing options for one representation.
class _EffectiveTemplate {
  _EffectiveTemplate({
    required this.attributes,
    required this.timeline,
    required this.segmentList,
  });

  final Map<String, String> attributes;
  final XmlNode? timeline;

  /// `SegmentList` inherited from a `Period`/`AdaptationSet` scope.
  final XmlNode? segmentList;

  String? get media => attributes['media'];
  String? get initialization => attributes['initialization'];
  int get bandwidth => int.tryParse(attributes['bandwidth'] ?? '') ?? 0;
  String? get representationId => attributes['id'];
}

const Set<String> _segmentSourceTags = <String>{
  'BaseURL',
  'SegmentTemplate',
  'SegmentList',
  'SegmentTimeline',
  'SegmentBase',
};

/// Monotonic local file-name counter.
class _Indexer {
  int _next = 0;
  int increment() => _next++;
}

/// `mediaPresentationDuration` ("PT#H#M#S" / "PT#M#S" / "PT#S") -> seconds.
double? _durationSeconds(String? value) {
  if (value == null) {
    return null;
  }
  final RegExpMatch? match = RegExp(
    r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$',
  ).firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  final double hours = double.tryParse(match.group(1) ?? '') ?? 0;
  final double minutes = double.tryParse(match.group(2) ?? '') ?? 0;
  final double seconds = double.tryParse(match.group(3) ?? '') ?? 0;
  return hours * 3600 + minutes * 60 + seconds;
}

/// Extension of [url]'s path, falling back to [fallback] when it has none.
String _extensionOf(String url, [String fallback = '.mp4']) {
  final String path = Uri.tryParse(url)?.path ?? '';
  final int dot = path.lastIndexOf('.');
  if (dot <= 0 || dot == path.length - 1) {
    return fallback;
  }
  final String ext = path.substring(dot).toLowerCase();
  return RegExp(r'^\.\w{1,8}$').hasMatch(ext) ? ext : fallback;
}

List<XmlNode> _elementsOf(XmlNode node, String tag) =>
    node.children.where((XmlNode c) => c.tag == tag).toList();

List<XmlNode> _childrenOf(XmlNode node, String tag) => _elementsOf(node, tag);

XmlNode? _first(List<XmlNode> nodes) => nodes.isEmpty ? null : nodes.first;