import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_custom/video_player_custom.dart';

import 'windows_pip_test_support.dart';
import 'windows_mp4_test_support.dart';

void main() {
  if (!Platform.isWindows) return;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> mount(
    WidgetTester tester,
    VideoPlayerController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      ),
    );
    await controller.initialize().timeout(const Duration(seconds: 25));
    await controller.setVolume(0);
    await tester.pump();
  }

  testWidgets('Windows native PiP renders and controls the same player', (
    tester,
  ) async {
    final controller = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    addTearDown(controller.dispose);
    await mount(tester, controller);
    expect(controller.value.size.width, greaterThan(0));
    expect(controller.value.duration.inSeconds, greaterThan(0));
    await controller.setLooping(true);
    await controller.seekTo(const Duration(seconds: 1));
    await controller.play();
    await tester.pump(const Duration(milliseconds: 500));
    expect(await controller.position, greaterThan(const Duration(seconds: 1)));
    expect(await controller.isPipSupported(), isTrue);
    final originalSize = tester.view.physicalSize;
    final events = <PipModeChanged>[];
    final subscription = controller.onPipModeChanged.listen(events.add);
    addTearDown(subscription.cancel);

    expect(await controller.enterPipMode(width: 360, height: 240), isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(await controller.isInPipMode(), isTrue);
    expect(WindowsPipWindow.exists, isTrue);
    expect(WindowsPipWindow.isTopmost, isTrue);
    expect(WindowsPipWindow.size, (width: 360, height: 240));
    expect(WindowsPipWindow.hasVideoPixels, isTrue);
    expect(find.text('Picture in Picture'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(tester.view.physicalSize, originalSize);
    expect(events.where((event) => event.isInPip), hasLength(1));

    WindowsPipWindow.togglePlayback();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.value.isPlaying, isFalse);
    WindowsPipWindow.togglePlayback();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.value.isPlaying, isTrue);
    final window = WindowsPipWindow.handle;
    expect(await controller.enterPipMode(), isTrue);
    expect(WindowsPipWindow.handle, window);
    expect(await controller.exitPipMode(), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(WindowsPipWindow.exists, isFalse);
    expect(find.text('Picture in Picture'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(events.where((event) => event.isRestored), isEmpty);
    expect(controller.value.isPlaying, isTrue);
    expect(await controller.enterPipMode(width: -1), isFalse);

    expect(await controller.enterPipMode(), isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 200));
    // Native rendering continues after the inline Flutter video is unmounted.
    expect(await controller.isInPipMode(), isTrue);
    expect(WindowsPipWindow.hasVideoPixels, isTrue);
    WindowsPipWindow.restore();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await controller.isInPipMode(), isFalse);
    expect(WindowsPipWindow.exists, isFalse);
    final restored = events.where((event) => event.isRestored).toList();
    expect(restored, hasLength(1));
    expect(restored.single.position, isNotNull);
    expect(restored.single.position!.inMilliseconds, greaterThan(0));
    expect(controller.value.isPlaying, isFalse);
    expect(tester.view.physicalSize, originalSize);
  });

  testWidgets('Windows PiP downscaling preserves the paused frame colors', (
    tester,
  ) async {
    final controller = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    addTearDown(controller.dispose);
    await mount(tester, controller);
    await controller.play();
    await tester.pump(const Duration(milliseconds: 500));
    await controller.pause();
    await tester.pump(const Duration(milliseconds: 200));
    final aspect = controller.value.aspectRatio;
    final largeVideoHeight = (640 / aspect).round();
    final smallVideoHeight = (320 / aspect).round();
    expect(
      await controller.enterPipMode(width: 640, height: largeVideoHeight + 32),
      isTrue,
    );
    WindowsPipWindow.leavePointer();
    await tester.pump(const Duration(milliseconds: 2800));
    final points = <({int x, int y})>[
      for (var y = 1; y <= 10; y++)
        for (var x = 1; x <= 10; x++)
          (x: 320 * x ~/ 12, y: smallVideoHeight * y ~/ 12),
    ];
    final largePixels = WindowsPipWindow.samplePixels([
      for (final point in points)
        for (var dy = 0; dy < 2; dy++)
          for (var dx = 0; dx < 2; dx++)
            (x: point.x * 2 + dx, y: 32 + point.y * 2 + dy),
    ]);
    WindowsPipWindow.resize(320, smallVideoHeight + 32);
    await tester.pump(const Duration(milliseconds: 200));
    final smallPixels = WindowsPipWindow.samplePixels([
      for (final point in points) (x: point.x, y: 32 + point.y),
    ]);
    expect(largePixels, isNot(contains(0xffffffff)));
    expect(smallPixels, isNot(contains(0xffffffff)));
    expect(smallPixels.toSet().length, greaterThan(20));
    var error = 0.0;
    for (var i = 0; i < points.length; i++) {
      for (final shift in [0, 8, 16]) {
        var average = 0.0;
        for (var pixel = 0; pixel < 4; pixel++) {
          average += (largePixels[i * 4 + pixel] >> shift) & 0xff;
        }
        average /= 4;
        error += (average - ((smallPixels[i] >> shift) & 0xff)).abs();
      }
    }
    final meanError = error / (points.length * 3);
    expect(
      meanError,
      lessThan(10),
      reason: 'Downscale RGB mean error: $meanError',
    );
    expect(await controller.exitPipMode(), isTrue);
  });

  testWidgets('Windows PiP seeks paused frames and clamps skip and drag', (
    tester,
  ) async {
    final controller = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    addTearDown(controller.dispose);
    await mount(tester, controller);
    await controller.seekTo(const Duration(seconds: 1));
    expect(await controller.enterPipMode(width: 420, height: 300), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    final initialFrame = WindowsPipWindow.framePixels;
    final durationMs = controller.value.duration.inMilliseconds;

    WindowsPipWindow.seek(0.75);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      (await controller.position)!.inMilliseconds,
      closeTo(durationMs * 0.75, 150),
    );
    expect(controller.value.isPlaying, isFalse);
    expect(WindowsPipWindow.framePixels, isNot(initialFrame));

    WindowsPipWindow.skipSeconds(forward: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect((await controller.position)!.inMilliseconds, durationMs);
    WindowsPipWindow.skipSeconds(forward: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect((await controller.position)!.inMilliseconds, 0);
    expect(controller.value.isPlaying, isFalse);

    WindowsPipWindow.beginSeek(0.2);
    WindowsPipWindow.dragSeek(0.5);
    WindowsPipWindow.leavePointer();
    await tester.pump(const Duration(milliseconds: 100));
    final dragging = WindowsPipWindow.controlPixels;
    await tester.pump(const Duration(milliseconds: 2800));
    // Dragging previews the position without playing or committing each move.
    expect((await controller.position)!.inMilliseconds, 0);
    expect(controller.value.isPlaying, isFalse);
    expect(WindowsPipWindow.controlPixels, dragging);
    WindowsPipWindow.endSeek(1.2);
    await tester.pump(const Duration(milliseconds: 400));
    expect((await controller.position)!.inMilliseconds, durationMs);
    WindowsPipWindow.togglePlayback();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.value.isPlaying, isTrue);
    expect((await controller.position)!.inMilliseconds, lessThan(durationMs));
    WindowsPipWindow.skipSeconds(forward: true);
    await tester.pump(const Duration(milliseconds: 800));
    expect(controller.value.isPlaying, isFalse);
    expect(controller.value.isCompleted, isTrue);

    WindowsPipWindow.beginSeek(0.5);
    WindowsPipWindow.endSeek(-0.2);
    await tester.pump(const Duration(milliseconds: 400));
    expect((await controller.position)!.inMilliseconds, 0);
    WindowsPipWindow.beginSeek(0.8);
    WindowsPipWindow.cancelSeek();
    WindowsPipWindow.endSeek(0.8);
    await tester.pump(const Duration(milliseconds: 300));
    expect((await controller.position)!.inMilliseconds, 0);

    WindowsPipWindow.resize(256, 160);
    await tester.pump(const Duration(milliseconds: 150));
    WindowsPipWindow.seek(0.6);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      (await controller.position)!.inMilliseconds,
      closeTo(durationMs * 0.6, 150),
    );
    WindowsPipWindow.resize(180, 120);
    await tester.pump(const Duration(milliseconds: 150));
    WindowsPipWindow.togglePlayback();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value.isPlaying, isTrue);
    WindowsPipWindow.togglePlayback();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value.isPlaying, isFalse);
    expect(await controller.exitPipMode(), isTrue);
  });

  testWidgets('Windows PiP consecutive skips accumulate exactly ten seconds', (
    tester,
  ) async {
    final original = await rootBundle.load('assets/Butterfly-209.mp4');
    final directory = await Directory.systemTemp.createTemp('vpc_pip_seek_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/slow.mp4').writeAsBytes(
      stretchMp4Timeline(
        original.buffer.asUint8List(
          original.offsetInBytes,
          original.lengthInBytes,
        ),
      ),
    );
    final controller = VideoPlayerController.file(file);
    addTearDown(controller.dispose);
    await mount(tester, controller);
    expect(controller.value.duration.inSeconds, greaterThan(25));
    await controller.seekTo(const Duration(seconds: 2));
    expect(await controller.enterPipMode(width: 420, height: 300), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    WindowsPipWindow.skipSeconds(forward: true);
    WindowsPipWindow.skipSeconds(forward: true);
    await tester.pump(const Duration(milliseconds: 800));
    expect((await controller.position)!.inMilliseconds, 22000);
    expect(controller.value.isPlaying, isFalse);
    WindowsPipWindow.skipSeconds(forward: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect((await controller.position)!.inMilliseconds, 12000);
    WindowsPipWindow.skipSeconds(forward: false);
    WindowsPipWindow.skipSeconds(forward: false);
    await tester.pump(const Duration(milliseconds: 700));
    expect((await controller.position)!.inMilliseconds, 0);
    expect(controller.value.isPlaying, isFalse);
    expect(await controller.exitPipMode(), isTrue);
  });

  testWidgets('Windows PiP controls hide after leaving and show on reentry', (
    tester,
  ) async {
    final controller = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    addTearDown(controller.dispose);
    await mount(tester, controller);
    await controller.seekTo(const Duration(seconds: 2));
    expect(await controller.enterPipMode(width: 420, height: 300), isTrue);
    WindowsPipWindow.leavePointer();
    await tester.pump(const Duration(milliseconds: 2800));
    final hidden = WindowsPipWindow.controlPixels;
    WindowsPipWindow.movePointer(210, 64);
    await tester.pump(const Duration(milliseconds: 150));
    final visible = WindowsPipWindow.controlPixels;
    expect(visible, isNot(hidden));
    WindowsPipWindow.leavePointer();
    await tester.pump(const Duration(milliseconds: 400));
    expect(WindowsPipWindow.controlPixels, visible);
    await tester.pump(const Duration(milliseconds: 2400));
    expect(WindowsPipWindow.controlPixels, hidden);
    WindowsPipWindow.movePointer(210, 64);
    await tester.pump(const Duration(milliseconds: 150));
    expect(WindowsPipWindow.controlPixels, visible);
    expect(controller.value.isPlaying, isFalse);
    expect((await controller.position)!.inSeconds, 2);
    expect(await controller.exitPipMode(), isTrue);
  });

  testWidgets('Windows file and authenticated HTTP playback', (tester) async {
    final data = await rootBundle.load('assets/Butterfly-209.mp4');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final directory = await Directory.systemTemp.createTemp('vpc_windows_');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/video with spaces.mp4')
        .writeAsBytes(bytes);
    final local = VideoPlayerController.file(file);
    await mount(tester, local);
    expect(local.value.isInitialized, isTrue);
    await tester.pumpWidget(const SizedBox());
    await local.dispose();

    // Serving from Flutter's own isolate also checks that native creation
    // leaves the merged UI/platform thread responsive during network I/O.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final headers = <String?>[];
    server.listen((request) async {
      headers.add(request.headers.value('X-Video-Test'));
      if (headers.last != 'windows') {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
      }
      await request.response.close();
    });
    final network = VideoPlayerController.networkUrl(
      Uri.parse('http://127.0.0.1:${server.port}/video.mp4'),
      httpHeaders: {'X-Video-Test': 'windows'},
    );
    addTearDown(network.dispose);
    await mount(tester, network);
    expect(network.value.isInitialized, isTrue);
    expect(headers, isNotEmpty);
    expect(headers, everyElement('windows'));
  });

  testWidgets(
    'Windows PiP ownership, native close and reset release resources',
    (tester) async {
      final controller = VideoPlayerController.asset(
        'assets/Butterfly-209.mp4',
      );
      final other = VideoPlayerController.asset('assets/Butterfly-209.mp4');
      addTearDown(controller.dispose);
      addTearDown(other.dispose);
      expect(await controller.enterPipMode(), isFalse);
      await mount(tester, controller);
      await other.initialize().timeout(const Duration(seconds: 25));
      expect(await other.enterPipMode(), isTrue); // A mounted view is optional.
      expect(await controller.enterPipMode(), isFalse);
      await other.dispose();
      await tester.pump(const Duration(milliseconds: 200));
      expect(await VideoPlayerPip.isInPipMode(), isFalse);
      expect(WindowsPipWindow.exists, isFalse);

      final observer = VideoPlayerController.asset('assets/Butterfly-209.mp4');
      addTearDown(observer.dispose);
      await observer.initialize();
      expect(await controller.enterPipMode(), isTrue);
      await observer.dispose();
      expect(await controller.isInPipMode(), isTrue);
      await controller.play();
      await tester.pump(const Duration(milliseconds: 200));
      WindowsPipWindow.closeButton();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await controller.isInPipMode(), isFalse);
      expect(controller.value.isPlaying, isFalse);
      expect(WindowsPipWindow.exists, isFalse);

      expect(await controller.enterPipMode(), isTrue);
      await controller.play();
      WindowsPipWindow.close();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await controller.isInPipMode(), isFalse);
      expect(controller.value.isPlaying, isFalse);
      expect(await controller.enterPipMode(), isTrue);
      await controller.play();
      await VideoPlayerPip.reset();
      await VideoPlayerPip.reset();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value.isPlaying, isFalse);
      expect(WindowsPipWindow.exists, isFalse);
      expect(await controller.enterPipMode(), isTrue);
      await controller.dispose();
      expect(await VideoPlayerPip.isInPipMode(), isFalse);
      expect(WindowsPipWindow.exists, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Windows cache miss downloads and cache hit plays fully offline',
    (tester) async {
      final originalCache = VideoPlayerCache.instance;
      final directory = await Directory.systemTemp.createTemp(
        'vpc_windows_cache_',
      );
      final cache = VideoPlayerCache(directory);
      VideoPlayerCache.instance = cache;
      addTearDown(() async {
        VideoPlayerCache.instance = originalCache;
        await directory.delete(recursive: true);
      });
      final data = await rootBundle.load('assets/Butterfly-209.mp4');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/video.mp4');
      // URI-shaped keys must also be valid filenames on Windows.
      final key = uri.toString();
      final first = VideoPlayerController.networkUrl(uri, cacheKey: key);
      addTearDown(first.dispose);
      await mount(tester, first);
      await first.play();
      await tester.pump(const Duration(milliseconds: 300));
      await cache.prefetch(uri.toString(), cacheKey: key);
      final cached = await cache.fileFor(uri.toString(), cacheKey: key);
      expect(cached, isNotNull);
      expect(await cached!.length(), bytes.length);
      expect(requests, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await first.dispose();
      await server.close(force: true);
      final requestsBeforeOffline = requests;

      final offline = VideoPlayerController.networkUrl(uri, cacheKey: key);
      addTearDown(offline.dispose);
      await mount(tester, offline);
      expect(offline.value.isInitialized, isTrue);
      await offline.seekTo(const Duration(seconds: 1));
      await offline.play();
      await tester.pump(const Duration(milliseconds: 500));
      expect(await offline.position, greaterThan(const Duration(seconds: 1)));
      expect(await offline.enterPipMode(), isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(WindowsPipWindow.hasVideoPixels, isTrue);
      expect(await offline.exitPipMode(), isTrue);
      expect(requests, requestsBeforeOffline);
      await tester.pumpWidget(const SizedBox());
      await offline.dispose();
    },
  );

  testWidgets('Windows reports load errors and can dispose failed sources', (
    tester,
  ) async {
    final controller = VideoPlayerController.file(
      File(
        '${Directory.systemTemp.path}/missing-${DateTime.now().microsecondsSinceEpoch}.mp4',
      ),
    );
    addTearDown(controller.dispose);
    await expectLater(
      controller.initialize().timeout(const Duration(seconds: 25)),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.value.hasError, isTrue);
    expect(await controller.enterPipMode(), isFalse);
    await controller.dispose().timeout(const Duration(seconds: 3));
  });
}
