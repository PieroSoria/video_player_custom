import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'windows_video_player.dart';

VideoPlayerPlatform? _registeredBackend;

/// Uses media_kit only for the platforms without a vendored native backend.
void registerDesktopVideoPlayer() {
  if (identical(VideoPlayerPlatform.instance, _registeredBackend)) return;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    MediaKit.ensureInitialized();
    WindowsVideoPlayer.registerWith();
  } else {
    VideoPlayerMediaKit.ensureInitialized(linux: true);
  }
  _registeredBackend = VideoPlayerPlatform.instance;
}
