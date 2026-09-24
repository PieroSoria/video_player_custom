import 'dart:io';
import 'dart:math' as math show min;

/// Serves files of a [VideoPlayerCache] entry over an in-process loopback
/// HTTP server.
///
/// AVFoundation only accepts HLS/DASH manifests delivered over HTTP — a
/// `file://` playlist never initiates on iOS/macOS — so cached presentations
/// are played through `http://127.0.0.1:<port>/<entry>/...` on those
/// platforms. The server binds exclusively to the loopback interface and
/// never serves anything the cache directory does not contain.
class CacheHttpServer {
  CacheHttpServer(this.root);

  /// Directory the server exposes. Every request maps to a file inside it.
  final Directory root;

  HttpServer? _server;

  Future<HttpServer> _ensureStarted() async {
    HttpServer? server = _server;
    if (server != null) {
      return server;
    }
    await root.create(recursive: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0,
        shared: true);
    server.listen(_handle);
    _server = server;
    return server;
  }

  Future<int> get _port async => (await _ensureStarted()).port;

  /// Absolute URL of [fileName] inside [entryKey]'s cache entry.
  ///
  /// Starts the server on first use. Both components are percent-encoded so
  /// cache keys containing `/` or spaces are preserved.
  Future<Uri> urlFor(String entryKey, String fileName) async {
    final int port = await _port;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      pathSegments: <String>[entryKey, fileName],
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final File? file = _fileForRequest(request.uri.path);
    if (file == null || !await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final int length = await file.length();
    final HttpResponse response = request.response;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers
        .set(HttpHeaders.contentTypeHeader, _mimeFor(file.absolute.path));

    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    if (request.method == 'HEAD') {
      response.headers.set(HttpHeaders.contentLengthHeader, length);
      await response.close();
      return;
    }
    if (range != null) {
      final RegExpMatch? match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (match != null) {
        final int start =
            match.group(1)!.isEmpty ? 0 : int.parse(match.group(1)!);
        final int end = match.group(2)!.isEmpty
            ? length - 1
            : int.parse(match.group(2)!);
        if (start >= 0 && start < length && end >= start) {
          await _serveRange(response, file, start, math.min(end, length - 1),
              length);
          return;
        }
      }
    }
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentLengthHeader, length);
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _serveRange(
      HttpResponse response, File file, int start, int end, int length) async {
    response.statusCode = HttpStatus.partialContent;
    response.headers
        .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    response.headers.set(HttpHeaders.contentLengthHeader, end - start + 1);
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }

  /// Maps a request path (e.g. `/show/master.m3u8`) to a file inside [root],
  /// rejecting path traversal and anything outside the cache directory.
  File? _fileForRequest(String path) {
    final List<String> segments = path
        .split('/')
        .where((String s) => s.isNotEmpty && s != '.')
        .toList();
    if (segments.isEmpty || segments.any((String s) => s == '..')) {
      return null;
    }
    final String rootPath =
        '${root.absolute.path}${Platform.pathSeparator}';
    final File candidate =
        File('$rootPath${segments.join(Platform.pathSeparator)}');
    final String candidatePath = candidate.absolute.path;
    if (!candidatePath.startsWith(rootPath)) {
      return null;
    }
    return candidate;
  }

  static String _mimeFor(String path) {
    final int dot = path.lastIndexOf('.');
    final String ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
    switch (ext) {
      case '.m3u8':
      case '.m3u':
        return 'application/vnd.apple.mpegurl';
      case '.mpd':
        return 'application/dash+xml';
      case '.ism':
        return 'application/vnd.ms-sstr+xml';
      case '.ts':
        return 'video/mp2t';
      case '.mp4':
      case '.ismv':
        return 'video/mp4';
      case '.isma':
        return 'audio/mp4';
      case '.ismt':
      case '.vtt':
        return 'text/plain';
      case '.aac':
        return 'audio/aac';
      case '.mp3':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }
}