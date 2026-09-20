import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_custom/video_player_custom.dart';

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
    await controller.initialize().timeout(const Duration(seconds: 20));
    await controller.setVolume(0);
    await tester.pump();
  }

  testWidgets('Windows playback, compact PiP controls and window restoration', (
    tester,
  ) async {
    final controller = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    addTearDown(controller.dispose);
    await mount(tester, controller);
    expect(controller.value.size.width, greaterThan(0));
    expect(controller.value.duration.inSeconds, greaterThan(0));
    await controller.setLooping(true);
    await controller.setPlaybackSpeed(1.5);
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
    expect(tester.view.physicalSize.width, lessThan(originalSize.width));
    expect(find.byTooltip('Restore window'), findsOneWidget);
    expect(events.any((event) => event.isInPip), isTrue);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value.isPlaying, isFalse);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value.isPlaying, isTrue);
    // Re-entering is idempotent and must preserve the original placement.
    expect(await controller.enterPipMode(), isTrue);
    await tester.tap(find.byTooltip('Restore window'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(await controller.isInPipMode(), isFalse);
    expect(tester.view.physicalSize, originalSize);
    expect(find.byTooltip('Restore window'), findsNothing);
    expect(events.any((event) => event.isRestored), isTrue);
    expect(controller.value.isPlaying, isTrue);
    expect(await controller.enterPipMode(width: -1), isFalse);
    expect(await controller.enterPipMode(), isTrue);
    await tester.pump();
    // Removing the video while in PiP must also restore the native window.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 500));
    expect(await controller.isInPipMode(), isFalse);
    expect(tester.view.physicalSize, originalSize);
  });

  testWidgets('Windows file and HTTP playback with request headers', (
    tester,
  ) async {
    final data = await rootBundle.load('assets/Butterfly-209.mp4');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final directory = await Directory.systemTemp.createTemp(
      'video_player_windows_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/video with spaces.mp4',
    ).writeAsBytes(bytes);
    final local = VideoPlayerController.file(file);
    await mount(tester, local);
    expect(local.value.isInitialized, isTrue);
    await tester.pumpWidget(const SizedBox());
    await local.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final headers = <String?>[];
    server.listen((request) async {
      headers.add(request.headers.value('X-Video-Test'));
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final network = VideoPlayerController.networkUrl(
      Uri.parse('http://127.0.0.1:${server.port}/video.mp4'),
      httpHeaders: {'X-Video-Test': 'windows'},
    );
    addTearDown(network.dispose);
    await mount(tester, network);
    expect(network.value.isInitialized, isTrue);
    expect(headers, contains('windows'));
  });

  testWidgets(
    'Windows PiP rejects unmounted players and cleans up on disposal',
    (tester) async {
      final controller = VideoPlayerController.asset(
        'assets/Butterfly-209.mp4',
      );
      final other = VideoPlayerController.asset('assets/Butterfly-209.mp4');
      addTearDown(controller.dispose);
      addTearDown(other.dispose);
      expect(await controller.enterPipMode(), isFalse);
      await mount(tester, controller);
      await other.initialize().timeout(const Duration(seconds: 20));
      expect(await other.enterPipMode(), isFalse);
      final originalSize = tester.view.physicalSize;
      expect(await controller.enterPipMode(), isTrue);
      await tester.pump();
      expect(await other.enterPipMode(), isFalse);
      expect(await controller.isInPipMode(), isTrue);
      await controller.dispose();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await VideoPlayerPip.isInPipMode(), isFalse);
      expect(tester.view.physicalSize, originalSize);
      await VideoPlayerPip.reset();
      await VideoPlayerPip.reset();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Windows reports load errors instead of hanging initialization', (
    tester,
  ) async {
    final controller = VideoPlayerController.file(
      File(
        '${Directory.systemTemp.path}/missing-video-${DateTime.now().microsecondsSinceEpoch}.mp4',
      ),
    );
    addTearDown(controller.dispose);
    await expectLater(
      controller.initialize().timeout(const Duration(seconds: 15)),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.value.hasError, isTrue);
    expect(await controller.enterPipMode(), isFalse);
  });
}
