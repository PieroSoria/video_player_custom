// Run on a physical iPhone; native PiP is entered through a Flutter button.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_custom/video_player_custom.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS PiP owns its source and reset preserves its video', (
    tester,
  ) async {
    final source = VideoPlayerController.asset(
      'assets/Butterfly-209.mp4',
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    final unrelated = VideoPlayerController.asset('assets/Butterfly-209.mp4');
    final entered = Completer<bool>();
    final stopped = Completer<void>();
    var unrelatedDisposed = false;
    final subscription = source.onPipModeChanged.listen((event) {
      if (!event.isInPip && !stopped.isCompleted) stopped.complete();
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: VideoPlayer(source),
              ),
            ),
            floatingActionButton: FloatingActionButton(
              key: const Key('enter-pip'),
              onPressed: () async {
                try {
                  entered.complete(await source.enterPipMode());
                } catch (error, stack) {
                  entered.completeError(error, stack);
                }
              },
              child: const Icon(Icons.picture_in_picture_alt),
            ),
          ),
        ),
      );
      await source.initialize().timeout(const Duration(seconds: 30));
      await source.setLooping(true);
      await source.setVolume(0);
      await source.play();
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      expect(await source.isPipSupported(), isTrue);
      await tester.tap(find.byKey(const Key('enter-pip')));
      expect(await entered.future.timeout(const Duration(seconds: 10)), isTrue);
      expect(await source.isInPipMode(), isTrue);

      await unrelated.initialize();
      await unrelated.dispose();
      unrelatedDisposed = true;
      expect(
        await source.isInPipMode(),
        isTrue,
        reason: 'Disposing another player must not reset the PiP source',
      );

      await VideoPlayerPip.reset();
      // Repeated reset must not remove the delegate before its final event.
      await VideoPlayerPip.reset();
      await stopped.future.timeout(const Duration(seconds: 10));
      expect(await source.isInPipMode(), isFalse);
      await platform.VideoPlayerPlatform.instance.setPlaybackSpeed(
        source.playerId,
        1,
      );
      // Let AVKit finish any pending seek when returning the inline layer.
      await Future<void>.delayed(const Duration(seconds: 1));
      final pausedPosition = await source.position;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(source.value.isPlaying, isFalse);
      expect(await source.position, pausedPosition);
      expect(source.value.isInitialized, isTrue);
      await source.seekTo(Duration.zero);
      await source.play();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        await source.position,
        greaterThan(Duration.zero),
        reason: 'Reset must not remove the source video item',
      );
    } finally {
      await subscription.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      await source.dispose();
      if (!unrelatedDisposed) await unrelated.dispose();
      await VideoPlayerPip.reset();
    }
  });
}
