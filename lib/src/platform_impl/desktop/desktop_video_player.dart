import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'native_desktop_video_player.dart';

/// The registered backend, to avoid re-registering on repeated calls.
VideoPlayerPlatform? _registeredBackend;

/// Registers the bundled native desktop backend:
///
///   * Windows: Windows Media Foundation.
///   * Linux: GStreamer.
///
/// Both platforms share the same Dart implementation and method-channel
/// contract; only the native plugin underneath differs.
void registerDesktopVideoPlayer() {
  if (identical(VideoPlayerPlatform.instance, _registeredBackend)) return;
  NativeDesktopVideoPlayer.registerWith();
  _registeredBackend = VideoPlayerPlatform.instance;
}