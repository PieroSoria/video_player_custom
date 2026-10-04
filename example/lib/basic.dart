// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// This file is used to extract code samples for the README.md file.
// Run update-excerpts if you modify this file.

// ignore_for_file: library_private_types_in_public_api, public_member_api_docs

// #docregion basic-example
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_custom/video_player_custom.dart';

void main() => runApp(const VideoApp());

/// Stateful widget to fetch and then display video content.
class VideoApp extends StatefulWidget {
  const VideoApp({super.key});

  @override
  _VideoAppState createState() => _VideoAppState();
}

class _VideoAppState extends State<VideoApp> {
  late VideoPlayerController _controller;
  String _pipStatus = 'Video Demo';
  StreamSubscription<PipModeChanged>? _pipSubscription;

  Future<void> _togglePip() async {
    if (!_controller.value.isInitialized) return;
    final active = await _controller.isInPipMode();
    final success = active
        ? await _controller.exitPipMode()
        : await _controller.enterPipMode();
    if (mounted) {
      setState(
        () => _pipStatus = success
            ? (active ? 'PiP cerrado' : 'PiP activo')
            : 'PiP no disponible para este video',
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _pipSubscription = VideoPlayerPip.instance.onPipModeChanged.listen((
      event,
    ) async {
      if (event.isRestored && mounted) {
        await VideoPlayerPip.resumeWithPosition(_controller, event.position);
      }
      if (mounted) {
        setState(
          () => _pipStatus = event.isInPip ? 'PiP activo' : 'PiP cerrado',
        );
      }
    });
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(
        'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
      ),
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(true);
      if (mounted) await _controller.play();
    } catch (error) {
      if (mounted && !_controller.value.hasError) {
        _controller.value = VideoPlayerValue.erroneous(error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Demo',
      home: Scaffold(
        appBar: AppBar(
          title: Text(_pipStatus),
          actions: [
            IconButton(
              tooltip: 'Picture in Picture',
              icon: const Icon(Icons.picture_in_picture_alt),
              onPressed: _togglePip,
            ),
          ],
        ),
        body: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoPlayer(
              _controller,
              loadingBuilder: (_, progress) =>
                  const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, error) =>
                  Center(child: Text(error ?? 'Unable to play video')),
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            setState(() {
              _controller.value.isPlaying
                  ? _controller.pause()
                  : _controller.play();
            });
          },
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _controller,
            builder: (_, value, _) =>
                Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pipSubscription?.cancel();
    _controller.dispose();
    super.dispose();
  }
}

// #enddocregion basic-example
