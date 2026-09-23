import 'dart:async';
import 'dart:io';

/// Disk cache for network videos, modelled after `cached_network_image`.
///
/// Assign a persistent [Directory] to [instance] to reuse downloaded files
/// across launches and play offline. Downloads stream to disk in chunks, so
/// device memory is not saturated even for large files.
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

  /// The cached file for [uri], or `null` when it is not cached yet.
  ///
  /// Uses [cacheKey] as the entry name when provided; otherwise a stable hash
  /// of [uri]. Touches the file so LRU eviction keeps it longer.
  Future<File?> fileFor(String uri, {String? cacheKey}) async {
    final File file = _fileFor(uri, cacheKey);
    if (!await file.exists()) {
      return null;
    }
    await _touch(file);
    return file;
  }

  /// Whether [uri] currently has a cached entry.
  Future<bool> have(String uri, {String? cacheKey}) async {
    return await fileFor(uri, cacheKey: cacheKey) != null;
  }

  /// Downloads [uri] into the cache (or waits for an already-running
  /// download of the same entry) without blocking playback.
  ///
  /// Idempotent: returns immediately when the entry already exists. Failures
  /// are surfaced to the caller, which usually ignores them (cache misses do
  /// not prevent streaming).
  Future<void> prefetch(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
  }) {
    final File target = _fileFor(uri, cacheKey);
    Future<void>? inFlight = _prefetching[target.path];
    if (inFlight == null) {
      inFlight = _download(uri, target, headers);
      _prefetching[target.path] = inFlight;
      inFlight.then<void>((_) {
        _prefetching.remove(target.path);
      }, onError: (Object _) {
        _prefetching.remove(target.path);
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
  }) {
    return prefetch(uri, cacheKey: cacheKey, headers: headers);
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
      if (entry is File) {
        try {
          total += await entry.length();
        } catch (_) {}
      }
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

  Future<void> _evictIfNeeded() async {
    if (maxCacheSizeBytes < 0 || !await _cacheDirectory.exists()) {
      return;
    }
    final List<({File file, int size, DateTime modified})> entries =
        <({File file, int size, DateTime modified})>[];
    await for (final FileSystemEntity entity in _cacheDirectory.list()) {
      if (entity is File) {
        final FileStat stat = entity.statSync();
        entries.add(
          (file: entity, size: stat.size, modified: stat.modified),
        );
      }
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
        entry.file.deleteSync();
      } catch (_) {}
    }
  }

  File _fileFor(String uri, String? cacheKey) {
    final String key = cacheKey ?? _hash(uri);
    final String ext = _extensionOf(Uri.tryParse(uri));
    return File('${_cacheDirectory.path}${Platform.pathSeparator}$key$ext');
  }

  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
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