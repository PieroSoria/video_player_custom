// Run on a physical iPhone to exercise cached HLS through AVFoundation.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_custom/video_player_custom.dart';

// Flutter's small HLS fixture contains three TS segments and about four seconds
// of video. Assets are fetched during setup rather than added to the repository.
final _fixtureUri = Uri.parse(
  'https://flutter.github.io/assets-for-api-docs/assets/videos/hls/bee.m3u8',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late _HlsFixture fixture;

  setUpAll(() async {
    if (Platform.isIOS) fixture = await _HlsFixture.download();
  });

  testWidgets(
    'iOS caches extensionless HLS and live bypasses an existing cache entry',
    (tester) async {
      await _checkOfflinePlayback(
        tester,
        fixture,
        manifestPath: '/playback',
        formatHint: VideoFormat.hls,
        verifyLiveBypass: true,
      );
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'iOS caches HLS URLs with a query token without a format hint',
    (tester) async {
      await _checkOfflinePlayback(tester, fixture, manifestPath: '/bee.m3u8');
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _checkOfflinePlayback(
  WidgetTester tester,
  _HlsFixture fixture, {
  required String manifestPath,
  VideoFormat? formatHint,
  bool verifyLiveBypass = false,
}) async {
  final previousCache = VideoPlayerCache.instance;
  final cacheDirectory = await Directory.systemTemp.createTemp(
    'ios_hls_cache_',
  );
  final cache = VideoPlayerCache(cacheDirectory);
  VideoPlayerCache.instance = cache;
  final origin = await _HlsOrigin.start(fixture, manifestPath);
  final source = origin.uri.replace(queryParameters: {'token': 'signed-video'});
  const cacheKey = 'offline-hls';
  VideoPlayerController? controller;

  try {
    await cache
        .warm(source.toString(), cacheKey: cacheKey, formatHint: formatHint)
        .timeout(const Duration(seconds: 30));
    expect(
      await cache.have(
        source.toString(),
        cacheKey: cacheKey,
        formatHint: formatHint,
      ),
      isTrue,
    );

    if (verifyLiveBypass) {
      final beforeLive = origin.manifestRequests;
      // A VOD fixture opened with isLive deliberately isolates the option's
      // behavior: even an existing entry with this same key must be ignored.
      controller = VideoPlayerController.networkUrl(
        source,
        cacheKey: cacheKey,
        formatHint: formatHint,
        isLive: true,
      );
      await _playAndCheckProgress(tester, controller);
      expect(
        origin.manifestRequests,
        greaterThan(beforeLive),
        reason:
            'isLive must stream from the origin instead of the cached entry',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
      controller = null;
    }

    // Shut down the only origin that serves these URLs. The next native player
    // can initialize and advance only if the complete cached presentation works.
    await origin.close();
    controller = VideoPlayerController.networkUrl(
      source,
      cacheKey: cacheKey,
      formatHint: formatHint,
    );
    await _playAndCheckProgress(tester, controller);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await controller?.dispose();
    await origin.close();
    VideoPlayerCache.instance = previousCache;
    await cacheDirectory.delete(recursive: true);
  }
}

Future<void> _playAndCheckProgress(
  WidgetTester tester,
  VideoPlayerController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    ),
  );
  await controller.initialize().timeout(const Duration(seconds: 30));
  expect(controller.value.isInitialized, isTrue);
  expect(controller.value.duration, greaterThan(Duration.zero));
  await controller.setVolume(0);
  await controller.play();
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await tester.pump();
  expect(controller.value.hasError, isFalse);
  expect(
    await controller.position,
    greaterThan(const Duration(milliseconds: 500)),
    reason: 'AVFoundation must decode and advance the cached HLS video',
  );
}

class _HlsFixture {
  _HlsFixture(this.manifest, this.segments);

  final String manifest;
  final Map<String, Uint8List> segments;

  static Future<_HlsFixture> download() async {
    final client = HttpClient();
    try {
      final manifest = utf8.decode(await _fetch(client, _fixtureUri));
      if (!manifest.startsWith('#EXTM3U') ||
          !manifest.contains('#EXT-X-ENDLIST')) {
        throw const FormatException('The Flutter fixture must be finite HLS');
      }
      final segments = <String, Uint8List>{};
      for (final line in manifest.split('\n')) {
        final name = line.trim();
        if (name.isEmpty || name.startsWith('#')) continue;
        segments['/$name'] = await _fetch(client, _fixtureUri.resolve(name));
      }
      return _HlsFixture(manifest, segments);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _fetch(HttpClient client, Uri uri) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 30));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Fixture GET failed: ${response.statusCode}',
        uri: uri,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

class _HlsOrigin {
  _HlsOrigin(this.server, this.fixture, this.manifestPath);

  final HttpServer server;
  final _HlsFixture fixture;
  final String manifestPath;
  int manifestRequests = 0;
  bool _closed = false;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}$manifestPath');

  static Future<_HlsOrigin> start(
    _HlsFixture fixture,
    String manifestPath,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _HlsOrigin(server, fixture, manifestPath);
    server.listen((request) async {
      try {
        await origin._handleRequest(request);
      } on SocketException {
        // AVFoundation can cancel requests when a player is disposed.
      } on HttpException {
        // The origin is deliberately closed before the offline player opens.
      }
    });
    return origin;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == manifestPath) {
      manifestRequests += 1;
      response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
      response.write(fixture.manifest);
      await response.close();
      return;
    }
    final segment = fixture.segments[request.uri.path];
    if (segment == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.headers.set('Content-Type', 'video/mp2t');
    response.headers.set('Accept-Ranges', 'bytes');
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (match != null) {
      final start = int.parse(match.group(1)!);
      final requestedEnd = int.tryParse(match.group(2)!);
      final end = requestedEnd == null || requestedEnd >= segment.length
          ? segment.length - 1
          : requestedEnd;
      if (start >= segment.length || end < start) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        'Content-Range',
        'bytes $start-$end/${segment.length}',
      );
      response.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        response.add(segment.sublist(start, end + 1));
      }
    } else {
      response.contentLength = segment.length;
      if (request.method != 'HEAD') {
        response.add(segment);
      }
    }
    await response.close();
  }
}
