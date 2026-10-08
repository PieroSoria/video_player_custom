// `playerId` is only exposed by video_player as a `@visibleForTesting` member,
// but there is no public API to retrieve it. It is required to identify the
// player on the native side.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';

import '../../video_player.dart';
import 'pip_state.dart';
import 'video_player_custom_pip_platform_interface.dart';

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
/// player was when PiP was expanded, so you can resume exactly where the
/// video was left off.
class PipModeChanged {
  const PipModeChanged({
    required this.isInPip,
    this.isRestored = false,
    this.position,
    this.playerId,
  });

  /// Whether PiP is currently active.
  final bool isInPip;

  /// Whether the user requested to restore the full-screen UI from PiP.
  final bool isRestored;

  /// Native playback position when PiP was restored (see [isRestored]).
  final Duration? position;

  /// Player whose native PiP state changed, when reported by the platform.
  final int? playerId;

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
  /// - [primaryColor]: Initial Windows control accent, overriding the last
  ///   mounted [VideoPlayer] theme. Mounted widgets follow later theme changes.
  ///
  /// The controller must be initialized. iOS and macOS require
  /// [VideoViewType.platformView]. Windows opens a small, borderless,
  /// always-on-top window that renders the video natively; the app keeps
  /// running underneath and can be used normally.
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
    Color? primaryColor,
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
    final VideoPlayerPip pip = instance;
    pip._ensurePlatformEvents();
    final int playerId = controller.playerId;
    final Object? token = pipPlayerToken(playerId);
    if (token == null) {
      return false;
    }
    final int command = ++pip._commandGeneration;
    final int revision = pip._stateRevision;
    pip._pendingEnterPlayerId = playerId;
    try {
      final int? accent = primaryColor?.toARGB32() ?? pipAccentColor(playerId);
      if (accent != null) rememberPipAccentColor(playerId, accent);
      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.windows &&
          accent != null) {
        await _platform.setPipAccentColor(playerId, accent);
        if (!identical(pipPlayerToken(playerId), token) ||
            pip._commandGeneration != command) {
          return false;
        }
      }
      final entered = await _platform.enterPipMode(
        playerId,
        width: width,
        height: height,
      );
      final bool live = identical(pipPlayerToken(playerId), token);
      if (entered &&
          live &&
          pip._commandGeneration == command &&
          pip._stateRevision == revision) {
        pip._publishOwner(playerId);
      }
      return entered && live;
    } finally {
      if (pip._commandGeneration == command) {
        pip._pendingEnterPlayerId = null;
      }
    }
  }

  /// Exits Picture-in-Picture mode if currently active.
  ///
  /// Returns `true` if PiP mode was exited successfully, or `false` otherwise.
  static Future<bool> exitPipMode() async {
    final VideoPlayerPip pip = instance;
    pip._ensurePlatformEvents();
    final int command = ++pip._commandGeneration;
    final int? playerId = pipPlayerId.value ?? pip._pendingEnterPlayerId;
    final bool exited = await _platform.exitPipMode();
    if (exited &&
        pip._commandGeneration == command &&
        pipPlayerId.value == playerId) {
      pip._publishOwner(null);
    }
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
    final VideoPlayerPip pip = instance;
    pip._ensurePlatformEvents();
    final int command = ++pip._commandGeneration;
    await _platform.reset();
    if (pip._commandGeneration == command) {
      pip._pendingEnterPlayerId = null;
      pip._publishOwner(null);
    }
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
    _ensurePlatformEvents();
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
    _ensurePlatformEvents();
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
  /// [primaryColor] configures the Windows accent when entering PiP.
  static Future<bool> togglePipMode(
    VideoPlayerController controller, {
    int? width,
    int? height,
    Color? primaryColor,
  }) async {
    final bool isInPip = kIsWeb
        ? _platform.currentPipState ?? (pipPlayerId.value != null)
        : await isInPipMode();

    if (isInPip) {
      return exitPipMode();
    }
    return enterPipMode(
      controller,
      width: width,
      height: height,
      primaryColor: primaryColor,
    );
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
  static VideoPlayerPip? _instance;

  /// The shared instance of [VideoPlayerPip].
  static VideoPlayerPip get instance => _instance ??= VideoPlayerPip._();

  VideoPlayerPip._() {
    _lastOwner = pipPlayerId.value;
    pipPlayerId.addListener(_onOwnerChanged);
    _channel.setMethodCallHandler(_handleMethodCall);
    _ensurePlatformEvents();
  }

  VideoPlayerPipPlatform? _eventPlatform;
  StreamSubscription<VideoPlayerPipPlatformEvent>? _platformEventsSubscription;

  void _ensurePlatformEvents() {
    if (_disposed || identical(_eventPlatform, _platform)) return;
    final previous = _platformEventsSubscription;
    if (previous != null) unawaited(previous.cancel());
    _eventPlatform = _platform;
    _platformEventsSubscription = _platform.events.listen((event) {
      if (_disposed) return;
      if (event.error != null) {
        _onPipErrorController.add(event.error!);
        return;
      }
      _nativeModeChanged({
        'playerId': event.playerId,
        'positionMs': event.positionMs,
      }, entered: event.isInPip, restored: event.isRestored);
    });
  }

  int _commandGeneration = 0;
  bool _disposed = false;
  int _stateRevision = 0;
  int? _pendingEnterPlayerId;
  int? _lastOwner;
  PipModeChanged? _nextModeEvent;

  bool get _usesTrackedOwnerEvents =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.windows;

  void _onOwnerChanged() {
    final int? owner = pipPlayerId.value;
    _stateRevision++;
    if (_usesTrackedOwnerEvents) {
      _onPipModeChangedController.add(
        _nextModeEvent ??
            PipModeChanged(
              isInPip: owner != null,
              playerId: owner ?? _lastOwner,
            ),
      );
    }
    _lastOwner = owner;
  }

  void _publishOwner(int? owner, {bool restored = false, Duration? position}) {
    if (pipPlayerId.value == owner) {
      return;
    }
    _nextModeEvent = PipModeChanged(
      isInPip: owner != null,
      isRestored: restored,
      position: position,
      playerId: owner ?? pipPlayerId.value,
    );
    try {
      pipPlayerId.value = owner;
    } finally {
      _nextModeEvent = null;
    }
  }

  void _nativeModeChanged(
    Map<Object?, Object?>? args, {
    required bool entered,
    bool restored = false,
  }) {
    final int? playerId =
        args?['playerId'] as int? ?? pipPlayerId.value ?? _pendingEnterPlayerId;
    final int? positionMs = args?['positionMs'] as int?;
    final Duration? position = positionMs == null
        ? null
        : Duration(milliseconds: positionMs);
    if (playerId != null && entered) {
      if (pipPlayerToken(playerId) != null) {
        _stateRevision++;
        _publishOwner(playerId);
      }
    } else if (playerId != null && pipPlayerId.value == playerId) {
      _publishOwner(
        null,
        restored: restored,
        position: restored ? position : null,
      );
    } else if (playerId != null && _pendingEnterPlayerId == playerId) {
      // A close callback can arrive before the enter method's success reply.
      _stateRevision++;
    }
    if (!_usesTrackedOwnerEvents) {
      // Preserve the native event contract of the mobile and Apple backends.
      // Their older callbacks omit IDs; commands must not synthesize duplicate
      // close events before the native didStop notification arrives.
      _onPipModeChangedController.add(
        PipModeChanged(
          isInPip: entered,
          isRestored: restored,
          position: restored ? position : null,
          playerId: playerId,
        ),
      );
    }
  }

  final _onPipModeChangedController =
      StreamController<PipModeChanged>.broadcast();
  final _onPipErrorController = StreamController<String>.broadcast();

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (_disposed) {
      return;
    }
    switch (call.method) {
      case 'nativeLog':
        final String message = call.arguments as String;
        debugPrint('[NATIVE PiP] $message');
        break;
      case 'pipModeChanged':
        final Map<Object?, Object?>? args =
            call.arguments as Map<Object?, Object?>?;
        _nativeModeChanged(args, entered: args?['isInPipMode'] == true);
        break;
      case 'onPipRestore':
        // Unified into the main state stream: PiP is stopping and the user
        // asked to restore the full-screen UI. Carry the native player
        // position so playback can resume exactly where it was left.
        final Map<Object?, Object?>? args =
            call.arguments as Map<Object?, Object?>?;
        _nativeModeChanged(args, entered: false, restored: true);
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
    if (_disposed) {
      return;
    }
    _disposed = true;
    _commandGeneration++;
    final events = _platformEventsSubscription;
    if (events != null) unawaited(events.cancel());
    if (kIsWeb) unawaited(_platform.reset());
    _publishOwner(null);
    pipPlayerId.removeListener(_onOwnerChanged);
    if (!_onPipModeChangedController.isClosed) {
      _onPipModeChangedController.close();
    }
    if (!_onPipErrorController.isClosed) {
      _onPipErrorController.close();
    }
    _channel.setMethodCallHandler(null);
    if (identical(_instance, this)) {
      _instance = null;
    }
  }
}
