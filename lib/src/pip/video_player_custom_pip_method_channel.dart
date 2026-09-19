import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'video_player_custom_pip_platform_interface.dart';

/// An implementation of [VideoPlayerPipPlatform] that uses method channels.
class MethodChannelVideoPlayerPip extends VideoPlayerPipPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('video_player_pip');

  @override
  Future<bool> isPipSupported() async {
    try {
      final isSupported = await methodChannel.invokeMethod<bool>(
        'isPipSupported',
      );
      return isSupported ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Error checking PiP support: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> enterPipMode(int playerId, {int? width, int? height}) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('enterPipMode', {
        'playerId': playerId,
        'width': ?width,
        'height': ?height,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Error entering PiP mode: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> exitPipMode() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('exitPipMode');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Error exiting PiP mode: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> isInPipMode() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('isInPipMode');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Error checking PiP mode: ${e.message}');
      return false;
    }
  }

  @override
  Future<void> reset() async {
    try {
      await methodChannel.invokeMethod<void>('reset');
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      debugPrint('Error resetting PiP: ${e.message}');
    }
  }
}
