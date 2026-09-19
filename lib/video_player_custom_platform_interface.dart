import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_player_custom_method_channel.dart';

abstract class VideoPlayerCustomPlatform extends PlatformInterface {
  /// Constructs a VideoPlayerCustomPlatform.
  VideoPlayerCustomPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoPlayerCustomPlatform _instance = MethodChannelVideoPlayerCustom();

  /// The default instance of [VideoPlayerCustomPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoPlayerCustom].
  static VideoPlayerCustomPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoPlayerCustomPlatform] when
  /// they register themselves.
  static set instance(VideoPlayerCustomPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
