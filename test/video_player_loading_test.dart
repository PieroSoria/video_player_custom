import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_player_test.dart' show FakeController, FakeVideoPlayerPlatform;

void main() {
  late VideoPlayerPlatform originalPlatform;
  late FakeController controller;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    controller = FakeController();
  });

  tearDown(() async {
    await controller.dispose();
    VideoPlayerPlatform.instance = originalPlatform;
  });

  Widget player() => Directionality(
    textDirection: TextDirection.ltr,
    child: VideoPlayer(
      controller,
      loadingBuilder: (_, progress) => Text('Loading: $progress'),
      errorBuilder: (_, error) => Text('Error: $error'),
    ),
  );

  for (final fails in [false, true]) {
    testWidgets(
      'mounted iOS player handles initialize() ${fails ? 'failure' : 'completion'} without a parent rebuild',
      (tester) async {
        (VideoPlayerPlatform.instance as FakeVideoPlayerPlatform)
                .forceInitError =
            fails;
        final actual = VideoPlayerController.networkUrl(
          Uri.parse('https://example.com/video.mp4'),
          viewType: VideoViewType.platformView,
        );
        addTearDown(actual.dispose);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: VideoPlayer(
              actual,
              loadingBuilder: (_, progress) => const Text('Loading'),
              errorBuilder: (_, error) => const Text('Playback failed'),
            ),
          ),
        );
        expect(find.text('Loading'), findsOneWidget);

        await tester.runAsync(() async {
          final initialization = actual.initialize();
          if (fails) {
            await expectLater(initialization, throwsA(isA<Exception>()));
          } else {
            await initialization;
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('Loading'), findsNothing);
        expect(
          find.text('Playback failed'),
          fails ? findsOneWidget : findsNothing,
        );
        expect(find.byType(Texture), fails ? findsNothing : findsOneWidget);
      },
      variant: TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  testWidgets('iOS replaces initial loading when the same player becomes ready', (
    tester,
  ) async {
    await tester.pumpWidget(player());
    expect(find.text('Loading: null'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    controller.playerId = 7;
    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump();
    final videoElement = tester.element(find.byType(Texture));

    controller.value = controller.value.copyWith(
      isInitialized: true,
      duration: const Duration(seconds: 10),
      isBuffering: false,
    );
    await tester.pump();
    // Loading remains during the fade, then disappears without replacing video.
    expect(find.text('Loading: null'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 125));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Loading: null'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('Loading: null'), findsNothing);
    expect(tester.element(find.byType(Texture)), same(videoElement));
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('iOS updates buffering progress and reveals the existing video', (
    tester,
  ) async {
    controller.playerId = 7;
    controller.value = controller.value.copyWith(
      isInitialized: true,
      duration: const Duration(seconds: 10),
    );
    await tester.pumpWidget(player());
    final videoElement = tester.element(find.byType(Texture));

    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pumpAndSettle();
    expect(find.text('Loading: null'), findsOneWidget);

    controller.value = controller.value.copyWith(
      buffered: [DurationRange(Duration.zero, const Duration(seconds: 5))],
    );
    await tester.pump();
    expect(find.text('Loading: 0.5'), findsOneWidget);

    controller.value = controller.value.copyWith(isBuffering: false);
    await tester.pumpAndSettle();
    expect(find.text('Loading: 0.5'), findsNothing);
    expect(tester.element(find.byType(Texture)), same(videoElement));
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets(
    'rapid iOS buffering reversals keep one loading layer and the native view',
    (tester) async {
      controller.playerId = 7;
      controller.value = controller.value.copyWith(
        isInitialized: true,
        isBuffering: true,
        duration: const Duration(seconds: 10),
      );
      await tester.pumpWidget(player());
      final videoElement = tester.element(find.byType(Texture));
      for (var i = 0; i < 10; i++) {
        controller.value = controller.value.copyWith(isBuffering: i.isOdd);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        expect(tester.takeException(), isNull);
        expect(find.text('Loading: null'), findsOneWidget);
        expect(tester.element(find.byType(Texture)), same(videoElement));
      }
      controller.value = controller.value.copyWith(isBuffering: false);
      await tester.pumpAndSettle();
      expect(find.text('Loading: null'), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'changing iOS controller during fade does not duplicate the loading layer',
    (tester) async {
      controller.playerId = 7;
      controller.value = controller.value.copyWith(isInitialized: true, isBuffering: true);
      await tester.pumpWidget(player());
      controller.value = controller.value.copyWith(isBuffering: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      final oldController = controller;
      controller = FakeController();
      await tester.pumpWidget(player());
      await oldController.dispose();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull);
      expect(find.text('Loading: null'), findsOneWidget);

      controller.playerId = 8;
      controller.value = controller.value.copyWith(isInitialized: true);
      await tester.pumpAndSettle();
      expect(find.text('Loading: null'), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 8);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'initialization errors replace loading before a player ID exists',
    (tester) async {
      await tester.pumpWidget(player());
      controller.value = VideoPlayerValue.erroneous('Cannot open video');
      await tester.pump();
      expect(find.text('Loading: null'), findsNothing);
      expect(find.text('Error: Cannot open video'), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
