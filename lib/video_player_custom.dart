// A single, autonomous plugin that merges the official `video_player` (from
// flutter/packages) with full Picture-in-Picture (PiP) support.
//
// Import this single library (and nothing else) to get everything:
//
//   - The complete video_player API: [VideoPlayerController], [VideoPlayer],
//     [VideoProgressIndicator], [VideoScrubber], [VideoViewType], ...
//   - The PiP API: [VideoPlayerPip], [PipModeChanged], plus the
//     [VideoPlayerControllerExtension] helpers (e.g. `controller.enterPipMode()`).
//
// ```dart
// import 'package:video_player_custom/video_player_custom.dart';
//
// final controller = VideoPlayerController.networkUrl(
//   Uri.parse('https://example.com/video.mp4'),
//   viewType: VideoViewType.platformView,
// );
// await controller.initialize();
// controller.enterPipMode();
// ```

import 'package:flutter/foundation.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'src/platform_impl/android/android_video_player.dart';
import 'src/platform_impl/desktop/desktop_video_player.dart';
import 'src/platform_impl/avfoundation/avfoundation_video_player.dart';

// The PiP library re-exports the full, PiP-enabled `video_player` API.
export 'src/pip/video_player_custom_pip.dart';

/// Dart entry point used by Flutter's generated plugin registrant.
class VideoPlayerCustom {
  static void registerWith() => registerVideoPlayerCustom();
}

/// Explicitly registers the implementation for the current native platform.
/// Flutter calls this automatically through its generated plugin registrant.
/// Web registration is handled by VideoPlayerCustomWeb.
void registerVideoPlayerCustom() {
  if (kIsWeb) return;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      if (VideoPlayerPlatform.instance is! AndroidVideoPlayer) {
        AndroidVideoPlayer.registerWith();
      }
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      if (VideoPlayerPlatform.instance is! AVFoundationVideoPlayer) {
        AVFoundationVideoPlayer.registerWith();
      }
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      registerDesktopVideoPlayer();
    case TargetPlatform.fuchsia:
      throw UnsupportedError(
        'video_player_custom does not support $defaultTargetPlatform',
      );
  }
}
