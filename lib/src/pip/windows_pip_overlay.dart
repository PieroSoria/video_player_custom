// The player identifier is required to reuse the desktop video texture.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;

import 'video_player_custom_pip.dart';

/// Presentation for Windows compact overlay mode, using the existing player.
/// Hosts are registered by VideoPlayer; applications need no extra wrapper.
class WindowsPipOverlay {
  static bool get supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static final Map<
    Object,
    ({VideoPlayerController controller, BuildContext context})
  >
  _hosts = {};
  static OverlayEntry? _entry;
  static VideoPlayerController? _controller;
  static Object? _owner;

  static void register(
    Object owner,
    VideoPlayerController controller,
    BuildContext context,
  ) {
    if (supportedPlatform) {
      _hosts[owner] = (controller: controller, context: context);
    }
  }

  static void unregister(Object owner) {
    _hosts.remove(owner);
    if (identical(_owner, owner)) {
      remove();
      unawaited(VideoPlayerPip.reset());
    }
  }

  static void controllerDisposed(VideoPlayerController controller) {
    if (identical(_controller, controller)) {
      remove();
      unawaited(VideoPlayerPip.reset());
    }
  }

  static bool show(VideoPlayerController controller) {
    if (_entry != null) return identical(_controller, controller);
    for (final host in _hosts.entries.toList().reversed) {
      if (!identical(host.value.controller, controller) ||
          !host.value.context.mounted) {
        continue;
      }
      final overlay = Overlay.maybeOf(host.value.context, rootOverlay: true);
      if (overlay == null) continue;
      _owner = host.key;
      _controller = controller;
      _entry = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: Material(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: platform.VideoPlayerPlatform.instance
                        .buildViewWithOptions(
                          platform.VideoViewOptions(
                            playerId: controller.playerId,
                          ),
                        ),
                  ),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: controller,
                          builder: (_, value, _) => IconButton(
                            tooltip: value.isPlaying ? 'Pause' : 'Play',
                            color: Colors.white,
                            icon: Icon(
                              value.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                            onPressed: () => value.isPlaying
                                ? controller.pause()
                                : controller.play(),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Restore window',
                          color: Colors.white,
                          icon: const Icon(Icons.picture_in_picture_alt),
                          onPressed: VideoPlayerPip.exitPipMode,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      overlay.insert(_entry!);
      return true;
    }
    return false;
  }

  static void remove() {
    final entry = _entry;
    _entry = null;
    _controller = null;
    _owner = null;
    entry?.remove();
    entry?.dispose();
  }
}
