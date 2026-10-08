import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'web_hls_manifest.dart';

extension type _StoredMedia._(JSObject _) implements JSObject {
  external factory _StoredMedia({
    required String manifest,
    required JSArray<web.Blob> blobs,
  });
  external String get manifest;
  external JSArray<web.Blob> get blobs;
}

extension type _Metadata._(JSObject _) implements JSObject {
  external factory _Metadata({
    required String key,
    required String kind,
    required int size,
    required int accessed,
  });
  external String get key;
  external String get kind;
  external int get size;
  external int get accessed;
}

final Map<String, WebVideoPlayerCache> _leaseOwners =
    <String, WebVideoPlayerCache>{};

/// Releases a source even when the global cache instance has been replaced.
void releaseBrowserCacheLease(String source) {
  _leaseOwners[source]?.releaseSource(source);
}

/// Persistent browser media cache backed by IndexedDB.
///
/// [namespace] is scoped to the site's origin. Completed MP4/WebM and other
/// browser-decodable media files are stored atomically. Finite HLS playlists,
/// segments and identity AES-128 keys are cached for browsers with native HLS.
/// DASH, Smooth Streaming, DRM and live presentations are rejected rather than
/// storing an incomplete or unplayable manifest.
///
/// Downloads use Fetch, so cross-origin servers must allow CORS and any custom
/// headers. Browsers control storage quotas and may evict site data. Cache hits
/// create temporary blob URLs; controllers release these automatically, while
/// callers of [sourceFor] must call [releaseSource] after playback.
class WebVideoPlayerCache {
  WebVideoPlayerCache({
    this.namespace = 'video_player_custom_cache',
    this.maxCacheSizeBytes = 1 << 30,
  });

  static WebVideoPlayerCache instance = WebVideoPlayerCache();
  final String namespace;
  final int maxCacheSizeBytes;

  Future<web.IDBDatabase>? _opening;
  web.IDBDatabase? _database;
  final Map<String, Future<void>> _downloads = <String, Future<void>>{};
  final Map<String, int> _entryEpochs = <String, int>{};
  final Map<web.AbortController, bool> _requests =
      <web.AbortController, bool>{};
  final Map<String, List<String>> _leases = <String, List<String>>{};
  Future<void> _mutation = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;

  /// Whether this browser currently permits this cache to open IndexedDB.
  Future<bool> get supported async {
    try {
      await _open();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _key(String uri, String? cacheKey, VideoFormat? formatHint) =>
      '${_kind(uri, formatHint)}:${cacheKey ?? uri}';

  static String _kind(String uri, VideoFormat? hint) {
    final String path = Uri.tryParse(uri)?.path.toLowerCase() ?? '';
    if (hint == VideoFormat.hls ||
        path.endsWith('.m3u8') ||
        path.endsWith('.m3u')) {
      return 'hls';
    }
    if (hint == VideoFormat.dash || path.endsWith('.mpd')) {
      return 'dash';
    }
    if (hint == VideoFormat.ss ||
        path.endsWith('.ism') ||
        path.endsWith('/manifest') ||
        path.contains('.ism/')) {
      return 'smooth';
    }
    return 'file';
  }

  Future<web.IDBDatabase> _open() {
    if (_disposed) {
      return Future<web.IDBDatabase>.error(StateError('Cache is disposed'));
    }
    return _opening ??= _openDatabase().then(
      (web.IDBDatabase db) {
        if (_disposed) {
          db.close();
          throw StateError('Cache is disposed');
        }
        _database = db;
        return db;
      },
      onError: (Object error, StackTrace stack) {
        _opening = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<web.IDBDatabase> _openDatabase() {
    final Completer<web.IDBDatabase> done = Completer<web.IDBDatabase>();
    final web.IDBOpenDBRequest request = web.window.indexedDB.open(
      'video_player_custom:$namespace',
      1,
    );
    request.onupgradeneeded = ((web.Event _) {
      final web.IDBDatabase db = request.result as web.IDBDatabase;
      db.createObjectStore('media');
      db.createObjectStore('metadata');
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final web.IDBDatabase db = request.result as web.IDBDatabase;
      if (done.isCompleted) {
        db.close();
        return;
      }
      db.onversionchange = ((web.Event _) {
        db.close();
        _database = null;
        _opening = null;
      }).toJS;
      done.complete(db);
    }).toJS;
    void fail() {
      if (!done.isCompleted) {
        done.completeError(StateError('Browser cache storage is unavailable'));
      }
    }

    request.onerror = ((web.Event _) => fail()).toJS;
    request.onblocked = ((web.Event _) => fail()).toJS;
    return done.future;
  }

  static Future<JSAny?> _result(web.IDBRequest request) {
    final Completer<JSAny?> done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
    request.onerror = ((web.Event _) => done.completeError(
      StateError(request.error?.message ?? 'IndexedDB request failed'),
    )).toJS;
    return done.future;
  }

  static Future<void> _committed(web.IDBTransaction transaction) {
    final Completer<void> done = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    void fail() {
      if (!done.isCompleted) {
        done.completeError(
          StateError(
            transaction.error?.message ?? 'IndexedDB transaction failed',
          ),
        );
      }
    }

    transaction.onerror = ((web.Event _) => fail()).toJS;
    transaction.onabort = ((web.Event _) => fail()).toJS;
    return done.future;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final Future<T> result = _mutation.then((_) => action());
    _mutation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<_StoredMedia?> _read(String key) async {
    final web.IDBDatabase db = await _open();
    final web.IDBTransaction tx = db.transaction('media'.toJS);
    final JSAny? value = await _result(tx.objectStore('media').get(key.toJS));
    return value.isUndefinedOrNull ? null : value as _StoredMedia;
  }

  /// Whether a complete presentation is available under this source/key.
  Future<bool> have(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {
    try {
      final web.IDBDatabase db = await _open();
      final web.IDBTransaction tx = db.transaction('metadata'.toJS);
      final JSAny? value = await _result(
        tx.objectStore('metadata').get(_key(uri, cacheKey, formatHint).toJS),
      );
      return !value.isUndefinedOrNull;
    } catch (_) {
      return false;
    }
  }

  /// Leases an offline blob URL, or returns null for a miss/unavailable storage.
  Future<String?> sourceFor(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {
    final String key = _key(uri, cacheKey, formatHint);
    try {
      final _StoredMedia? entry = await _read(key);
      if (entry == null) return null;
      final String source = await _lease(entry);
      try {
        await _serialize(() async {
          final web.IDBDatabase db = await _open();
          final web.IDBTransaction tx = db.transaction(
            'metadata'.toJS,
            'readwrite',
          );
          final Future<void> committed = _committed(tx);
          final web.IDBRequest request = tx
              .objectStore('metadata')
              .get(key.toJS);
          request.onsuccess = ((web.Event _) {
            final JSAny? value = request.result;
            if (!value.isUndefinedOrNull) {
              final _Metadata meta = value as _Metadata;
              tx
                  .objectStore('metadata')
                  .put(
                    _Metadata(
                      key: meta.key,
                      kind: meta.kind,
                      size: meta.size,
                      accessed: DateTime.now().millisecondsSinceEpoch,
                    ),
                    key.toJS,
                  );
            }
          }).toJS;
          await committed;
        });
      } catch (_) {
        // A valid leased blob remains playable when a metadata touch fails.
      }
      if (_disposed) {
        releaseSource(source);
        return null;
      }
      return source;
    } catch (_) {
      return null;
    }
  }

  /// Downloads a whole source before atomically exposing it as a cache hit.
  /// Calls for the same key share one download. Live sources are bypassed.
  Future<void> prefetch(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) {
    if (isLive) return Future<void>.value();
    final String key = _key(uri, cacheKey, formatHint);
    return _downloads.putIfAbsent(key, () {
      final int generation = _generation;
      final Future<void> download = _prefetch(
        uri,
        key,
        headers,
        _kind(uri, formatHint),
        generation,
        _entryEpochs[key] ?? 0,
      );
      download.then<void>(
        (_) {
          if (identical(_downloads[key], download)) _downloads.remove(key);
        },
        onError: (Object _) {
          if (identical(_downloads[key], download)) _downloads.remove(key);
        },
      );
      return download;
    });
  }

  Future<void> _prefetch(
    String uri,
    String key,
    Map<String, String>? headers,
    String kind,
    int generation,
    int entryEpoch,
  ) async {
    void ensureActive() {
      if (_disposed ||
          generation != _generation ||
          entryEpoch != (_entryEpochs[key] ?? 0)) {
        throw StateError('Cache download was cancelled');
      }
    }

    ensureActive();
    _validateKind(kind);
    final bool cached = await have(
      uri,
      cacheKey: key.substring(kind.length + 1),
      formatHint: kind == 'hls' ? VideoFormat.hls : null,
    );
    ensureActive();
    if (cached) return;
    await _open();
    ensureActive();
    final _StoredMedia entry = await _download(uri, headers, kind, generation);
    await _serialize(() async {
      ensureActive();
      final int size = entry.blobs.toDart.fold<int>(
        0,
        (int size, web.Blob blob) => size + blob.size,
      );
      if (maxCacheSizeBytes >= 0 && size > maxCacheSizeBytes) {
        throw StateError('Video exceeds the configured browser cache size');
      }
      final web.IDBDatabase db = await _open();
      ensureActive();
      final web.IDBTransaction tx = db.transaction(
        ['media'.toJS, 'metadata'.toJS].toJS,
        'readwrite',
      );
      final Future<void> committed = _committed(tx);
      tx.objectStore('media').put(entry, key.toJS);
      tx
          .objectStore('metadata')
          .put(
            _Metadata(
              key: key,
              kind: kind,
              size: size,
              accessed: DateTime.now().millisecondsSinceEpoch,
            ),
            key.toJS,
          );
      await committed;
      await _evict(db);
    });
  }

  /// Alias for [prefetch].
  Future<void> warm(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) => prefetch(
    uri,
    cacheKey: cacheKey,
    headers: headers,
    formatHint: formatHint,
    isLive: isLive,
  );

  static void _validateKind(String kind) {
    if (kind == 'dash' || kind == 'smooth') {
      throw UnsupportedError(
        'Browser cache requires native media decoding; '
        'DASH and Smooth Streaming require a separate MSE player',
      );
    }
    if (kind == 'hls') {
      final web.HTMLVideoElement video = web.HTMLVideoElement();
      if (video.canPlayType('application/vnd.apple.mpegurl').isEmpty &&
          video.canPlayType('application/x-mpegURL').isEmpty) {
        throw UnsupportedError('This browser does not support native HLS');
      }
    }
  }

  Future<({web.Blob blob, String base})> _fetch(
    String uri,
    Map<String, String>? headers,
    int? generation,
  ) async {
    if (_disposed || generation != null && generation != _generation) {
      throw StateError('Cache download was cancelled');
    }
    final web.AbortController abort = web.AbortController();
    _requests[abort] = generation != null;
    final web.Headers requestHeaders = web.Headers();
    headers?.forEach((String name, String value) {
      requestHeaders.set(name, value);
    });
    // Fetch must request the whole media representation, never a ranged part.
    requestHeaders.delete('Range');
    final Timer timeout = Timer(
      const Duration(seconds: 60),
      () => abort.abort(),
    );
    try {
      final web.Response response = await web.window
          .fetch(
            uri.toJS,
            web.RequestInit(
              headers: requestHeaders,
              signal: abort.signal,
              credentials: 'same-origin',
            ),
          )
          .toDart;
      if (!response.ok || response.status != 200 || response.type == 'opaque') {
        throw StateError('Video cache GET failed (${response.status})');
      }
      final web.Blob blob = await response.blob().toDart;
      if (_disposed || generation != null && generation != _generation) {
        throw StateError('Cache download was cancelled');
      }
      if (blob.size == 0) throw StateError('Video response was empty');
      final String type = blob.type.toLowerCase();
      if (type.contains('dash+xml') ||
          type.contains('vnd.ms-sstr') ||
          type.contains('text/html') ||
          type.contains('application/json')) {
        throw UnsupportedError('This browser cannot decode the manifest');
      }
      return (blob: blob, base: response.url.isEmpty ? uri : response.url);
    } finally {
      timeout.cancel();
      _requests.remove(abort);
    }
  }

  Future<_StoredMedia> _download(
    String uri,
    Map<String, String>? headers,
    String kind,
    int? generation, {
    bool enforceLimit = true,
  }) async {
    _validateKind(kind);
    final List<web.Blob> blobs = <web.Blob>[];
    final List<Map<String, Object?>> nodes = <Map<String, Object?>>[];
    final Map<String, int> index = <String, int>{};
    final Set<String> visiting = <String>{};
    int total = 0;
    Future<int> visit(String url, bool playlist, int depth) async {
      if (depth > 64 || nodes.length >= 10000) {
        throw StateError('HLS presentation is too large or deeply nested');
      }
      if (visiting.contains(url)) {
        throw const FormatException('Circular HLS playlists are not supported');
      }
      final int? existing = index[url];
      if (existing != null) return existing;
      visiting.add(url);
      final ({web.Blob blob, String base}) response = await _fetch(
        url,
        headers,
        generation,
      );
      final bool isPlaylist =
          playlist || response.blob.type.toLowerCase().contains('mpegurl');
      final int id = nodes.length;
      index[url] = id;
      nodes.add(<String, Object?>{'url': url, 'base': response.base});
      blobs.add(response.blob);
      total += response.blob.size;
      if (enforceLimit && maxCacheSizeBytes >= 0 && total > maxCacheSizeBytes) {
        throw StateError('Video exceeds the configured browser cache size');
      }
      if (isPlaylist) {
        _validateKind('hls');
        final String text = (await response.blob.text().toDart).toDart;
        final WebHlsManifest manifest = WebHlsManifest(
          text,
          Uri.parse(response.base),
        );
        nodes[id]['text'] = text;
        for (final reference in manifest.references) {
          await visit(reference.uri, reference.playlist, depth + 1);
        }
      }
      visiting.remove(url);
      return id;
    }

    await visit(uri, kind == 'hls', 0);
    return _StoredMedia(manifest: jsonEncode(nodes), blobs: blobs.toJS);
  }

  Future<String> _lease(_StoredMedia entry) async {
    if (_disposed) throw StateError('Cache is disposed');
    final List<Object?> decoded = jsonDecode(entry.manifest) as List<Object?>;
    final List<Map<String, Object?>> nodes = decoded
        .map((Object? value) => (value! as Map<String, Object?>))
        .toList();
    final List<web.Blob> blobs = entry.blobs.toDart;
    final Map<String, int> indices = <String, int>{
      for (int i = 0; i < nodes.length; i++) nodes[i]['url']! as String: i,
    };
    final Map<String, String> sources = <String, String>{};
    final List<String> created = <String>[];
    final Set<int> active = <int>{};
    String materialize(int i) {
      final Map<String, Object?> node = nodes[i];
      final String url = node['url']! as String;
      final String? existing = sources[url];
      if (existing != null) return existing;
      if (!active.add(i)) throw const FormatException('Circular HLS cache');
      web.Blob blob = blobs[i];
      final String? text = node['text'] as String?;
      if (text != null) {
        _validateKind('hls');
        final WebHlsManifest manifest = WebHlsManifest(
          text,
          Uri.parse(node['base']! as String),
        );
        for (final reference in manifest.references) {
          final int? child = indices[reference.uri];
          if (child == null) {
            throw const FormatException('Incomplete HLS cache');
          }
          materialize(child);
        }
        blob = web.Blob(
          [manifest.rewrite(sources).toJS].toJS,
          web.BlobPropertyBag(type: 'application/vnd.apple.mpegurl'),
        );
      }
      final String source = web.URL.createObjectURL(blob);
      sources[url] = source;
      created.add(source);
      active.remove(i);
      return source;
    }

    try {
      final String source = materialize(0);
      _leases[source] = created;
      _leaseOwners[source] = this;
      return source;
    } catch (_) {
      for (final String source in created) {
        web.URL.revokeObjectURL(source);
      }
      rethrow;
    }
  }

  /// Fetches an authenticated media source without requiring persistent storage.
  /// The caller must release the returned blob URL after the player is disposed.
  Future<String> fetchSource(
    String uri, {
    required Map<String, String> headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) async {
    if (isLive) {
      throw UnsupportedError(
        'Live browser playback cannot use custom Fetch '
        'headers; use a signed URL or browser-managed authentication',
      );
    }
    return _lease(
      await _download(
        uri,
        headers,
        _kind(uri, formatHint),
        null,
        enforceLimit: false,
      ),
    );
  }

  /// Revokes this source and every blob referenced by its cached presentation.
  void releaseSource(String uri) {
    final List<String>? sources = _leases.remove(uri);
    if (sources == null) return;
    _leaseOwners.remove(uri);
    for (final String source in sources) {
      web.URL.revokeObjectURL(source);
    }
  }

  Future<void> _evict(web.IDBDatabase db) async {
    if (maxCacheSizeBytes < 0) return;
    final web.IDBTransaction read = db.transaction('metadata'.toJS);
    final JSArray<JSObject> result =
        (await _result(read.objectStore('metadata').getAll()))!
            as JSArray<JSObject>;
    final List<_Metadata> entries =
        result.toDart.map((JSObject entry) => _Metadata._(entry)).toList()
          ..sort(
            (_Metadata a, _Metadata b) => a.accessed.compareTo(b.accessed),
          );
    int total = entries.fold<int>(
      0,
      (int total, _Metadata entry) => total + entry.size,
    );
    if (total <= maxCacheSizeBytes) return;
    final web.IDBTransaction tx = db.transaction(
      ['media'.toJS, 'metadata'.toJS].toJS,
      'readwrite',
    );
    final Future<void> committed = _committed(tx);
    for (final _Metadata entry in entries) {
      if (total <= maxCacheSizeBytes) break;
      // Pending downloads live outside IndexedDB, so completed entries alone
      // count towards LRU and eviction cannot corrupt an active download.
      tx.objectStore('media').delete(entry.key.toJS);
      tx.objectStore('metadata').delete(entry.key.toJS);
      total -= entry.size;
    }
    await committed;
  }

  /// Deletes this entry and prevents its pending download from repopulating it,
  /// without interrupting any already leased playback.
  Future<void> remove(String uri, {String? cacheKey, VideoFormat? formatHint}) {
    final String key = _key(uri, cacheKey, formatHint);
    _entryEpochs[key] = (_entryEpochs[key] ?? 0) + 1;
    _downloads.remove(key);
    return _serialize(() async {
      final web.IDBDatabase db = await _open();
      final web.IDBTransaction tx = db.transaction(
        ['media'.toJS, 'metadata'.toJS].toJS,
        'readwrite',
      );
      final Future<void> committed = _committed(tx);
      tx.objectStore('media').delete(key.toJS);
      tx.objectStore('metadata').delete(key.toJS);
      await committed;
    });
  }

  /// Cancels pending downloads and deletes completed entries. Leased sources
  /// remain valid until [releaseSource], allowing current playback to continue.
  Future<void> clear() {
    _generation++;
    _downloads.clear();
    for (final MapEntry<web.AbortController, bool> request
        in _requests.entries.toList()) {
      if (request.value) {
        request.key.abort();
      }
    }
    return _serialize(() async {
      final web.IDBDatabase db = await _open();
      final web.IDBTransaction tx = db.transaction(
        ['media'.toJS, 'metadata'.toJS].toJS,
        'readwrite',
      );
      final Future<void> committed = _committed(tx);
      tx.objectStore('media').clear();
      tx.objectStore('metadata').clear();
      await committed;
    });
  }

  /// Total bytes in completed entries; in-progress responses are excluded.
  Future<int> totalSizeBytes() async {
    try {
      final web.IDBDatabase db = await _open();
      final web.IDBTransaction tx = db.transaction('metadata'.toJS);
      final JSArray<JSObject> result =
          (await _result(tx.objectStore('metadata').getAll()))!
              as JSArray<JSObject>;
      return result.toDart.fold<int>(
        0,
        (int total, JSObject entry) => total + _Metadata._(entry).size,
      );
    } catch (_) {
      return 0;
    }
  }

  /// Closes storage, cancels downloads and releases all temporary playback URLs.
  /// Stored entries remain available to a new instance with this namespace.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    for (final web.AbortController request in _requests.keys.toList()) {
      request.abort();
    }
    for (final String source in _leases.keys.toList()) {
      releaseSource(source);
    }
    _database?.close();
    _database = null;
    _opening = null;
  }
}
