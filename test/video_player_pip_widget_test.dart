import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player_custom/src/pip/pip_state.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_player_test.dart' show FakeVideoPlayerPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('video_player_pip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late VideoPlayerPlatform originalPlatform;
  late FakeVideoPlayerPlatform backend;
  late List<VideoPlayerController> controllers;
  Future<bool> Function(int)? enterResponse;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    backend = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = backend;
    controllers = <VideoPlayerController>[];
    enterResponse = null;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'enterPipMode' && enterResponse != null) {
        return enterResponse!(
          (call.arguments as Map<dynamic, dynamic>)['playerId'] as int,
        );
      }
      return call.method == 'reset' ? null : true;
    });
    VideoPlayerPip.instance;
  });

  tearDown(() async {
    for (final controller in controllers) {
      await controller.dispose();
    }
    VideoPlayerPip.instance.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    VideoPlayerPlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<VideoPlayerController> createController(WidgetTester tester) async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/video.mp4'),
    );
    controllers.add(controller);
    await tester.runAsync(controller.initialize);
    return controller;
  }

  Widget view(VideoPlayerController controller, {Key? key}) => Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      width: 320,
      height: 180,
      child: VideoPlayer(controller, key: key),
    ),
  );

  Future<void> nativeEvent(
    WidgetTester tester,
    String method,
    Map<String, Object> args,
  ) async {
    unawaited(
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        null,
      ),
    );
    await tester.pump();
  }

  Future<void> mode(
    WidgetTester tester,
    VideoPlayerController controller,
    bool entered,
  ) => nativeEvent(tester, 'pipModeChanged', <String, Object>{
    'playerId': controller.playerId,
    'isInPipMode': entered,
  });

  void pipWidgetTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  pipWidgetTest(
    'Windows automatically replaces only the owner without subscribers',
    (tester) async {
      final owner = await createController(tester);
      final other = await createController(tester);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: <Widget>[view(owner), view(other)]),
        ),
      );
      final int pauseCalls = backend.calls
          .where((call) => call == 'pause')
          .length;

      expect(await VideoPlayerPip.enterPipMode(owner), isTrue);
      await tester.pump();
      expect(find.text('Picture in Picture'), findsOneWidget);
      expect(find.byType(Texture), findsOneWidget);
      expect(
        tester.widget<Texture>(find.byType(Texture)).textureId,
        other.playerId,
      );
      expect(
        backend.calls.where((call) => call == 'pause'),
        hasLength(pauseCalls),
      );
    },
  );

  pipWidgetTest(
    'native callbacks replace an already mounted owner without subscribers',
    (tester) async {
      final owner = await createController(tester);
      await tester.pumpWidget(view(owner));
      await mode(tester, owner, true);
      expect(find.text('Picture in Picture'), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      await mode(tester, owner, false);
      expect(find.text('Picture in Picture'), findsNothing);
      expect(find.byType(Texture), findsOneWidget);
    },
  );

  pipWidgetTest(
    'restore restores inline rendering and emits one identified close',
    (tester) async {
      final owner = await createController(tester);
      final List<PipModeChanged> events = <PipModeChanged>[];
      final subscription = VideoPlayerPip.instance.onPipModeChanged.listen(
        events.add,
      );
      addTearDown(subscription.cancel);
      await tester.pumpWidget(view(owner));
      await mode(tester, owner, true);
      await nativeEvent(tester, 'onPipRestore', <String, Object>{
        'playerId': owner.playerId,
        'positionMs': 350,
      });

      await mode(tester, owner, false);

      expect(find.byType(Texture), findsOneWidget);
      expect(events, hasLength(2));
      expect(events.last.isRestored, isTrue);
      expect(events.last.playerId, owner.playerId);
      expect(events.last.position, const Duration(milliseconds: 350));
    },
  );

  for (final reset in <bool>[false, true]) {
    pipWidgetTest(
      '${reset ? 'reset' : 'exit'} restores inline without native callbacks',
      (tester) async {
        final owner = await createController(tester);
        await tester.pumpWidget(view(owner));
        await VideoPlayerPip.enterPipMode(owner);
        await tester.pump();
        expect(find.byType(Texture), findsNothing);
        if (reset) {
          await VideoPlayerPip.reset();
        } else {
          expect(await VideoPlayerPip.exitPipMode(), isTrue);
        }
        await tester.pump();
        expect(find.text('Picture in Picture'), findsNothing);
        expect(find.byType(Texture), findsOneWidget);
      },
    );
  }

  pipWidgetTest(
    'a stale close for another player cannot clear the current owner',
    (tester) async {
      final first = await createController(tester);
      final owner = await createController(tester);
      await tester.pumpWidget(view(owner));
      await mode(tester, first, true);
      await mode(tester, owner, true);
      await mode(tester, first, false);
      expect(pipPlayerId.value, owner.playerId);
      expect(find.text('Picture in Picture'), findsOneWidget);
    },
  );

  pipWidgetTest('controller swaps use the ownership of the new controller', (
    tester,
  ) async {
    final owner = await createController(tester);
    final other = await createController(tester);
    const key = ValueKey<String>('video');
    await tester.pumpWidget(view(owner, key: key));
    await VideoPlayerPip.enterPipMode(owner);
    await tester.pump();
    await tester.pumpWidget(view(other, key: key));
    expect(find.text('Picture in Picture'), findsNothing);
    expect(
      tester.widget<Texture>(find.byType(Texture)).textureId,
      other.playerId,
    );
    await tester.pumpWidget(view(owner, key: key));
    expect(find.text('Picture in Picture'), findsOneWidget);
  });

  pipWidgetTest('views mounted after entry also show the owner placeholder', (
    tester,
  ) async {
    final owner = await createController(tester);
    await VideoPlayerPip.enterPipMode(owner);
    await tester.pumpWidget(view(owner));
    expect(find.text('Picture in Picture'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
  });

  pipWidgetTest('every inline view of the same owner uses the placeholder', (
    tester,
  ) async {
    final owner = await createController(tester);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: <Widget>[view(owner), view(owner)]),
      ),
    );
    await VideoPlayerPip.enterPipMode(owner);
    await tester.pump();
    expect(find.text('Picture in Picture'), findsNWidgets(2));
    expect(find.byType(Texture), findsNothing);
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    pipWidgetTest('$platform keeps its native inline view mounted during PiP', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final owner = await createController(tester);
      await tester.pumpWidget(view(owner));
      final Element texture = tester.element(find.byType(Texture));
      await VideoPlayerPip.enterPipMode(owner);
      await tester.pump();
      expect(find.text('Picture in Picture'), findsNothing);
      expect(tester.element(find.byType(Texture)), same(texture));
    });
  }

  pipWidgetTest(
    'disposing another controller preserves ownership; disposing owner clears it once',
    (tester) async {
      final owner = await createController(tester);
      final other = await createController(tester);
      final List<PipModeChanged> events = <PipModeChanged>[];
      final subscription = VideoPlayerPip.instance.onPipModeChanged.listen(
        events.add,
      );
      addTearDown(subscription.cancel);
      await VideoPlayerPip.enterPipMode(owner);
      await tester.runAsync(other.dispose);
      expect(pipPlayerId.value, owner.playerId);
      await tester.runAsync(owner.dispose);
      await tester.pump();
      expect(pipPlayerId.value, isNull);
      await mode(tester, owner, false);
      await mode(tester, owner, true);
      expect(pipPlayerId.value, isNull);
      expect(events.where((event) => !event.isInPip), hasLength(1));
      expect(events.last.playerId, owner.playerId);
    },
  );

  pipWidgetTest('a close before the enter reply prevents a stale placeholder', (
    tester,
  ) async {
    final owner = await createController(tester);
    final response = Completer<bool>();
    enterResponse = (_) => response.future;
    await tester.pumpWidget(view(owner));
    final entering = VideoPlayerPip.enterPipMode(owner);
    await tester.pump();
    await mode(tester, owner, true);
    await mode(tester, owner, false);
    response.complete(true);
    expect(await entering, isTrue);
    await tester.pump();
    expect(find.text('Picture in Picture'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
  });

  pipWidgetTest('a pending enter cannot reactivate a disposed controller', (
    tester,
  ) async {
    final owner = await createController(tester);
    final response = Completer<bool>();
    enterResponse = (_) => response.future;
    final entering = VideoPlayerPip.enterPipMode(owner);
    await tester.pump();
    await tester.runAsync(owner.dispose);
    response.complete(true);
    expect(await entering, isFalse);
    await mode(tester, owner, true);
    expect(pipPlayerId.value, isNull);
  });

  pipWidgetTest('disposing a mounted owner avoids rebuilding its native view', (
    tester,
  ) async {
    final owner = await createController(tester);
    await tester.pumpWidget(view(owner));
    await VideoPlayerPip.enterPipMode(owner);
    await tester.pump();
    await tester.runAsync(owner.dispose);
    await tester.pump();
    expect(find.text('Picture in Picture'), findsNothing);
    expect(find.byType(Texture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  pipWidgetTest('an old singleton cannot dispose the replacement instance', (
    tester,
  ) async {
    final owner = await createController(tester);
    final old = VideoPlayerPip.instance;
    old.dispose();
    final fresh = VideoPlayerPip.instance;
    await VideoPlayerPip.enterPipMode(owner);
    old.dispose();
    expect(VideoPlayerPip.instance, same(fresh));
    expect(pipPlayerId.value, owner.playerId);
    await mode(tester, owner, false);
    expect(pipPlayerId.value, isNull);
  });

  for (final reset in <bool>[false, true]) {
    pipWidgetTest(
      'iOS ${reset ? 'reset' : 'exit'} preserves one native idless stop event',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final owner = await createController(tester);
        final List<PipModeChanged> events = <PipModeChanged>[];
        final subscription = VideoPlayerPip.instance.onPipModeChanged.listen(
          events.add,
        );
        addTearDown(subscription.cancel);
        await VideoPlayerPip.enterPipMode(owner);
        await nativeEvent(tester, 'pipModeChanged', <String, Object>{
          'isInPipMode': true,
        });
        expect(events, hasLength(1));
        if (reset) {
          await VideoPlayerPip.reset();
        } else {
          await VideoPlayerPip.exitPipMode();
        }
        await tester.pump();
        expect(events, hasLength(1));
        await nativeEvent(tester, 'pipModeChanged', <String, Object>{
          'isInPipMode': false,
        });
        expect(events, hasLength(2));
        expect(events.last.isInPip, isFalse);
      },
    );
  }

  pipWidgetTest(
    'another initialization failure leaves the current PiP owner intact',
    (tester) async {
      final owner = await createController(tester);
      await VideoPlayerPip.enterPipMode(owner);
      backend.forceInitError = true;
      final failed = VideoPlayerController.networkUrl(
        Uri.parse('https://example.com/broken.mp4'),
      );
      controllers.add(failed);
      await tester.runAsync(() async {
        await expectLater(
          failed.initialize(),
          throwsA(isA<PlatformException>()),
        );
      });
      expect(pipPlayerId.value, owner.playerId);
    },
  );
}
