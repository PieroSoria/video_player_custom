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
import 'src/platform_impl/avfoundation/avfoundation_video_player.dart';

// The PiP library re-exports the full, PiP-enabled `video_player` API.
export 'src/pip/video_player_custom_pip.dart';

bool _isVideoPlayerCustomRegistered = false;

/// Binds the platform implementation for the current target.
///
/// This is called automatically when the library is first imported. It is
/// idempotent, so it is safe to call again at any time (e.g. after overriding
/// the instance in tests).
///
/// The web implementation is registered separately by the plugin system
/// through [VideoPlayerCustomWeb.registerWith].
void registerVideoPlayerCustom() {
  if (_isVideoPlayerCustomRegistered) {
    return;
  }
  _isVideoPlayerCustomRegistered = true;

  if (kIsWeb) {
    // Handled by `video_player_custom_web.dart` (dart plugin registrant).
    return;
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      VideoPlayerPlatform.instance = AndroidVideoPlayer();
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      VideoPlayerPlatform.instance = AVFoundationVideoPlayer();
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      // No supported implementation.
      break;
  }
}
// Registration is handled by the Dart plugin registrant (`registerWith`),
// matching the official `video_player` package. No top-level call is needed.