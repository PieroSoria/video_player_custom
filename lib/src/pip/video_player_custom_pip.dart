// `playerId` is only exposed by video_player as a `@visibleForTesting` member,
// but there is no public API to retrieve it. It is required to identify the
// player on the native side.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../video_player.dart';
import 'video_player_custom_pip_platform_interface.dart';
import 'windows_pip_overlay.dart';

export 'video_player_custom_pip_platform_interface.dart'
    show VideoPlayerPipPlatform;

// Export the PiP-enabled VideoPlayer API that supports view type selection
export '../../video_player.dart';
export 'extensions.dart';

/// Event emitted by [VideoPlayerPip.onPipModeChanged].
///
/// [isInPip] is `true` while the video is playing in the floating PiP window.
/// [isRestored] is `true` when the user tapped the PiP window's restore/expand
/// button; use it to navigate back to your full-screen video screen.
/// [position] (only set when [isRestored] is `true`) is where the native
/// AVPlayer was when PiP was expanded, so you can resume exactly where the
/// video was left off.
class PipModeChanged {
  const PipModeChanged({
    required this.isInPip,
    this.isRestored = false,
    this.position,
  });

  /// Whether PiP is currently active.
  final bool isInPip;

  /// Whether the user requested to restore the full-screen UI from PiP.
  final bool isRestored;

  /// Native playback position when PiP was restored (see [isRestored]).
  final Duration? position;

  @override
  String toString() =>
      'PipModeChanged(isInPip: $isInPip, isRestored: $isRestored, '
      'position: $position)';
}

/// A Flutter plugin that adds Picture-in-Picture (PiP) functionality to the video_player package.
///
/// This plugin provides methods to enter and exit PiP mode, check if PiP is supported
/// on the current device, and monitor PiP state changes.
class VideoPlayerPip {
  static const MethodChannel _channel = MethodChannel('video_player_pip');

  static VideoPlayerPipPlatform get _platform =>
      VideoPlayerPipPlatform.instance;

  /// Checks if the device supports PiP mode
  ///
  /// Returns `true` if PiP is supported, otherwise `false`.
  ///
  /// For Android, this requires API level 26 (Android 8.0) or higher.
  /// For iOS, this requires iOS 14.0 or higher.
  static Future<bool> isPipSupported() {
    return _platform.isPipSupported();
  }

  /// Enters Picture-in-Picture mode for the given video player controller.
  ///
  /// Returns a [Future] that completes with `true` if PiP mode was entered successfully,
  /// or `false` otherwise.
  ///
  /// Optional parameters:
  /// - [width]: Desired width of the PiP window (in pixels)
  /// - [height]: Desired height of the PiP window (in pixels)
  ///
  /// The controller must be initialized. iOS requires
  /// [VideoViewType.platformView]. Windows uses the existing texture and requires
  /// a mounted [VideoPlayer] below an Overlay (for example, inside MaterialApp).
  ///
  /// Example:
  /// ```dart
  /// final controller = VideoPlayerController.networkUrl(
  ///   Uri.parse('https://example.com/video.mp4'),
  ///   viewType: VideoViewType.platformView,
  /// );
  /// await controller.initialize();
  /// await VideoPlayerPip.enterPipMode(controller, width: 300, height: 200);
  /// ```
  static Future<bool> enterPipMode(
    VideoPlayerController controller, {
    int? width,
    int? height,
  }) async {
    if (controller.playerId == VideoPlayerController.kUninitializedPlayerId) {
      debugPrint(
        'VideoPlayerPip: Cannot enter PiP mode with uninitialized controller',
      );
      return false;
    }
    if (!controller.value.isInitialized ||
        controller.value.hasError ||
        (width != null && width <= 0) ||
        (height != null && height <= 0)) {
      return false;
    }
    // Install the native callback handler even without an event subscriber.
    instance;
    final windows = WindowsPipOverlay.supportedPlatform;
    if (windows && !WindowsPipOverlay.show(controller)) return false;
    try {
      final entered = await _platform.enterPipMode(
        controller.playerId,
        width: width,
        height: height,
      );
      if (windows && !entered) WindowsPipOverlay.remove();
      return entered;
    } catch (_) {
      if (windows) WindowsPipOverlay.remove();
      rethrow;
    }
  }

  /// Exits Picture-in-Picture mode if currently active.
  ///
  /// Returns `true` if PiP mode was exited successfully, or `false` otherwise.
  static Future<bool> exitPipMode() async {
    final exited = await _platform.exitPipMode();
    if (exited) WindowsPipOverlay.remove();
    return exited;
  }

  /// Checks if the app is currently in PiP mode.
  ///
  /// Returns `true` if in PiP mode, or `false` otherwise.
  static Future<bool> isInPipMode() {
    return _platform.isInPipMode();
  }

  /// Fully resets the plugin's PiP state: stops PiP if active, releases the
  /// PiP controller, invalidates observers and clears the retained player.
  ///
  /// Call this when leaving the video screen (e.g. in your widget's `dispose`)
  /// to guarantee a clean slate for the next playback session.
  static Future<void> reset() async {
    await _platform.reset();
    WindowsPipOverlay.remove();
  }

  /// Single stream of PiP state changes.
  ///
  /// Emits a [PipModeChanged] whenever PiP starts/stops or when the user taps
  /// the PiP window's restore/expand button ([PipModeChanged.isRestored]).
  ///
  /// Example:
  /// ```dart
  /// VideoPlayerPip.instance.onPipModeChanged.listen((event) {
  ///   if (event.isRestored) {
  ///     // The user tapped "expand": navigate back to the video screen.
  ///     router.go('/player');
  ///   }
  ///   print('Is in PiP mode: ${event.isInPip}');
  /// });
  /// ```
  Stream<PipModeChanged> get onPipModeChanged {
    return _onPipModeChangedController.stream;
  }

  /// Stream of PiP error messages coming from the native side.
  ///
  /// Example:
  /// ```dart
  /// VideoPlayerPip.instance.onPipError.listen((error) {
  ///   print('PiP error: $error');
  /// });
  /// ```
  Stream<String> get onPipError {
    return _onPipErrorController.stream;
  }

  /// Toggles Picture-in-Picture mode.
  ///
  /// If currently in PiP mode, it will exit. If not in PiP mode, it will
  /// enter PiP mode with the provided controller.
  ///
  /// Optional parameters:
  /// - [width]: Desired width of the PiP window (in pixels)
  /// - [height]: Desired height of the PiP window (in pixels)
  ///
  /// Returns `true` if the operation was successful, or `false` otherwise.
  static Future<bool> togglePipMode(
    VideoPlayerController controller, {
    int? width,
    int? height,
  }) async {
    final bool isInPip = await isInPipMode();

    if (isInPip) {
      return exitPipMode();
    }
    return enterPipMode(controller, width: width, height: height);
  }

  /// Resumes playback on [controller] at [position], continuing where a restored
  /// PiP session left off.
  ///
  /// Pass a [PipModeChanged.position] from a `onPipModeChanged` event where
  /// [PipModeChanged.isRestored] is `true`. If the controller is not initialized
  /// yet, it is initialized first; if [position] is null, playback just starts.
  static Future<void> resumeWithPosition(
    VideoPlayerController controller,
    Duration? position,
  ) async {
    if (!controller.value.isInitialized) {
      await controller.initialize();
    }
    if (position != null) {
      await controller.seekTo(position);
    }
    await controller.play();
  }

  // Singleton instance
  static final VideoPlayerPip _instance = VideoPlayerPip._();

  /// The shared instance of [VideoPlayerPip].
  static VideoPlayerPip get instance => _instance;

  VideoPlayerPip._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final _onPipModeChangedController =
      StreamController<PipModeChanged>.broadcast();
  final _onPipErrorController = StreamController<String>.broadcast();

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'nativeLog':
        final String message = call.arguments as String;
        debugPrint('[NATIVE iOS] $message');
        break;
      case 'pipModeChanged':
        final bool isInPipMode = call.arguments['isInPipMode'] as bool;
        if (!isInPipMode) WindowsPipOverlay.remove();
        _onPipModeChangedController.add(PipModeChanged(isInPip: isInPipMode));
        break;
      case 'onPipRestore':
        WindowsPipOverlay.remove();
        // Unified into the main state stream: PiP is stopping and the user
        // asked to restore the full-screen UI. Carry the native AVPlayer
        // position so playback can resume exactly where it was left.
        final Map<Object?, Object?>? args =
            call.arguments as Map<Object?, Object?>?;
        final int? positionMs = args?['positionMs'] as int?;
        _onPipModeChangedController.add(
          PipModeChanged(
            isInPip: false,
            isRestored: true,
            position: positionMs != null
                ? Duration(milliseconds: positionMs)
                : null,
          ),
        );
        break;
      case 'pipError':
        final String errorMessage = call.arguments['error'] as String;
        debugPrint('PiP Error: $errorMessage');
        _onPipErrorController.add(errorMessage);
        break;
      default:
        debugPrint('Unhandled method ${call.method}');
    }
  }

  /// Disposes resources used by the plugin.
  ///
  /// Call this when you're done using PiP to free up resources.
  /// Typically called in the `dispose` method of your StatefulWidget.
  void dispose() {
    if (!_onPipModeChangedController.isClosed) {
      _onPipModeChangedController.close();
    }
    if (!_onPipErrorController.isClosed) {
      _onPipErrorController.close();
    }
    _channel.setMethodCallHandler(null);
  }
}
