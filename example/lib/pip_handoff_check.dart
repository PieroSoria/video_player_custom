// Manual macOS regression check: use the native PiP close and restore buttons.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_custom/video_player_custom.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;

void main() => runApp(const MaterialApp(home: PipHandoffCheck()));

class PipHandoffCheck extends StatefulWidget {
  const PipHandoffCheck({super.key});

  @override
  State<PipHandoffCheck> createState() => _PipHandoffCheckState();
}

class _PipHandoffCheckState extends State<PipHandoffCheck> {
  final _controllers = <VideoPlayerController>[];
  late VideoPlayerController _controller;
  StreamSubscription<PipModeChanged>? _subscription;
  String _status = 'Open PiP, then use its close or restore button';
  bool _checking = false;

  VideoPlayerController _createController() {
    final controller = VideoPlayerController.asset(
      'assets/Butterfly-209.mp4',
      viewType: VideoViewType.platformView,
    );
    _controllers.add(controller);
    return controller;
  }

  Future<void> _start(VideoPlayerController controller) async {
    await controller.initialize();
    await controller.setLooping(true);
    await controller.play();
  }

  @override
  void initState() {
    super.initState();
    _controller = _createController();
    unawaited(_start(_controller));
    _subscription = _controller.onPipModeChanged.listen(_checkStop);
  }

  Future<void> _expectPaused(VideoPlayerController source) async {
    // Calling the backend directly exercises updatePlayingState even though
    // Dart already considers the source paused. A raw AVPlayer.pause() alone
    // leaves the native wrapper's playback intent set and fails this check.
    await platform.VideoPlayerPlatform.instance.setPlaybackSpeed(
      source.playerId,
      1,
    );
    var before = await source.position;
    await Future<void>.delayed(const Duration(seconds: 1));
    var after = await source.position;
    // AVKit may finish a pending backward seek when returning the layer.
    // Verify the clock remains stationary after that seek has completed.
    if (!source.value.isPlaying &&
        before != null &&
        after != null &&
        after < before) {
      before = after;
      await Future<void>.delayed(const Duration(seconds: 1));
      after = await source.position;
    }
    if (source.value.isPlaying ||
        before == null ||
        after == null ||
        (after - before).inMilliseconds.abs() > 100) {
      throw StateError(
        'The previous player is still playing: '
        'id=${source.playerId}, playing=${source.value.isPlaying}, '
        'before=$before, after=$after',
      );
    }
  }

  Future<void> _checkStop(PipModeChanged event) async {
    if (event.isInPip || _checking || !mounted) return;
    _checking = true;
    final source = _controller;
    try {
      await _expectPaused(source);
      if (event.isRestored && mounted) {
        final replacement = _createController();
        await VideoPlayerPip.resumeWithPosition(replacement, event.position);
        await replacement.setLooping(true);
        setState(() => _controller = replacement);
        // Keep the source alive while the new video plays to detect overlap.
        await _expectPaused(source);
        await source.dispose();
        _controllers.remove(source);
      }
      final result = event.isRestored
          ? 'PASS: replacement playing, previous player paused'
          : 'PASS: close stopped video and audio';
      debugPrint(result);
      if (mounted) setState(() => _status = result);
    } catch (error) {
      debugPrint('FAIL: $error');
      if (mounted) setState(() => _status = 'FAIL: $error');
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_status)),
    body: Center(
      child: SizedBox(width: 640, height: 360, child: VideoPlayer(_controller)),
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () async {
        if (_checking || !_controller.value.isInitialized) return;
        await _controller.play();
        await _controller.enterPipMode();
      },
      label: const Text('Open PiP'),
      icon: const Icon(Icons.picture_in_picture_alt),
    ),
  );

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    for (final controller in _controllers) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }
}
