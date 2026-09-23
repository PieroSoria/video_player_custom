import 'dart:convert';
import 'dart:io';

import 'mini_xml.dart';

/// Downloads a whole Smooth Streaming presentation (Microsoft IIS, `Manifest`)
/// into a flat local directory so the cached copy plays back offline.
///
/// Every `(QualityLevel fragment)` pair is resolved from the `StreamIndex`
/// `Url` template (`{bitrate}`, `{start time}`), downloaded and stored under a
/// unique flat name. The manifest is rewritten so the template maps those
/// local names and every `<c>` run is expanded into per-fragment entries, and
/// the `DVRWindowLength`/`IsLive` live-stream markers are dropped (live DVR
/// manifests are never cached).
class SmoothStreamingDownloader {
  SmoothStreamingDownloader({required this.entryDir, this.headers});

  /// Local directory that receives the manifest and every fragment.
  final Directory entryDir;

  /// HTTP headers forwarded to every request made by this downloader.
  final Map<String, String>? headers;

  /// Hard cap on fragments downloaded per stream index.
  static const int _maxFragmentsPerStream = 20000;

  /// Downloads the Smooth Streaming presentation rooted at [manifestUrl] and
  /// returns the local manifest.
  Future<File> download(String manifestUrl) async {
    await entryDir.create(recursive: true);
    final (String text, Uri base) = await _fetchText(manifestUrl);
    final XmlNode? root = parseXml(text);
    if (root == null || root.tag != 'SmoothStreamingMedia') {
      throw FormatException('Not a Smooth Streaming manifest: $manifestUrl');
    }
    if ((root.attributes['IsLive'] ?? '').toLowerCase() == 'true') {
      throw FormatException('Live Smooth Streaming is never cached');
    }
    final int? dvrWindow =
        int.tryParse(root.attributes['DVRWindowLength'] ?? '0');
    if (dvrWindow != null && dvrWindow > 0) {
      throw FormatException('Live (DVR) Smooth Streaming is never cached');
    }
    final String revised = await _rebuild(root, base);
    final File master =
        File('${entryDir.path}${Platform.pathSeparator}master.ism');
    await master.writeAsString(revised, flush: true);
    return master;
  }

  Future<String> _rebuild(XmlNode root, Uri base) async {
    final int rootTimeScale =
        int.tryParse(root.attributes['TimeScale'] ?? '') ?? 10000000;
    final int _ = rootTimeScale;
    final StringBuffer out = StringBuffer();
    out.write('<SmoothStreamingMedia${xmlAttributes(root)}>');
    for (final XmlNode stream in _elementsOf(root, 'StreamIndex')) {
      final String type = stream.attributes['Type'] ?? 'video';
      final String localName = _localTypeName(type);
      final String ext = _typeExtension(type);
      final String template = stream.attributes['Url'] ?? '';
      if (!template.contains('{start time}')) {
        throw FormatException(
            'Unsupported Smooth Streaming Url template: "$template"');
      }
      final bool usesBitrate = template.contains('{bitrate}');

      final List<(int t, int d)> fragments = _expandFragments(stream);
      if (fragments.length > _maxFragmentsPerStream) {
        throw FormatException(
            'Smooth Streaming presentation too large to cache '
            '(${fragments.length} fragments in $type stream)');
      }
      if (fragments.isEmpty) {
        out.write(serializeXml(stream, skipTags: const <String>{}));
        continue;
      }

final String localTemplate = usesBitrate
          ? '$localName{bitrate}_{start time}$ext'
          : '$localName{start time}$ext';

      // Download (quality level x fragment) pairs.
      for (final XmlNode quality in _elementsOf(stream, 'QualityLevel')) {
        final String bitrate = quality.attributes['Bitrate'] ?? '';
        for (final (int t, _) in fragments) {
          String url = template
              .replaceAll('{bitrate}', bitrate)
              .replaceAll('{start time}', '$t');
          final Uri absolute = base.resolve(url);
          final String name = localTemplate
              .replaceAll('{bitrate}', bitrate)
              .replaceAll('{start time}', '$t');
          await _downloadBlob(absolute.toString(), name);
        }
      }

      out.write('<StreamIndex');
      out.write(xmlAttributes(stream, skip: const <String>{'Url', 'Chunks'}));
      out.write(' Url="${escapeXml(localTemplate)}" Chunks="${fragments.length}">');
      for (final XmlNode quality in _elementsOf(stream, 'QualityLevel')) {
        out.write('<QualityLevel${xmlAttributes(quality)}/>');
      }
      for (final (int t, int d) in fragments) {
        out.write('<c t="$t" d="$d"/>');
      }
      out.write('</StreamIndex>');
    }
    out.write('</SmoothStreamingMedia>');
    return out.toString();
  }

  /// Expands the `<c>` entries (including `r` repeats) into the ordered
  /// `(start time, duration)` fragment slots of the stream.
  List<(int, int)> _expandFragments(XmlNode stream) {
    final List<(int, int)> fragments = <(int, int)>[];
    int runningTime = 0;
    for (final XmlNode c in _elementsOf(stream, 'c')) {
      final int t = int.tryParse(c.attributes['t'] ?? '') ?? runningTime;
      final int d = int.tryParse(c.attributes['d'] ?? '') ?? 0;
      final int repeats = int.tryParse(c.attributes['r'] ?? '') ?? 0;
      if (d <= 0) {
        throw FormatException('Smooth Streaming fragment with d<=0');
      }
      for (int k = 0; k <= repeats; k++) {
        fragments.add((t + k * d, d));
      }
      runningTime = t + (repeats + 1) * d;
    }
    return fragments;
  }

  /// Short per-stream-type file prefix (`v`, `a`, `t`).
  static String _localTypeName(String type) {
    switch (type.toLowerCase()) {
      case 'audio':
        return 'a';
      case 'text':
        return 't';
      default:
        return 'v';
    }
  }

  static String _typeExtension(String type) {
    switch (type.toLowerCase()) {
      case 'audio':
        return '.isma';
      case 'text':
        return '.ismt';
      default:
        return '.ismv';
    }
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

List<XmlNode> _elementsOf(XmlNode node, String tag) =>
    node.children.where((XmlNode c) => c.tag == tag).toList();