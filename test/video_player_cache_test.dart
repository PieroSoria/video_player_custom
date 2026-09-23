import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_custom/src/cache/video_player_cache.dart';

void main() {
  late Directory tempDir;
  late VideoPlayerCache cache;
  late _RecordingPlatform fakePlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_test_');
    cache = VideoPlayerCache(tempDir);
    VideoPlayerCache.instance = cache;
    fakePlatform = _RecordingPlatform();
    VideoPlayerPlatform.instance = fakePlatform;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<HttpServer> serve(List<int> body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.binary
        ..add(body);
      request.response.close();
    }, onError: (_) {});
    return server;
  }

  String uri(HttpServer server) =>
      'http://${server.address.address}:${server.port}/media/clip.mp4';

  test('prefetch downloads to disk and reuses the entry', () async {
    final body = Uint8List.fromList(utf8.encode('fake-mp4-bytes'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    expect(await cache.have(url, cacheKey: 'alpha'), isFalse);
    await cache.prefetch(url, cacheKey: 'alpha');
    expect(await cache.have(url, cacheKey: 'alpha'), isTrue);

    final file = await cache.fileFor(url, cacheKey: 'alpha');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), body);

    // A second prefetch does not re-download (the file already exists).
    await cache.prefetch(url, cacheKey: 'alpha');
    expect(await cache.fileFor(url, cacheKey: 'alpha'), isNotNull);
  });

  test('prefetch forwards http headers to the server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? receivedToken;
    server.listen((request) {
      receivedToken = request.headers.value('x-token');
      request.response
        ..add(List<int>.filled(8, 1))
        ..close();
    }, onError: (_) {});
    addTearDown(server.close);

    await cache.prefetch(
      uri(server),
      cacheKey: 'headers',
      headers: const <String, String>{'x-token': 'abc123'},
    );
    expect(receivedToken, 'abc123');
  });

  test('download failure leaves no partial file behind', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    }, onError: (_) {});
    addTearDown(server.close);

    await expectLater(
      cache.prefetch(uri(server), cacheKey: 'broken'),
      throwsA(isA<HttpException>()),
    );
    expect(await cache.have(uri(server), cacheKey: 'broken'), isFalse);
    final leftovers = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });

  test('concurrent prefetches of the same entry share one download', () async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      hits++;
      request.response
        ..headers.contentType = ContentType.binary
        ..add(List<int>.filled(8 * 1024, 7));
      request.response.close();
    }, onError: (_) {});
    addTearDown(server.close);
    final url = uri(server);

    await Future.wait([
      cache.prefetch(url, cacheKey: 'shared'),
      cache.prefetch(url, cacheKey: 'shared'),
      cache.prefetch(url, cacheKey: 'shared'),
    ]);
    expect(hits, 1);
  });

  test('LRU eviction removes the oldest entry over the limit', () async {
    final server = await serve(List<int>.filled(1024, 1));
    addTearDown(server.close);
    final url = uri(server);

    final small = VideoPlayerCache(tempDir, maxCacheSizeBytes: 2048);
    await small.prefetch(url, cacheKey: 'first');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await small.prefetch(url, cacheKey: 'second');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await small.prefetch(url, cacheKey: 'third');

    expect(await small.have(url, cacheKey: 'third'), isTrue);
    expect(await small.have(url, cacheKey: 'second'), isTrue);
    // Oldest entry was evicted to stay under the 2 KiB budget (3 x 1 KiB).
    expect(await small.have(url, cacheKey: 'first'), isFalse);
  });

  test('hash-derived key is stable and extension is preserved', () async {
    final body = Uint8List.fromList(utf8.encode('x'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    await cache.prefetch(url);
    final byHash = await cache.fileFor(url);
    expect(byHash, isNotNull);
    expect(byHash!.path, endsWith('.mp4'), reason: 'keeps the .mp4 suffix');

    final again = await cache.fileFor(url);
    expect(again!.path, byHash.path, reason: 'same hash every time');
  });

  test('initialize() uses the cached local file when one exists', () async {
    final body = Uint8List.fromList(utf8.encode('cached-video'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    // Prime the cache first.
    await cache.prefetch(url, cacheKey: 'mine');
    final cachedFile = await cache.fileFor(url, cacheKey: 'mine');

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      cacheKey: 'mine',
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    await controller.dispose();

    expect(fakePlatform.dataSources, isNotEmpty);
    final sent = fakePlatform.dataSources.last;
    expect(sent.uri, cachedFile!.uri.toString());
    expect(sent.httpHeaders, isEmpty);
  });

  test('initialize() streams from the network and prefetches on a miss',
      () async {
    final server = await serve(List<int>.filled(64, 1));
    addTearDown(server.close);
    final url = uri(server);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      cacheKey: 'cold',
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    // Playback used the network URL itself, with headers passed through.
    expect(fakePlatform.dataSources.last.uri, url);
    // The background prefetch completes on its own.
    await cache.warm(url, cacheKey: 'cold');
    expect(await cache.have(url, cacheKey: 'cold'), isTrue);
    await controller.dispose();
  });
}

class _RecordingPlatform extends VideoPlayerPlatform {
  final List<DataSource> dataSources = <DataSource>[];
  int _nextPlayerId = 0;
  final Map<int, StreamController<VideoEvent>> _streams =
      <int, StreamController<VideoEvent>>{};

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final StreamController<VideoEvent> stream = StreamController<VideoEvent>();
    _streams[_nextPlayerId] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(100, 100),
        duration: const Duration(seconds: 1),
      ),
    );
    dataSources.add(options.dataSource);
    return _nextPlayerId++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return _streams[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await _streams.remove(playerId)?.close();
  }
}