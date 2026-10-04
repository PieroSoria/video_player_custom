// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_player_test.dart' show FakeVideoPlayerPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVideoPlayerPlatform fakeVideoPlayerPlatform;

  setUp(() {
    VideoPlayerPlatform.instance = fakeVideoPlayerPlatform =
        FakeVideoPlayerPlatform();
  });

  test('plugin initialized', () async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://127.0.0.1'),
    );
    await controller.initialize();
    expect(fakeVideoPlayerPlatform.calls.first, 'init');
  });

  test('web configuration is applied (web only)', () async {
    const expected = VideoPlayerWebOptions(
      allowContextMenu: false,
      allowRemotePlayback: false,
      controls: VideoPlayerWebOptionsControls.enabled(),
    );

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://127.0.0.1'),
      videoPlayerOptions: VideoPlayerOptions(webOptions: expected),
    );
    await controller.initialize();

    expect(
      () {
        fakeVideoPlayerPlatform.calls.singleWhere(
          (String call) => call == 'setWebOptions',
        );
      },
      returnsNormally,
      reason: 'setWebOptions must be called exactly once.',
    );
    expect(
      fakeVideoPlayerPlatform.webOptions[controller.playerId],
      expected,
      reason: 'web options must be passed to the platform',
    );
  }, skip: !kIsWeb);

  test('video view type is applied', () async {
    const VideoViewType expected = VideoViewType.platformView;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://127.0.0.1'),
      viewType: expected,
    );
    await controller.initialize();

    expect(
      () {
        fakeVideoPlayerPlatform.calls.singleWhere(
          (String call) => call == 'createWithOptions',
        );
      },
      returnsNormally,
      reason: 'createWithOptions must be called exactly once.',
    );
    expect(
      fakeVideoPlayerPlatform.viewTypes[controller.playerId],
      expected,
      reason: 'view type must be passed to the platform',
    );
  });

  test('back buffer duration is forwarded to platform', () async {
    const expectedBackBufferDurationMs = 20000;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://127.0.0.1'),
      videoPlayerOptions: VideoPlayerOptions(
        backBufferDurationMs: expectedBackBufferDurationMs,
      ),
    );

    await controller.initialize();

    expect(
      fakeVideoPlayerPlatform.videoPlayerOptions.last?.backBufferDurationMs,
      expectedBackBufferDurationMs,
      reason:
          'backBufferDurationMs must be forwarded to the platform via VideoCreationOptions.videoPlayerOptions',
    );
  });

  test('native creation failure sets error and allows disposal', () async {
    VideoPlayerPlatform.instance = _FailingVideoPlayerPlatform();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://127.0.0.1/missing.mp4'),
    );
    await expectLater(
      controller.initialize(),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.value.hasError, isTrue);
    expect(controller.value.errorDescription, 'Unable to open media');
    await controller.dispose().timeout(const Duration(seconds: 1));
  });

  test(
    'disposal during failed creation completes without a native ID',
    () async {
      final failure = _FailingVideoPlayerPlatform(gate: Completer<void>());
      VideoPlayerPlatform.instance = failure;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://127.0.0.1/missing.mp4'),
      );
      final initialized = controller.initialize();
      final expectation = expectLater(
        initialized,
        throwsA(isA<PlatformException>()),
      );
      await failure.started.future;
      final disposed = controller.dispose();
      failure.gate!.complete();
      await expectation;
      await disposed.timeout(const Duration(seconds: 1));
      expect(failure.calls, isNot(contains('dispose')));
    },
  );
}

class _FailingVideoPlayerPlatform extends FakeVideoPlayerPlatform {
  _FailingVideoPlayerPlatform({this.gate});

  final Completer<void>? gate;
  final Completer<void> started = Completer<void>();

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    started.complete();
    await gate?.future;
    throw PlatformException(
      code: 'video_error',
      message: 'Unable to open media',
    );
  }
}
