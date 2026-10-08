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
  late List<MethodCall> pipCalls;
  Future<bool> Function(int)? enterResponse;
  Future<void> Function(int)? accentResponse;
  bool? inPipResponse;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    backend = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = backend;
    controllers = <VideoPlayerController>[];
    pipCalls = <MethodCall>[];
    enterResponse = null;
    accentResponse = null;
    inPipResponse = null;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      pipCalls.add(call);
      if (call.method == 'setPipAccentColor' && accentResponse != null) {
        await accentResponse!(
          (call.arguments as Map<dynamic, dynamic>)['playerId'] as int,
        );
        return null;
      }
      if (call.method == 'enterPipMode' && enterResponse != null) {
        return enterResponse!(
          (call.arguments as Map<dynamic, dynamic>)['playerId'] as int,
        );
      }
      if (call.method == 'isInPipMode' && inPipResponse != null) {
        return inPipResponse;
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

  Widget themedView(
    VideoPlayerController controller,
    Color primary, {
    Key? key,
  }) => Theme(
    data: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: primary)
          .copyWith(primary: primary),
    ),
    child: view(controller, key: key),
  );

  List<MethodCall> accentCalls() =>
      pipCalls.where((call) => call.method == 'setPipAccentColor').toList();

  void expectAccent(MethodCall call, int playerId, Color primary) {
    expect(call.method, 'setPipAccentColor');
    expect(call.arguments, <String, int>{
      'playerId': playerId,
      'color': primary.toARGB32(),
    });
  }

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
    'Windows sends the theme color when a mounted player initializes',
    (tester) async {
      const primary = Color(0xFF6750A4);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.com/video.mp4'),
      );
      controllers.add(controller);
      await tester.pumpWidget(themedView(controller, primary));
      expect(accentCalls(), isEmpty);
      await tester.runAsync(controller.initialize);
      await tester.pump();
      expect(accentCalls(), hasLength(1));
      expectAccent(accentCalls().single, controller.playerId, primary);
    },
  );

  pipWidgetTest(
    'Windows updates primary in PiP and deduplicates equal theme colors',
    (tester) async {
      const primary = Color(0xFF6750A4);
      const updated = Color(0xFF008577);
      final owner = await createController(tester);
      await tester.pumpWidget(themedView(owner, primary));
      expectAccent(accentCalls().single, owner.playerId, primary);
      await VideoPlayerPip.enterPipMode(owner);
      await tester.pump();
      pipCalls.clear();
      await tester.pumpWidget(themedView(owner, primary));
      expect(accentCalls(), isEmpty);
      await tester.pumpWidget(themedView(owner, updated));
      expectAccent(accentCalls().single, owner.playerId, updated);
      expect(pipPlayerId.value, owner.playerId);
      await tester.pumpWidget(themedView(owner, updated));
      expect(accentCalls(), hasLength(1));
    },
  );

  pipWidgetTest(
    'a controller swap targets the new player even with the same primary',
    (tester) async {
      const primary = Color(0xFF6750A4);
      const key = ValueKey<String>('themed-video');
      final first = await createController(tester);
      final second = await createController(tester);
      await tester.pumpWidget(themedView(first, primary, key: key));
      await VideoPlayerPip.enterPipMode(first);
      await tester.pump();
      pipCalls.clear();
      await tester.pumpWidget(themedView(second, primary, key: key));
      expectAccent(accentCalls().single, second.playerId, primary);
      expect(pipPlayerId.value, first.playerId);
    },
  );

  pipWidgetTest(
    'entry retains the primary after its inline widget is unmounted',
    (tester) async {
      const primary = Color(0xFF008577);
      final owner = await createController(tester);
      await tester.pumpWidget(themedView(owner, primary));
      await tester.pumpWidget(const SizedBox.shrink());
      pipCalls.clear();
      expect(await VideoPlayerPip.enterPipMode(owner), isTrue);
      final opening = pipCalls
          .where(
            (call) =>
                call.method == 'setPipAccentColor' ||
                call.method == 'enterPipMode',
          )
          .toList();
      expect(opening, hasLength(2));
      expectAccent(opening.first, owner.playerId, primary);
      expect(opening.last.method, 'enterPipMode');
    },
  );

  for (final api in <String>['enter', 'toggle', 'extension enter']) {
    pipWidgetTest('$api forwards an explicit primary before opening PiP', (
      tester,
    ) async {
      const primary = Color(0xFF123456);
      final owner = await createController(tester);
      inPipResponse = false;
      final bool entered = switch (api) {
        'enter' => await VideoPlayerPip.enterPipMode(
          owner,
          primaryColor: primary,
        ),
        'toggle' => await VideoPlayerPip.togglePipMode(
          owner,
          primaryColor: primary,
        ),
        _ => await owner.enterPipMode(primaryColor: primary),
      };
      expect(entered, isTrue);
      final opening = pipCalls
          .where(
            (call) =>
                call.method == 'setPipAccentColor' ||
                call.method == 'enterPipMode',
          )
          .toList();
      expect(opening, hasLength(2));
      expectAccent(opening.first, owner.playerId, primary);
      expect(opening.last.method, 'enterPipMode');
    });
  }

  for (final dispose in <bool>[true, false]) {
    pipWidgetTest(
      '${dispose ? 'dispose' : 'reset'} during the accent reply cancels native entry',
      (tester) async {
        final owner = await createController(tester);
        final response = Completer<void>();
        accentResponse = (_) => response.future;
        final entering = VideoPlayerPip.enterPipMode(
          owner,
          primaryColor: const Color(0xFF6750A4),
        );
        await tester.pump();
        expect(accentCalls(), hasLength(1));
        if (dispose) {
          await tester.runAsync(owner.dispose);
        } else {
          await VideoPlayerPip.reset();
        }
        response.complete();
        expect(await entering, isFalse);
        expect(
          pipCalls.where((call) => call.method == 'enterPipMode'),
          isEmpty,
        );
        expect(pipPlayerId.value, isNull);
      },
    );
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
