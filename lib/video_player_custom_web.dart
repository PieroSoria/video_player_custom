// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The web implementation is inlined in the same package as the core plugin.
// ignore: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'src/platform_impl/web/video_player.dart';
import 'src/platform_impl/web/web_pip.dart';
import 'src/platform_impl/web/web_tracks.dart' as browser_tracks;
import 'src/pip/video_player_custom_pip_platform_interface.dart';
import 'src/cache/network_cache.dart';

/// The web implementation of [VideoPlayerPlatform].
///
/// Uses HTML video playback and the browser's available Picture-in-Picture API.
class VideoPlayerCustomWeb extends VideoPlayerPlatform {
  VideoPlayerCustomWeb() {
    pip = WebVideoPlayerPip(
      resolveVideo: (id) => _videoPlayers[id]?.videoElement,
      resolveHost: (id) => _videoHosts[id],
    );
  }

  /// The PiP adapter shares the exact HTML video used for inline playback.
  late final WebVideoPlayerPip pip;

  /// Registers this class as the default instance of [VideoPlayerPlatform].
  static void registerWith(Registrar registrar) {
    final implementation = VideoPlayerCustomWeb();
    VideoPlayerPlatform.instance = implementation;
    VideoPlayerPipPlatform.instance = implementation.pip;
  }

  // Map of playerId -> VideoPlayer instances.
  final Map<int, VideoPlayer> _videoPlayers = <int, VideoPlayer>{};
  final Map<int, web.HTMLDivElement> _videoHosts = {};
  final Map<int, String> _ownedSources = {};

  static int _playerCounter = 1;

  @override
  Future<void> init() async {
    return _disposeAllPlayers();
  }

  @override
  Future<void> dispose(int playerId) async {
    pip.playerDisposed(playerId);
    _videoPlayers.remove(playerId)?.dispose();
    _videoHosts.remove(playerId);
    final source = _ownedSources.remove(playerId);
    if (source != null) releaseBrowserCachedSource(source);
  }

  Future<void> _disposeAllPlayers() async {
    for (final id in _videoPlayers.keys.toList()) {
      await dispose(id);
    }
  }

  @override
  Future<int> create(DataSource dataSource) {
    return createWithOptions(
      VideoCreationOptions(
        dataSource: dataSource,
        // Web only supports platform views.
        viewType: VideoViewType.platformView,
      ),
    );
  }

  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    // Parameter options.viewType is ignored because web only supports platform views.

    final DataSource dataSource = options.dataSource;
    final int playerId = _playerCounter++;

    late String uri;
    switch (dataSource.sourceType) {
      case DataSourceType.network:
        // Do NOT modify the incoming uri, it can be a Blob, and Safari doesn't
        // like blobs that have changed.
        uri = dataSource.uri ?? '';
      case DataSourceType.asset:
        String assetUrl = dataSource.asset!;
        if (dataSource.package != null && dataSource.package!.isNotEmpty) {
          assetUrl = 'packages/${dataSource.package}/$assetUrl';
        }
        assetUrl = ui_web.assetManager.getAssetUrl(assetUrl);
        uri = assetUrl;
      case DataSourceType.file:
        return Future<int>.error(UnimplementedError(
            'web implementation of video_player cannot play local files'));
      case DataSourceType.contentUri:
        return Future<int>.error(UnimplementedError(
            'web implementation of video_player cannot play content uri'));
    }

    if (dataSource.sourceType == DataSourceType.network &&
        dataSource.httpHeaders.isNotEmpty &&
        !uri.startsWith('blob:') && !uri.startsWith('data:')) {
      uri = await fetchBrowserVideoSource(
        uri,
        headers: dataSource.httpHeaders,
        formatHint: dataSource.formatHint,
      );
      _ownedSources[playerId] = uri;
    }

    final web.HTMLVideoElement videoElement = web.HTMLVideoElement()
      ..id = 'videoElement-$playerId'
      ..style.border = 'none'
      ..style.height = '100%'
      ..style.width = '100%';

    // Keep Flutter's platform-view host mounted when Document PiP adopts the
    // video into its own document. The PiP adapter renders a placeholder here.
    final host = web.HTMLDivElement()
      ..id = 'videoPlayerHost-$playerId'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.position = 'relative'
      ..style.backgroundColor = 'black';
    host.appendChild(videoElement);
    _videoHosts[playerId] = host;

    // TODO(hterkelsen): Use initialization parameters once they are available
    ui_web.platformViewRegistry.registerViewFactory(
        'videoPlayer-$playerId', (int viewId) => host);

    final VideoPlayer player = VideoPlayer(videoElement: videoElement)
      ..initialize(
        src: uri,
      );

    _videoPlayers[playerId] = player;
    pip.playerCreated(playerId);

    return playerId;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    return _player(playerId).setLooping(looping);
  }

  @override
  Future<void> play(int playerId) async {
    return _player(playerId).play();
  }

  @override
  Future<void> pause(int playerId) async {
    return _player(playerId).pause();
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    return _player(playerId).setVolume(volume);
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    return _player(playerId).setPlaybackSpeed(speed);
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {
    _player(playerId).setPreventsDisplaySleepDuringVideoPlayback(
      preventsDisplaySleepDuringVideoPlayback,
    );
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    return _player(playerId).seekTo(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    return _player(playerId).getPosition();
  }

  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) async =>
      browser_tracks.getAudioTracks(_player(playerId).videoElement);

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async =>
      browser_tracks.selectAudioTrack(_player(playerId).videoElement, trackId);

  @override
  bool isAudioTrackSupportAvailable() =>
      browser_tracks.isAudioTrackSupportAvailable;

  @override
  Future<List<VideoTrack>> getVideoTracks(int playerId) async =>
      browser_tracks.getVideoTracks(_player(playerId).videoElement);

  @override
  Future<void> selectVideoTrack(int playerId, VideoTrack? track) async =>
      browser_tracks.selectVideoTrack(_player(playerId).videoElement, track);

  @override
  bool isVideoTrackSupportAvailable() =>
      browser_tracks.isVideoTrackSupportAvailable;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return _player(playerId).events;
  }

  @override
  Future<void> setWebOptions(int playerId, VideoPlayerWebOptions options) {
    return _player(playerId).setOptions(options);
  }

  // Retrieves a [VideoPlayer] by its internal `id`.
  // It must have been created earlier from the [create] method.
  VideoPlayer _player(int id) {
    return _videoPlayers[id]!;
  }

  @override
  Widget buildView(int playerId) {
    return HtmlElementView(viewType: 'videoPlayer-$playerId');
  }

  /// Sets the audio mode to mix with other sources (ignored).
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future<void>.value();
}
