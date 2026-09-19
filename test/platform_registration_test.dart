import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/video_player_custom.dart';
import 'package:video_player_custom/src/platform_impl/android/android_video_player.dart';
import 'package:video_player_custom/src/platform_impl/avfoundation/avfoundation_video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  final original = VideoPlayerPlatform.instance;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    VideoPlayerPlatform.instance = original;
  });

  for (final target in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    test('registers $target and preserves existing backend on repeat', () {
      debugDefaultTargetPlatformOverride = target;
      VideoPlayerCustom.registerWith();
      final backend = VideoPlayerPlatform.instance;
      expect(
        backend,
        target == TargetPlatform.android
            ? isA<AndroidVideoPlayer>()
            : isA<AVFoundationVideoPlayer>(),
      );
      VideoPlayerCustom.registerWith();
      expect(VideoPlayerPlatform.instance, same(backend));
    });
  }
  test('unsupported platform reports its name', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    expect(registerVideoPlayerCustom, throwsUnsupportedError);
  });
}
