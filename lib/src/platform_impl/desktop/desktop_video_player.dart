import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

VideoPlayerPlatform? _registeredBackend;

/// Uses media_kit only for the platforms without a vendored native backend.
void registerDesktopVideoPlayer() {
  if (identical(VideoPlayerPlatform.instance, _registeredBackend)) return;
  VideoPlayerMediaKit.ensureInitialized(windows: true, linux: true);
  _registeredBackend = VideoPlayerPlatform.instance;
}
