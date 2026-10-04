import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_custom/video_player_custom.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Native PiP entry/exit is checked in basic.dart with a visible macOS window.
  // The integration binding supplies an unattached, zero-size AVPlayerLayer.
  testWidgets("macOS PiP queries and reset work without a native view", (
    tester,
  ) async {
    final controller = VideoPlayerController.asset(
      "assets/Butterfly-209.mp4",
      viewType: VideoViewType.textureView,
    );
    try {
      await controller.initialize();
      expect(await controller.isPipSupported(), isTrue);
      expect(await controller.isInPipMode(), isFalse);
      expect(await controller.enterPipMode(), isFalse);
      await VideoPlayerPip.reset();
      expect(await controller.isInPipMode(), isFalse);
      expect(controller.value.isInitialized, isTrue);
    } finally {
      await controller.dispose();
    }
  });

  for (final viewType in VideoViewType.values) {
    testWidgets('macOS plays and switches videos with $viewType', (
      tester,
    ) async {
      for (var index = 0; index < 2; index++) {
        final controller = VideoPlayerController.asset(
          'assets/Butterfly-209.mp4',
          viewType: viewType,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 640,
                  height: 360,
                  child: VideoPlayer(
                    controller,
                    loadingBuilder: (_, progress) =>
                        const Text('Loading video'),
                    errorBuilder: (_, error) => Text('Playback error: $error'),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Loading video'), findsOneWidget);
        try {
          await controller.initialize().timeout(const Duration(seconds: 30));
          await controller.setVolume(0);
          await controller.play();
          await tester.pumpAndSettle();
          await Future<void>.delayed(const Duration(seconds: 1));
          await tester.pump();
          expect(controller.value.hasError, isFalse);
          expect(controller.value.isInitialized, isTrue);
          expect(await controller.position, greaterThan(Duration.zero));
          expect(find.text('Loading video'), findsNothing);
          if (viewType == VideoViewType.platformView) {
            expect(find.byType(AppKitView), findsOneWidget);
          } else {
            expect(find.byType(Texture), findsOneWidget);
          }
          await controller.pause();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await controller.dispose();
        }
      }
    });
  }
}
