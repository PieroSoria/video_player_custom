import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/src/platform_impl/desktop/native_desktop_video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(kDesktopMethodChannel);
  const EventChannel eventChannel = EventChannel(
    '$kDesktopMethodChannel/events/7',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeDesktopVideoPlayer platform;
  late List<MethodCall> calls;
  late List<VideoEvent> events;
  late List<Object> errors;
  late int bufferedPosition;
  StreamSubscription<VideoEvent>? subscription;
  Future<Object?> Function()? bufferResponse;

  setUp(() {
    platform = NativeDesktopVideoPlayer(methodChannel: channel);
    calls = <MethodCall>[];
    events = <VideoEvent>[];
    errors = <Object>[];
    bufferedPosition = 5000;
    subscription = null;
    bufferResponse = null;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return switch (call.method) {
        'create' => <String, int>{'playerId': 7, 'textureId': 19},
        'getBufferedPosition' =>
          bufferResponse == null ? bufferedPosition : await bufferResponse!(),
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      MethodChannel(eventChannel.name),
      (_) async => null,
    );
  });

  tearDown(() async {
    await subscription?.cancel();
    await platform.init();
    messenger.setMockMethodCallHandler(MethodChannel(eventChannel.name), null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> createAndListen(WidgetTester tester) async {
    await platform.create(
      DataSource(
        sourceType: DataSourceType.network,
        uri: 'https://example.com/video.mp4',
      ),
    );
    subscription = platform
        .videoEventsFor(7)
        .listen(events.add, onError: errors.add);
    await tester.pump();
  }

  void initializeNativePlayer() {
    unawaited(
      messenger.handlePlatformMessage(
        eventChannel.name,
        eventChannel.codec.encodeSuccessEnvelope(<String, Object>{
          'event': 'initialized',
          'duration': 5000,
          'width': 1920,
          'height': 1080,
        }),
        null,
      ),
    );
  }

  Iterable<MethodCall> bufferCalls() =>
      calls.where((MethodCall call) => call.method == 'getBufferedPosition');

  test(
    'forwards source and HTTP headers and uses the native texture ID',
    () async {
      final int? playerId = await platform.createWithOptions(
        VideoCreationOptions(
          dataSource: DataSource(
            sourceType: DataSourceType.network,
            uri: 'https://example.com/private.mp4',
            httpHeaders: <String, String>{'Authorization': 'Bearer token'},
          ),
          viewType: VideoViewType.platformView,
        ),
      );

      expect(playerId, 7);
      expect(calls.single.arguments, <String, Object>{
        'uri': 'https://example.com/private.mp4',
        'httpHeaders': <String, String>{'Authorization': 'Bearer token'},
        'viewType': 'platformView',
      });
      expect((platform.buildView(7) as Texture).textureId, 19);
    },
  );

  test(
    'preserves cached Windows file URIs containing spaces and Unicode',
    () async {
      final String uri = Uri.file(
        r'C:\video cache\película.mp4',
        windows: true,
      ).toString();
      await platform.create(
        DataSource(sourceType: DataSourceType.file, uri: uri),
      );

      expect((calls.single.arguments as Map<dynamic, dynamic>)['uri'], uri);
    },
  );

  testWidgets('reports the buffer immediately and only when it changes', (
    WidgetTester tester,
  ) async {
    await createAndListen(tester);
    initializeNativePlayer();
    await tester.pump();

    expect(events.map((VideoEvent event) => event.eventType), <VideoEventType>[
      VideoEventType.initialized,
      VideoEventType.bufferingUpdate,
    ]);
    expect(events.first.duration, const Duration(seconds: 5));
    expect(events.first.size, const Size(1920, 1080));
    expect(events.last.buffered!.single.end, const Duration(seconds: 5));

    await tester.pump(const Duration(seconds: 1));
    expect(events, hasLength(2));
    bufferedPosition = 6000;
    await tester.pump(const Duration(seconds: 1));
    expect(events, hasLength(3));
    expect(events.last.buffered!.single.end, const Duration(seconds: 6));
    await tester.runAsync(() => platform.dispose(7));
  });

  testWidgets('keeps only one buffer request in flight', (
    WidgetTester tester,
  ) async {
    final Completer<Object?> response = Completer<Object?>();
    bufferResponse = () => response.future;
    await createAndListen(tester);
    initializeNativePlayer();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(bufferCalls(), hasLength(1));
    response.complete(2000);
    await tester.pump();
    expect(events.last.buffered!.single.end, const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(bufferCalls(), hasLength(2));
    await tester.runAsync(() => platform.dispose(7));
  });

  testWidgets('routes a failed buffer poll through the event stream once', (
    WidgetTester tester,
  ) async {
    bufferResponse = () async => throw PlatformException(
      code: 'buffer_error',
      message: 'Cannot query this player.',
    );
    await createAndListen(tester);
    initializeNativePlayer();
    await tester.pump();

    expect(errors, hasLength(1));
    expect(errors.single, isA<PlatformException>());
    expect((errors.single as PlatformException).code, 'buffer_error');
    await tester.pump(const Duration(seconds: 3));
    expect(bufferCalls(), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => platform.dispose(7));
  });

  testWidgets('releases the native player while a listener is paused', (
    WidgetTester tester,
  ) async {
    await createAndListen(tester);
    subscription!.pause();
    await tester.runAsync(() => platform.dispose(7));
    expect(
      calls.where((MethodCall call) => call.method == 'dispose'),
      hasLength(1),
    );
    subscription!.resume();
    await tester.pump();
    expect(() => platform.buildView(7), throwsStateError);
    await tester.runAsync(() => platform.dispose(7));
    expect(
      calls.where((MethodCall call) => call.method == 'dispose'),
      hasLength(1),
    );
  });

  testWidgets('ignores a buffer failure that completes after disposal', (
    WidgetTester tester,
  ) async {
    final Completer<Object?> response = Completer<Object?>();
    bufferResponse = () => response.future;
    await createAndListen(tester);
    initializeNativePlayer();
    await tester.pump();
    await tester.runAsync(() => platform.dispose(7));
    response.completeError(PlatformException(code: 'unknown_player'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(errors, isEmpty);
    expect(bufferCalls(), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
