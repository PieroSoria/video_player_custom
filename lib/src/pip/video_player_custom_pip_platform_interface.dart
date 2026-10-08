import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_player_custom_pip_method_channel.dart';

/// PiP notifications emitted by implementations which do not use a method
/// channel, such as the browser implementation.
class VideoPlayerPipPlatformEvent {
  const VideoPlayerPipPlatformEvent({
    required this.playerId,
    required this.isInPip,
    this.isRestored = false,
    this.positionMs,
    this.error,
  });

  final int playerId;
  final bool isInPip;
  final bool isRestored;
  final int? positionMs;
  final String? error;
}

abstract class VideoPlayerPipPlatform extends PlatformInterface {
  /// Constructs a VideoPlayerPipPlatform.
  VideoPlayerPipPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoPlayerPipPlatform _instance = MethodChannelVideoPlayerPip();

  /// The default instance of [VideoPlayerPipPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoPlayerPip].
  static VideoPlayerPipPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoPlayerPipPlatform] when
  /// they register themselves.
  static set instance(VideoPlayerPipPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Browser state/error notifications. Native implementations retain their
  /// method-channel callback contract.
  Stream<VideoPlayerPipPlatformEvent> get events => const Stream.empty();

  /// Synchronous state when the implementation can provide it. Browser entry
  /// must be requested in the original click stack to retain user activation.
  bool? get currentPipState => null;

  /// Sets a player's ARGB32 accent for native PiP controls. Implementations
  /// with browser/system-owned controls may leave this as a no-op.
  Future<void> setPipAccentColor(int playerId, int color) async {}

  /// Checks if the device supports PiP mode.
  Future<bool> isPipSupported() {
    throw UnimplementedError('isPipSupported() has not been implemented.');
  }

  /// Enters PiP mode for the specified player ID.
  Future<bool> enterPipMode(int playerId, {int? width, int? height}) {
    throw UnimplementedError('enterPipMode() has not been implemented.');
  }

  /// Exits PiP mode.
  Future<bool> exitPipMode() {
    throw UnimplementedError('exitPipMode() has not been implemented.');
  }

  /// Checks if the app is currently in PiP mode.
  Future<bool> isInPipMode() {
    throw UnimplementedError('isInPipMode() has not been implemented.');
  }

  /// Fully resets the plugin's PiP state: stops PiP if active, releases the
  /// PiP controller, invalidates observers and clears the retained player.
  /// Call this when leaving the video screen to guarantee a clean slate.
  Future<void> reset() {
    throw UnimplementedError('reset() has not been implemented.');
  }
}
