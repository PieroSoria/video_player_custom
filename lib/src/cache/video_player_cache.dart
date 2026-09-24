import 'dart:async';
import 'dart:io';

import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'cache_http_server.dart';
import 'dash_downloader.dart';
import 'hls_downloader.dart';
import 'smooth_streaming_downloader.dart';

/// Disk cache for network videos, modelled after `cached_network_image`.
///
/// Assign a persistent [Directory] to [instance] to reuse downloaded files
/// across launches and play offline. Downloads stream to disk in chunks, so
/// device memory is not saturated even for large files.
///
/// Supported sources:
///   * Single files (MP4, MKV, WebM, ...) — cached whole.
///   * HLS (`formatHint: VideoFormat.hls` or `.m3u8`/`.m3u` URLs) — the whole
///     presentation (playlists, segments and keys) is downloaded and rewritten
///     to local files, so the cached copy plays back offline.
///   * DASH (`formatHint: VideoFormat.dash` or `.mpd` URLs) — the manifest and
///     every segment are downloaded and the manifest is rewritten to local
///     files.
///   * Smooth Streaming (`formatHint: VideoFormat.ss` or `Manifest` URLs) —
///     the manifest and every video/audio fragment are downloaded and the
///     manifest is rewritten to local files.
///   * Live manifests (dynamic DASH, DVR/Smooth Streaming) are never cached,
///     and neither are sources opened with `isLive: true` on the controller.
///
/// Note: manifest playback from the cached local files requires a player that
/// accepts `file://` HLS/DASH presentations (e.g. ExoPlayer on Android). On
/// iOS/macOS AVFoundation does not, so `VideoPlayerController` serves the
/// cached manifest over this cache's loopback HTTP server there (see
/// [serveManifestHttp]).
///
/// Usage from `initialize()` (opt-in, `cacheKey` required):
/// ```dart
/// final controller = VideoPlayerController.networkUrl(
///   Uri.parse('https://example.com/video.mp4'),
///   cacheKey: 'weekly-highlights',
/// );
/// ```
class VideoPlayerCache {
  /// Creates a cache backed by [_cacheDirectory].
  ///
  /// [maxCacheSizeBytes] bounds the total on-disk size using an LRU policy
  /// (oldest entries are removed first). Pass a negative value for no limit.
  VideoPlayerCache(this._cacheDirectory,
      {this.maxCacheSizeBytes = 1 << 30});

  /// Global instance used by [VideoPlayerController.networkUrl] when a
  /// [cacheKey] is provided. Defaults to a folder under the system temp
  /// directory; point it at a persistent directory to keep playback offline
  /// for the next run.
  static VideoPlayerCache instance = VideoPlayerCache(
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}'
        'video_player_custom_cache'),
  );

  final Directory _cacheDirectory;
  final int maxCacheSizeBytes;

  final Map<String, Future<void>> _prefetching = <String, Future<void>>{};
  CacheHttpServer? _httpServer;

  /// The cached file for [uri], or `null` when it is not cached yet.
  ///
  /// Uses [cacheKey] as the entry name when provided; otherwise a stable hash
  /// of [uri]. Touches the file so LRU eviction keeps it longer. For HLS,
  /// DASH and Smooth Streaming the returned file is the rewritten local
  /// master manifest/playlist.
  Future<File?> fileFor(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {
    final String key = cacheKey ?? _hash(uri);
    final String? manifestExt = manifestExtension(uri, formatHint);
    if (manifestExt != null) {
      final File master = _manifestMaster(key, manifestExt);
      if (!await master.exists()) {
        return null;
      }
      await _touch(master);
      return master;
    }
    final File file = _fileFor(key, uri);
    if (!await file.exists()) {
      return null;
    }
    await _touch(file);
    return file;
  }

  /// Whether [uri] currently has a cached entry.
  Future<bool> have(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {
    return await fileFor(uri, cacheKey: cacheKey, formatHint: formatHint) !=
        null;
  }

  /// HTTP URL over the cache's loopback server for [uri]'s cached manifest
  /// entry, or `null` when the entry is not cached or [uri] is not a
  /// manifest source.
  ///
  /// AVFoundation only plays HLS/DASH manifests delivered over HTTP (never
  /// from a `file://` path), so iOS/macOS play the cached presentation
  /// through this URL while it keeps streaming from disk.
  Future<Uri?> serveManifestHttp(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {
    final String? ext = manifestExtension(uri, formatHint);
    if (ext == null) {
      return null;
    }
    final String key = cacheKey ?? _hash(uri);
    final File master = _manifestMaster(key, ext);
    if (!await master.exists()) {
      return null;
    }
    await _touch(master);
    _httpServer ??= CacheHttpServer(_cacheDirectory);
    return _httpServer!.urlFor(key, 'master$ext');
  }

  /// Downloads [uri] into the cache (or waits for an already-running
  /// download of the same entry) without blocking playback.
  ///
  /// Idempotent: returns immediately when the entry already exists. HLS, DASH
  /// and Smooth Streaming sources download their whole presentation
  /// (manifests, segments, keys) and rewrite it to local files. Failures are
  /// surfaced to the caller, which usually ignores them (cache misses do not
  /// prevent streaming).
  Future<void> prefetch(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
  }) {
    final String key = cacheKey ?? _hash(uri);
    final String? manifestExt = manifestExtension(uri, formatHint);
    final String hitKey = manifestExt != null
        ? _manifestMaster(key, manifestExt).path
        : _fileFor(key, uri).path;
    Future<void>? inFlight = _prefetching[hitKey];
    if (inFlight == null) {
      inFlight = manifestExt != null
          ? _downloadManifestEntry(uri, key, headers, manifestExt, formatHint)
          : _download(uri, _fileFor(key, uri), headers);
      _prefetching[hitKey] = inFlight;
      inFlight.then<void>((_) {
        _prefetching.remove(hitKey);
      }, onError: (Object _) {
        _prefetching.remove(hitKey);
      });
    }
    return inFlight;
  }

  /// Alias of [prefetch] for pre-warming flows; may be cancelled by returning
  /// the future and awaiting it where convenient.
  Future<void> warm(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
  }) {
    return prefetch(
      uri,
      cacheKey: cacheKey,
      headers: headers,
      formatHint: formatHint,
    );
  }

  /// Removes every cached entry.
  Future<void> clear() async {
    if (!await _cacheDirectory.exists()) {
      return;
    }
    await for (final FileSystemEntity entry in _cacheDirectory.list()) {
      try {
        await entry.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Total on-disk size of the cache directory in bytes.
  Future<int> totalSizeBytes() async {
    if (!await _cacheDirectory.exists()) {
      return 0;
    }
    int total = 0;
    await for (final FileSystemEntity entry in _cacheDirectory.list()) {
      total += await _entrySize(entry);
    }
    return total;
  }

  Future<File> _download(
    String uri,
    File target,
    Map<String, String>? headers,
  ) async {
    if (await target.exists()) {
      return target;
    }
    await _cacheDirectory.create(recursive: true);
    final File part = File('${target.path}.part');
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(uri));
      headers?.forEach((String key, String value) {
        request.headers.set(key, value);
      });
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
            'VideoPlayerCache: GET $uri -> ${response.statusCode}');
      }
      final IOSink sink = part.openWrite();
      await response.pipe(sink);
      await sink.close();
      await part.rename(target.path);
      await _touch(target);
      await _evictIfNeeded();
      return target;
    } catch (_) {
      try {
        if (part.existsSync()) {
          part.deleteSync();
        }
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadManifestEntry(
    String uri,
    String key,
    Map<String, String>? headers,
    String manifestExt,
    VideoFormat? formatHint,
  ) async {
    final File master = _manifestMaster(key, manifestExt);
    if (await master.exists()) {
      return;
    }
    await _cacheDirectory.create(recursive: true);
    try {
      final Directory dir = _manifestDir(key);
      switch (manifestExt) {
        case '.m3u8':
          await HlsDownloader(entryDir: dir, headers: headers).download(uri);
        case '.mpd':
          await DashDownloader(entryDir: dir, headers: headers).download(uri);
        case '.ism':
          await SmoothStreamingDownloader(entryDir: dir, headers: headers)
              .download(uri);
        default:
          throw FormatException(
              'VideoPlayerCache: unknown manifest type $manifestExt');
      }
      await _touch(master);
      await _evictIfNeeded();
    } catch (_) {
      try {
        final Directory dir = _manifestDir(key);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _evictIfNeeded() async {
    if (maxCacheSizeBytes < 0 || !await _cacheDirectory.exists()) {
      return;
    }
    final List<({FileSystemEntity entity, int size, DateTime modified})>
        entries =
        <({FileSystemEntity entity, int size, DateTime modified})>[];
    await for (final FileSystemEntity entity in _cacheDirectory.list()) {
      entries.add(
        (
          entity: entity,
          size: await _entrySize(entity),
          modified: await _entryModified(entity),
        ),
      );
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    int total = 0;
    for (final entry in entries) {
      total += entry.size;
    }
    for (final entry in entries) {
      if (total <= maxCacheSizeBytes) {
        break;
      }
      total -= entry.size;
      try {
        _deleteQuietly(entry.entity);
      } catch (_) {}
    }
  }

  Future<int> _entrySize(FileSystemEntity entity) async {
    if (entity is File) {
      try {
        return await entity.length();
      } catch (_) {
        return 0;
      }
    }
    if (entity is! Directory) {
      return 0;
    }
    int total = 0;
    try {
      await for (final FileSystemEntity child in entity.list(recursive: true)) {
        if (child is File) {
          total += await child.length();
        }
      }
    } catch (_) {}
    return total;
  }

  Future<DateTime> _entryModified(FileSystemEntity entity) async {
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      latest = entity.statSync().modified;
    } catch (_) {}
    if (entity is! Directory) {
      return latest;
    }
    try {
      await for (final FileSystemEntity child in entity.list(recursive: true)) {
        if (child is File) {
          final DateTime modified = child.statSync().modified;
          if (modified.isAfter(latest)) {
            latest = modified;
          }
        }
      }
    } catch (_) {}
    return latest;
  }

  File _manifestMaster(String key, String manifestExt) =>
      File('${_manifestDir(key).path}${Platform.pathSeparator}'
          'master$manifestExt');

  Directory _manifestDir(String key) =>
      Directory('${_cacheDirectory.path}${Platform.pathSeparator}$key');

  File _fileFor(String key, String uri) {
    final String ext = _extensionOf(Uri.tryParse(uri));
    return File('${_cacheDirectory.path}${Platform.pathSeparator}$key$ext');
  }

  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// The local master-manifest extension for a manifest-based source, or
  /// `null` for plain media files. Detection combines the [formatHint] with
  /// the URL shape.
  static String? manifestExtension(String uri, VideoFormat? formatHint) {
    if (formatHint == VideoFormat.hls || _isHlsUri(uri)) {
      return '.m3u8';
    }
    if (formatHint == VideoFormat.dash || _isDashUri(uri)) {
      return '.mpd';
    }
    if (formatHint == VideoFormat.ss || _isSsUri(uri)) {
      return '.ism';
    }
    return null;
  }

  static bool _isHlsUri(String uri) {
    final String lower = uri.toLowerCase();
    return lower.endsWith('.m3u8') || lower.endsWith('.m3u');
  }

  static bool _isDashUri(String uri) => uri.toLowerCase().endsWith('.mpd');

  static bool _isSsUri(String uri) {
    final String lower = uri.toLowerCase();
    return lower.endsWith('.ism') || lower.endsWith('/manifest') ||
        lower.contains('.ism/');
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (entity is Directory) {
        if (await entity.exists()) {
          await entity.delete(recursive: true);
        }
      } else if (entity is File) {
        if (await entity.exists()) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  static String _hash(String value) {
    // FNV-1a 64-bit: stable, dependency-free, plenty for a cache key.
    const int prime = 0x100000001B3;
    int hash = 0xcbf29ce484222325;
    for (final int unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _extensionOf(Uri? uri) {
    final String source = uri == null || uri.path.isEmpty ? '' : uri.path;
    final int dot = source.lastIndexOf('.');
    if (dot <= 0 || dot == source.length - 1) {
      return '.video';
    }
    final String ext = source.substring(dot).toLowerCase();
    return RegExp(r'^\.\w{1,8}$').hasMatch(ext) ? ext : '.video';
  }
}