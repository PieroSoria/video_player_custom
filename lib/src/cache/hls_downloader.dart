import 'dart:convert';
import 'dart:io';

/// Downloads a whole HLS presentation into a flat local directory so the
/// cached copy can be played back offline.
///
/// The master playlist, every variant (media) playlist, all segments and the
/// AES-128 keys are stored in [entryDir] under short names, and every
/// reference (`#EXT-X-STREAM-INF`, `#EXTINF`, `#EXT-X-KEY`, `#EXT-X-MAP`,
/// `#EXT-X-MEDIA`...) is rewritten to a relative local file name. The returned
/// master playlist can then be opened through a `file://` URI: relative
/// references resolve inside the same folder.
class HlsDownloader {
  HlsDownloader({required this.entryDir, this.headers});

  /// Local directory that receives every downloaded playlist, segment and key.
  final Directory entryDir;

  /// HTTP headers forwarded to every request made by this downloader.
  final Map<String, String>? headers;

  /// Absolute URI -> local file name assigned inside [entryDir].
  final Map<String, String> _localNameByUri = <String, String>{};
  int _nextIndex = 0;

  /// Downloads the HLS presentation rooted at [masterUrl] and returns the
  /// local master playlist.
  Future<File> download(String masterUrl) async {
    await entryDir.create(recursive: true);
    final (String text, String base) = await _fetchText(masterUrl);
    if (!text.startsWith('#EXTM3U')) {
      throw FormatException('Not an HLS playlist: $masterUrl');
    }
    final String revised = await _rewrite(text, base);
    final File master =
        File('${entryDir.path}${Platform.pathSeparator}master.m3u8');
    await master.writeAsString(revised, flush: true);
    return master;
  }

  /// Rewrites every playlist reference that appears in [manifest] to a local
  /// file name, downloading referenced resources on demand. [baseUrl] is the
  /// (post-redirect) URL the manifest was loaded from, used to resolve
  /// relative references.
  Future<String> _rewrite(String manifest, String baseUrl) async {
    final List<String> output = <String>[];
    for (final String raw in manifest.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) {
        output.add(raw);
        continue;
      }
      if (line.startsWith('#')) {
        output.add(await _rewriteDirective(raw, baseUrl));
        continue;
      }
      // A bare URI line: variant playlist (after #EXT-X-STREAM-INF) or a
      // segment (after #EXTINF).
      final String absolute = Uri.parse(baseUrl).resolve(line).toString();
      output.add(await _localNameFor(absolute));
    }
    return output.join('\n');
  }

  Future<String> _rewriteDirective(String raw, String baseUrl) async {
    if (!raw.contains('URI=')) {
      return raw;
    }
    final RegExpMatch? match = RegExp('URI="([^"]*)"').firstMatch(raw);
    if (match == null || match.group(1)!.isEmpty) {
      // e.g. #EXT-X-KEY:METHOD=NONE: no key to download.
      return raw;
    }
    final String absolute =
        Uri.parse(baseUrl).resolve(match.group(1)!).toString();
    final String local = await _localNameFor(absolute);
    return raw.replaceFirst('URI="${match.group(1)}"', 'URI="$local"');
  }

  /// Ensures the resource at [absoluteUri] is downloaded into [entryDir] and
  /// returns its local file name. Playlists are fetched as text and rewritten
  /// recursively; every other resource (segment, key, init segment) is copied
  /// as-is.
  Future<String> _localNameFor(String absoluteUri) async {
    final String? existing = _localNameByUri[absoluteUri];
    if (existing != null) {
      return existing;
    }
    final String ext = _extensionOf(absoluteUri);
    final String name = 'e${_nextIndex++}$ext';
    if (ext == '.m3u8' || ext == '.m3u') {
      final (String text, String base) = await _fetchText(absoluteUri);
      if (!text.startsWith('#EXTM3U')) {
        throw FormatException('Not an HLS playlist: $absoluteUri');
      }
      _localNameByUri[absoluteUri] = name;
      await File('${entryDir.path}${Platform.pathSeparator}$name')
          .writeAsString(await _rewrite(text, base), flush: true);
      return name;
    }
    await _downloadBlob(absoluteUri, name);
    _localNameByUri[absoluteUri] = name;
    return name;
  }

  Future<(String, String)> _fetchText(String url) async {
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
      final IOSink sink = File('${entryDir.path}${Platform.pathSeparator}$localName')
          .openWrite();
      await response.pipe(sink);
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  static String _finalUrlOf(HttpClientResponse response, Uri requestUri) {
    Uri current = requestUri;
    for (final RedirectInfo redirect in response.redirects) {
      current = current.resolve(redirect.location.toString());
    }
    return current.toString();
  }

  static String _extensionOf(String url) {
    final String path = Uri.tryParse(url)?.path ?? '';
    final int dot = path.lastIndexOf('.');
    if (dot <= 0 || dot == path.length - 1) {
      return '.blob';
    }
    final String ext = path.substring(dot).toLowerCase();
    return RegExp(r'^\.\w{1,10}$').hasMatch(ext) ? ext : '.blob';
  }
}