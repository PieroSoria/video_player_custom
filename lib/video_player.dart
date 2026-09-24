// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math show max;

import 'package:collection/collection.dart' as collection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform_interface;

import 'src/closed_caption_file.dart';
import 'src/cache/video_player_cache.dart';

export 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show
        DataSourceType,
        DurationRange,
        VideoFormat,
        VideoPlayerOptions,
        VideoPlayerWebOptions,
        VideoPlayerWebOptionsControls,
        VideoViewType;

export 'src/closed_caption_file.dart';

/// Represents an audio track in a video with its metadata.
@immutable
class VideoAudioTrack {
  /// Constructs an instance of [VideoAudioTrack].
  const VideoAudioTrack({
    required this.id,
    required this.isSelected,
    this.label,
    this.language,
    this.bitrate,
    this.sampleRate,
    this.channelCount,
    this.codec,
  });

  /// Unique identifier for the audio track.
  final String id;

  /// Human-readable label for the track.
  ///
  /// May be null if not available from the platform.
  final String? label;

  /// Language code of the audio track (e.g., 'en', 'es', 'und').
  ///
  /// May be null if not available from the platform.
  final String? language;

  /// Whether this track is currently selected.
  final bool isSelected;

  /// Bitrate of the audio track in bits per second.
  ///
  /// May be null if not available from the platform.
  final int? bitrate;

  /// Sample rate of the audio track in Hz.
  ///
  /// May be null if not available from the platform.
  final int? sampleRate;

  /// Number of audio channels.
  ///
  /// May be null if not available from the platform.
  final int? channelCount;

  /// Audio codec used (e.g., 'aac', 'mp3', 'ac3').
  ///
  /// May be null if not available from the platform.
  final String? codec;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is VideoAudioTrack &&
            runtimeType == other.runtimeType &&
            id == other.id &&
            label == other.label &&
            language == other.language &&
            isSelected == other.isSelected &&
            bitrate == other.bitrate &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            codec == other.codec;
  }

  @override
  int get hashCode =>
      Object.hash(id, label, language, isSelected, bitrate, sampleRate, channelCount, codec);

  @override
  String toString() =>
      'VideoAudioTrack('
      'id: $id, '
      'label: $label, '
      'language: $language, '
      'isSelected: $isSelected, '
      'bitrate: $bitrate, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'codec: $codec)';
}

/// Converts a platform interface [VideoAudioTrack] to the public API type.
///
/// This internal method is used to decouple the public API from the
/// platform interface implementation.
VideoAudioTrack _convertPlatformAudioTrack(platform_interface.VideoAudioTrack platformTrack) {
  return VideoAudioTrack(
    id: platformTrack.id,
    label: platformTrack.label,
    language: platformTrack.language,
    isSelected: platformTrack.isSelected,
    bitrate: platformTrack.bitrate,
    sampleRate: platformTrack.sampleRate,
    channelCount: platformTrack.channelCount,
    codec: platformTrack.codec,
  );
}

platform_interface.VideoPlayerPlatform? _lastVideoPlayerPlatform;

platform_interface.VideoPlayerPlatform get _videoPlayerPlatform {
  final platform_interface.VideoPlayerPlatform currentInstance =
      platform_interface.VideoPlayerPlatform.instance;
  if (_lastVideoPlayerPlatform != currentInstance) {
    // This will clear all open videos on the platform when a full restart is
    // performed.
    currentInstance.init();
    _lastVideoPlayerPlatform = currentInstance;
  }
  return currentInstance;
}

/// The duration, current position, buffering state, error state and settings
/// of a [VideoPlayerController].
@immutable
class VideoPlayerValue {
  /// Constructs a video with the given values. Only [duration] is required. The
  /// rest will initialize with default values when unset.
  const VideoPlayerValue({
    required this.duration,
    this.size = Size.zero,
    this.position = Duration.zero,
    this.caption = Caption.none,
    this.captionOffset = Duration.zero,
    this.buffered = const <platform_interface.DurationRange>[],
    this.isInitialized = false,
    this.isPlaying = false,
    this.isLooping = false,
    this.isBuffering = false,
    this.volume = 1.0,
    this.playbackSpeed = 1.0,
    this.rotationCorrection = 0,
    this.errorDescription,
    this.isCompleted = false,
    this.preventsDisplaySleepDuringVideoPlayback = true,
  });

  /// Returns an instance for a video that hasn't been loaded.
  const VideoPlayerValue.uninitialized() : this(duration: Duration.zero, isInitialized: false);

  /// Returns an instance with the given [errorDescription].
  const VideoPlayerValue.erroneous(String errorDescription)
    : this(duration: Duration.zero, isInitialized: false, errorDescription: errorDescription);

  /// This constant is just to indicate that parameter is not passed to [copyWith]
  /// workaround for this issue https://github.com/dart-lang/language/issues/2009
  static const String _defaultErrorDescription = 'defaultErrorDescription';

  /// The total duration of the video.
  ///
  /// The value is only meaningful when [isInitialized] is true.
  final Duration duration;

  /// The current playback position.
  final Duration position;

  /// The [Caption] that should be displayed based on the current [position].
  ///
  /// This field will never be null. If there is no caption for the current
  /// [position], this will be a [Caption.none] object.
  final Caption caption;

  /// The [Duration] that should be used to offset the current [position] to get the correct [Caption].
  ///
  /// Defaults to Duration.zero.
  final Duration captionOffset;

  /// The currently buffered ranges.
  final List<platform_interface.DurationRange> buffered;

  /// True if the video is playing. False if it's paused.
  final bool isPlaying;

  /// True if the video is looping.
  final bool isLooping;

  /// True if the video is currently buffering.
  final bool isBuffering;

  /// The current volume of the playback.
  final double volume;

  /// The current speed of the playback.
  final double playbackSpeed;

  /// A description of the error if present.
  ///
  /// If [hasError] is false this is `null`.
  final String? errorDescription;

  /// True if video has finished playing to end.
  ///
  /// Reverts to false if video position changes, or video begins playing.
  /// Does not update if video is looping.
  final bool isCompleted;

  /// Whether the screen is prevented from sleeping during video playback.
  ///
  /// Defaults to `true`.
  ///
  /// This is currently only supported on iOS and macOS.
  final bool preventsDisplaySleepDuringVideoPlayback;

  /// The [size] of the currently loaded video.
  final Size size;

  /// Degrees to rotate the video (clockwise) so it is displayed correctly.
  final int rotationCorrection;

  /// Indicates whether or not the video has been loaded and is ready to play.
  final bool isInitialized;

  /// Indicates whether or not the video is in an error state. If this is true
  /// [errorDescription] should have information about the problem.
  bool get hasError => errorDescription != null;

  /// Returns [size.width] / [size.height].
  ///
  /// Will return `1.0` if:
  /// * [isInitialized] is `false`
  /// * [size.width], or [size.height] is equal to `0.0`
  /// * aspect ratio would be less than or equal to `0.0`
  double get aspectRatio {
    if (!isInitialized || size.width == 0 || size.height == 0) {
      return 1.0;
    }
    final double aspectRatio = size.width / size.height;
    if (aspectRatio <= 0) {
      return 1.0;
    }
    return aspectRatio;
  }

  /// Returns a new instance that has the same values as this current instance,
  /// except for any overrides passed in as arguments to [copyWith].
  VideoPlayerValue copyWith({
    Duration? duration,
    Size? size,
    Duration? position,
    Caption? caption,
    Duration? captionOffset,
    List<platform_interface.DurationRange>? buffered,
    bool? isInitialized,
    bool? isPlaying,
    bool? isLooping,
    bool? isBuffering,
    double? volume,
    double? playbackSpeed,
    int? rotationCorrection,
    String? errorDescription = _defaultErrorDescription,
    bool? isCompleted,
    bool? preventsDisplaySleepDuringVideoPlayback,
  }) {
    return VideoPlayerValue(
      duration: duration ?? this.duration,
      size: size ?? this.size,
      position: position ?? this.position,
      caption: caption ?? this.caption,
      captionOffset: captionOffset ?? this.captionOffset,
      buffered: buffered ?? this.buffered,
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isLooping: isLooping ?? this.isLooping,
      isBuffering: isBuffering ?? this.isBuffering,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      rotationCorrection: rotationCorrection ?? this.rotationCorrection,
      errorDescription: errorDescription != _defaultErrorDescription
          ? errorDescription
          : this.errorDescription,
      isCompleted: isCompleted ?? this.isCompleted,
      preventsDisplaySleepDuringVideoPlayback:
          preventsDisplaySleepDuringVideoPlayback ?? this.preventsDisplaySleepDuringVideoPlayback,
    );
  }

  @override
  String toString() {
    return '${objectRuntimeType(this, 'VideoPlayerValue')}('
        'duration: $duration, '
        'size: $size, '
        'position: $position, '
        'caption: $caption, '
        'captionOffset: $captionOffset, '
        'buffered: [${buffered.join(', ')}], '
        'isInitialized: $isInitialized, '
        'isPlaying: $isPlaying, '
        'isLooping: $isLooping, '
        'isBuffering: $isBuffering, '
        'volume: $volume, '
        'playbackSpeed: $playbackSpeed, '
        'errorDescription: $errorDescription, '
        'isCompleted: $isCompleted, '
        'preventsDisplaySleepDuringVideoPlayback: $preventsDisplaySleepDuringVideoPlayback),';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoPlayerValue &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          position == other.position &&
          caption == other.caption &&
          captionOffset == other.captionOffset &&
          listEquals(buffered, other.buffered) &&
          isPlaying == other.isPlaying &&
          isLooping == other.isLooping &&
          isBuffering == other.isBuffering &&
          volume == other.volume &&
          playbackSpeed == other.playbackSpeed &&
          errorDescription == other.errorDescription &&
          size == other.size &&
          rotationCorrection == other.rotationCorrection &&
          isInitialized == other.isInitialized &&
          isCompleted == other.isCompleted &&
          preventsDisplaySleepDuringVideoPlayback == other.preventsDisplaySleepDuringVideoPlayback;

  @override
  int get hashCode => Object.hash(
    duration,
    position,
    caption,
    captionOffset,
    buffered,
    isPlaying,
    isLooping,
    isBuffering,
    volume,
    playbackSpeed,
    errorDescription,
    size,
    rotationCorrection,
    isInitialized,
    isCompleted,
    preventsDisplaySleepDuringVideoPlayback,
  );
}

/// Controls a platform video player, and provides updates when the state is
/// changing.
///
/// Instances must be initialized with initialize.
///
/// The video is displayed in a Flutter app by creating a [VideoPlayer] widget.
///
/// To reclaim the resources used by the player call [dispose].
///
/// After [dispose] all further calls are ignored.
class VideoPlayerController extends ValueNotifier<VideoPlayerValue> {
  /// Constructs a [VideoPlayerController] playing a video from an asset.
  ///
  /// The name of the asset is given by the [dataSource] argument and must not be
  /// null. The [package] argument must be non-null when the asset comes from a
  /// package and null otherwise.
  ///
  /// The [viewType] option allows the caller to request a specific display mode
  /// for the video. Platforms that do not support the request view type will
  /// ignore this parameter.
  VideoPlayerController.asset(
    this.dataSource, {
    this.package,
    Future<ClosedCaptionFile>? closedCaptionFile,
    this.videoPlayerOptions,
    this.viewType = platform_interface.VideoViewType.textureView,
  }) : _closedCaptionFileFuture = closedCaptionFile,
       dataSourceType = platform_interface.DataSourceType.asset,
       formatHint = null,
       httpHeaders = const <String, String>{},
       cacheKey = null,
       isLive = false,
       super(
         VideoPlayerValue(
           duration: Duration.zero,
           preventsDisplaySleepDuringVideoPlayback:
               videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
         ),
       );

  /// Constructs a [VideoPlayerController] playing a network video.
  ///
  /// The URI for the video is given by the [dataSource] argument.
  ///
  /// **Android only**: The [formatHint] option allows the caller to override
  /// the video format detection code.
  ///
  /// The [viewType] option allows the caller to request a specific display mode
  /// for the video. Platforms that do not support the request view type will
  /// ignore this parameter.
  ///
  /// [httpHeaders] option allows to specify HTTP headers
  /// for the request to the [dataSource].
  @Deprecated('Use VideoPlayerController.networkUrl instead')
  VideoPlayerController.network(
    this.dataSource, {
    this.formatHint,
    Future<ClosedCaptionFile>? closedCaptionFile,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    this.viewType = platform_interface.VideoViewType.textureView,
  }) : _closedCaptionFileFuture = closedCaptionFile,
       dataSourceType = platform_interface.DataSourceType.network,
       package = null,
       cacheKey = null,
       isLive = false,
       super(
         VideoPlayerValue(
           duration: Duration.zero,
           preventsDisplaySleepDuringVideoPlayback:
               videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
         ),
       );

  /// Constructs a [VideoPlayerController] playing a network video.
  ///
  /// The URI for the video is given by the [dataSource] argument.
  ///
  /// **Android only**: The [formatHint] option allows the caller to override
  /// the video format detection code.
  ///
  /// [httpHeaders] option allows to specify HTTP headers
  /// for the request to the [dataSource].
  VideoPlayerController.networkUrl(
    Uri url, {
    this.formatHint,
    Future<ClosedCaptionFile>? closedCaptionFile,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    this.cacheKey,
    this.isLive = false,
    this.viewType = platform_interface.VideoViewType.textureView,
  }) : _closedCaptionFileFuture = closedCaptionFile,
       dataSource = url.toString(),
       dataSourceType = platform_interface.DataSourceType.network,
       package = null,
       super(
         VideoPlayerValue(
           duration: Duration.zero,
           preventsDisplaySleepDuringVideoPlayback:
               videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
         ),
       );

  /// Constructs a [VideoPlayerController] playing a video from a file.
  ///
  /// This will load the file from a file:// URI constructed from [file]'s path.
  /// [httpHeaders] option allows to specify HTTP headers, mainly used for hls files like (m3u8).
  VideoPlayerController.file(
    File file, {
    Future<ClosedCaptionFile>? closedCaptionFile,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    this.viewType = platform_interface.VideoViewType.textureView,
  }) : _closedCaptionFileFuture = closedCaptionFile,
       dataSource = Uri.file(file.absolute.path).toString(),
       dataSourceType = platform_interface.DataSourceType.file,
       package = null,
       formatHint = null,
       cacheKey = null,
       isLive = false,
       super(
         VideoPlayerValue(
           duration: Duration.zero,
           preventsDisplaySleepDuringVideoPlayback:
               videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
         ),
       );

  /// Constructs a [VideoPlayerController] playing a video from a contentUri.
  ///
  /// This will load the video from the input content-URI.
  /// This is supported on Android only.
  VideoPlayerController.contentUri(
    Uri contentUri, {
    Future<ClosedCaptionFile>? closedCaptionFile,
    this.videoPlayerOptions,
    this.viewType = platform_interface.VideoViewType.textureView,
  }) : assert(
         defaultTargetPlatform == TargetPlatform.android,
         'VideoPlayerController.contentUri is only supported on Android.',
       ),
       _closedCaptionFileFuture = closedCaptionFile,
       dataSource = contentUri.toString(),
       dataSourceType = platform_interface.DataSourceType.contentUri,
       package = null,
       formatHint = null,
       httpHeaders = const <String, String>{},
       cacheKey = null,
       isLive = false,
       super(
         VideoPlayerValue(
           duration: Duration.zero,
           preventsDisplaySleepDuringVideoPlayback:
               videoPlayerOptions?.preventsDisplaySleepDuringVideoPlayback ?? true,
         ),
       );

  /// The URI to the video file. This will be in different formats depending on
  /// the [DataSourceType] of the original video.
  final String dataSource;

  /// HTTP headers used for the request to the [dataSource].
  /// Only for [VideoPlayerController.network].
  /// Always empty for other video types.
  final Map<String, String> httpHeaders;

  /// **Android only**. Will override the platform's generic file format
  /// detection with whatever is set here.
  final platform_interface.VideoFormat? formatHint;

  /// Describes the type of data source this [VideoPlayerController]
  /// is constructed with.
  final platform_interface.DataSourceType dataSourceType;

  /// Provide additional configuration options (optional). Like setting the audio mode to mix
  final platform_interface.VideoPlayerOptions? videoPlayerOptions;

  /// Only set for [asset] videos. The package that the asset was loaded from.
  final String? package;

  /// Optional disk-cache entry for network videos (`networkUrl`).
  ///
  /// When set, `initialize()` reuses the cached copy on disk when available
  /// (no network, instant open) and, on a miss, keeps streaming from the
  /// network while the media is downloaded in the background for next time.
  /// See [VideoPlayerCache.instance] to configure the cache directory.
  ///
  /// HLS (`.m3u8`/`.m3u` or `formatHint: VideoFormat.hls`), DASH (`.mpd` or
  /// `formatHint: VideoFormat.dash`) and Smooth Streaming (`Manifest` or
  /// `formatHint: VideoFormat.ss`) cache their whole presentation —
  /// manifests, segments and keys are downloaded and rewritten to local
  /// files. Live sources stream live and are never cached (see [isLive]).
  ///
  /// Note: on iOS and macOS, cached manifests are played through an in-process
  /// loopback HTTP server, because AVFoundation cannot play manifest
  /// playlists from a `file://` path.
  final String? cacheKey;

  /// Marks a live network stream.
  ///
  /// Live streams are ephemeral by nature, so they are never written to the
  /// disk cache: [cacheKey] is ignored and playback always streams from the
  /// network.
  final bool isLive;

  /// The requested display mode for the video.
  ///
  /// Platforms that do not support the request view type will ignore this.
  final platform_interface.VideoViewType viewType;

  Future<ClosedCaptionFile>? _closedCaptionFileFuture;
  ClosedCaptionFile? _closedCaptionFile;
  List<Caption>? _sortedCaptions;

  Timer? _timer;
  bool _isDisposed = false;
  Completer<void>? _creatingCompleter;
  StreamSubscription<dynamic>? _eventSubscription;
  _VideoAppLifeCycleObserver? _lifeCycleObserver;

  /// The id of a player that hasn't been initialized.
  @visibleForTesting
  static const int kUninitializedPlayerId = -1;
  int _playerId = kUninitializedPlayerId;

  /// This is just exposed for testing. It shouldn't be used by anyone depending
  /// on the plugin.
  @visibleForTesting
  int get playerId => _playerId;

  /// Resolves the effective source for a network video.
  ///
  /// With a [cacheKey], a cached copy takes priority (immediate, offline
  /// playback); on a miss the network is used for playback while the media is
  /// downloaded in the background for the next open. HLS, DASH and Smooth
  /// Streaming presentations are cached whole — playlists/manifests, segments
  /// and keys are downloaded and rewritten to local files. Live sources
  /// ([isLive]) always stream from the network and are never written to the
  /// cache, as are live manifests themselves (dynamic DASH, DVR Smooth
  /// Streaming), which the downloaders reject.
  ///
  /// On iOS and macOS (AVFoundation) the cached manifest is served to the
  /// player over an in-process loopback HTTP server (`127.0.0.1`), because
  /// AVFoundation does not play `.m3u8`/`.mpd` from `file://` paths.
  Future<platform_interface.DataSource> _networkDataSource(
    String uri, {
    required Map<String, String> httpHeaders,
    String? cacheKey,
  }) async {
    if (cacheKey == null || kIsWeb || isLive) {
      return platform_interface.DataSource(
        sourceType: platform_interface.DataSourceType.network,
        uri: uri,
        formatHint: formatHint,
        httpHeaders: httpHeaders,
      );
    }
    final File? cached = await VideoPlayerCache.instance
        .fileFor(uri, cacheKey: cacheKey, formatHint: formatHint);
    if (cached != null) {
      if (_manifestRequiresHttp(uri)) {
        // AVFoundation refuses file:// manifests; serve the cached copy over
        // the loopback HTTP server instead. If the server is unavailable,
        // stream from the network rather than handing AVFoundation a file://
        // playlist that would never load.
        final Uri? overHttp = await VideoPlayerCache.instance.serveManifestHttp(
          uri,
          cacheKey: cacheKey,
        );
        if (overHttp != null) {
          Uri uriToPlay = overHttp;
          // HLS: tell AVFoundation how much media to keep buffered ahead of
          // the playhead. The value is derived from the presentation's own
          // segment duration (about three segments) instead of being fixed, so
          // the decoder keeps enough runway at segment boundaries for the
          // picture not to freeze while audio continues. The loopback feed
          // fills instantly, so the preload wait is negligible.
          if (VideoPlayerCache.manifestExtension(uri, formatHint) == '.m3u8') {
            final double? target =
                await VideoPlayerCache.hlsTargetDurationSeconds(cached);
            if (target != null) {
              final double seconds =
                  (target.clamp(1.0, 5.0) * 3.0).toDouble(); // 3-15s of runway.
              uriToPlay = overHttp.replace(queryParameters: <String, String>{
                ...overHttp.queryParameters,
                'forward': seconds.toStringAsFixed(1),
              });
            }
          }
          return platform_interface.DataSource(
            sourceType: platform_interface.DataSourceType.network,
            uri: uriToPlay.toString(),
            formatHint: formatHint,
          );
        }
        return platform_interface.DataSource(
          sourceType: platform_interface.DataSourceType.network,
          uri: uri,
          formatHint: formatHint,
          httpHeaders: httpHeaders,
        );
      }
      return platform_interface.DataSource(
        sourceType: platform_interface.DataSourceType.network,
        uri: cached.uri.toString(),
        formatHint: formatHint,
      );
    }
    // Playback streams live while the media is downloaded in the background;
    // the next open uses the local copy.
    unawaited(_prefetchForCache(uri, httpHeaders));
    return platform_interface.DataSource(
      sourceType: platform_interface.DataSourceType.network,
      uri: uri,
      formatHint: formatHint,
      httpHeaders: httpHeaders,
    );
  }

  /// Whether a cached manifest must be handed to the platform over HTTP.
  ///
  /// AVFoundation refuses to play HLS (and any rewritten manifest) from a
  /// `file://` path — it only accepts manifests served over HTTP — so iOS
  /// and macOS serve cached manifest entries through the cache's loopback
  /// HTTP server instead. Other platforms (e.g. ExoPlayer on Android) play
  /// the local files directly. Returns `false` for plain media files.
  bool _manifestRequiresHttp(String uri) {
    if (VideoPlayerCache.manifestExtension(uri, formatHint) == null) {
      return false;
    }
    return Platform.isIOS || Platform.isMacOS;
  }

  Future<void> _prefetchForCache(
    String uri,
    Map<String, String> httpHeaders,
  ) async {
    try {
      await VideoPlayerCache.instance.prefetch(
        uri,
        cacheKey: cacheKey,
        headers: httpHeaders,
        formatHint: formatHint,
      );
    } catch (error) {
      debugPrint('VideoPlayerCache: prefetch failed for $uri ($error)');
    }
  }

  /// Attempts to open the given [dataSource] and load metadata about the video.
  Future<void> initialize() async {
    final bool allowBackgroundPlayback = videoPlayerOptions?.allowBackgroundPlayback ?? false;
    if (!allowBackgroundPlayback) {
      _lifeCycleObserver = _VideoAppLifeCycleObserver(this);
    }
    _lifeCycleObserver?.initialize();
    _creatingCompleter = Completer<void>();

    final platform_interface.DataSource dataSourceDescription;
    switch (dataSourceType) {
      case platform_interface.DataSourceType.asset:
        dataSourceDescription = platform_interface.DataSource(
          sourceType: platform_interface.DataSourceType.asset,
          asset: dataSource,
          package: package,
        );
      case platform_interface.DataSourceType.network:
        dataSourceDescription = await _networkDataSource(
          dataSource,
          httpHeaders: httpHeaders,
          cacheKey: cacheKey,
        );
      case platform_interface.DataSourceType.file:
        dataSourceDescription = platform_interface.DataSource(
          sourceType: platform_interface.DataSourceType.file,
          uri: dataSource,
          httpHeaders: httpHeaders,
        );
      case platform_interface.DataSourceType.contentUri:
        dataSourceDescription = platform_interface.DataSource(
          sourceType: platform_interface.DataSourceType.contentUri,
          uri: dataSource,
        );
    }

    final creationOptions = platform_interface.VideoCreationOptions(
      dataSource: dataSourceDescription,
      viewType: viewType,
      videoPlayerOptions: videoPlayerOptions,
    );

    if (videoPlayerOptions?.mixWithOthers != null) {
      await _videoPlayerPlatform.setMixWithOthers(videoPlayerOptions!.mixWithOthers);
    }

    _playerId =
        (await _videoPlayerPlatform.createWithOptions(creationOptions)) ?? kUninitializedPlayerId;
    _creatingCompleter!.complete(null);
    final initializingCompleter = Completer<void>();

    await _videoPlayerPlatform.setPreventsDisplaySleepDuringVideoPlayback(
      _playerId,
      value.preventsDisplaySleepDuringVideoPlayback,
    );

    // Apply the web-specific options
    if (kIsWeb && videoPlayerOptions?.webOptions != null) {
      await _videoPlayerPlatform.setWebOptions(_playerId, videoPlayerOptions!.webOptions!);
    }

    void eventListener(platform_interface.VideoEvent event) {
      if (_isDisposed) {
        return;
      }

      switch (event.eventType) {
        case platform_interface.VideoEventType.initialized:
          value = value.copyWith(
            duration: event.duration,
            size: event.size,
            rotationCorrection: event.rotationCorrection,
            isInitialized: event.duration != null,
            errorDescription: null,
            isCompleted: false,
          );
          assert(
            !initializingCompleter.isCompleted,
            'VideoPlayerController already initialized. This is typically a '
            'sign that an implementation of the VideoPlayerPlatform '
            '(${_videoPlayerPlatform.runtimeType}) has a bug and is sending '
            'more than one initialized event per instance.',
          );
          if (initializingCompleter.isCompleted) {
            throw StateError('VideoPlayerController already initialized');
          }
          initializingCompleter.complete(null);
          _applyLooping();
          _applyVolume();
          _applyPlayPause();
        case platform_interface.VideoEventType.completed:
          // In this case we need to stop _timer, set isPlaying=false, and
          // position=value.duration. Instead of setting the values directly,
          // we use pause() and seekTo() to ensure the platform stops playing
          // and seeks to the last frame of the video.
          pause().then((void pauseResult) => seekTo(value.duration));
          value = value.copyWith(isCompleted: true);
        case platform_interface.VideoEventType.bufferingUpdate:
          value = value.copyWith(buffered: event.buffered);
        case platform_interface.VideoEventType.bufferingStart:
          value = value.copyWith(isBuffering: true);
        case platform_interface.VideoEventType.bufferingEnd:
          value = value.copyWith(isBuffering: false);
        case platform_interface.VideoEventType.isPlayingStateUpdate:
          if (event.isPlaying ?? false) {
            value = value.copyWith(isPlaying: event.isPlaying, isCompleted: false);
          } else {
            value = value.copyWith(isPlaying: event.isPlaying);
          }
        case platform_interface.VideoEventType.unknown:
          break;
      }
    }

    if (_closedCaptionFileFuture != null) {
      await _updateClosedCaptionWithFuture(_closedCaptionFileFuture);
    }

    void errorListener(Object obj) {
      final e = obj as PlatformException;
      value = VideoPlayerValue.erroneous(e.message!);
      _timer?.cancel();
      if (!initializingCompleter.isCompleted) {
        initializingCompleter.completeError(obj);
      }
    }

    _eventSubscription = _videoPlayerPlatform
        .videoEventsFor(_playerId)
        .listen(eventListener, onError: errorListener);
    return initializingCompleter.future;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    if (_creatingCompleter != null) {
      await _creatingCompleter!.future;
      if (!_isDisposed) {
        _isDisposed = true;
        _timer?.cancel();
        await _eventSubscription?.cancel();
        await _videoPlayerPlatform.dispose(_playerId);
      }
      _lifeCycleObserver?.dispose();
    }
    _isDisposed = true;
    super.dispose();
  }

  /// Starts playing the video.
  ///
  /// If the video is at the end, this method starts playing from the beginning.
  ///
  /// This method returns a future that completes as soon as the "play" command
  /// has been sent to the platform, not when playback itself is totally
  /// finished.
  Future<void> play() async {
    if (value.position == value.duration) {
      await seekTo(Duration.zero);
    }
    value = value.copyWith(isPlaying: true);
    await _applyPlayPause();
  }

  /// Sets whether or not the video should loop after playing once. See also
  /// [VideoPlayerValue.isLooping].
  Future<void> setLooping(bool looping) async {
    value = value.copyWith(isLooping: looping);
    await _applyLooping();
  }

  /// Sets whether the screen is prevented from sleeping during video playback.
  ///
  /// See also [VideoPlayerValue.preventsDisplaySleepDuringVideoPlayback].
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {
    value = value.copyWith(
      preventsDisplaySleepDuringVideoPlayback: preventsDisplaySleepDuringVideoPlayback,
    );
    await _applyPreventsDisplaySleepDuringVideoPlayback();
  }

  /// Pauses the video.
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
    await _applyPlayPause();
  }

  Future<void> _applyLooping() async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    await _videoPlayerPlatform.setLooping(_playerId, value.isLooping);
  }

  Future<void> _applyPreventsDisplaySleepDuringVideoPlayback() async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    await _videoPlayerPlatform.setPreventsDisplaySleepDuringVideoPlayback(
      _playerId,
      value.preventsDisplaySleepDuringVideoPlayback,
    );
  }

  Future<void> _applyPlayPause() async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    if (value.isPlaying) {
      await _videoPlayerPlatform.play(_playerId);

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 100), (Timer timer) async {
        if (_isDisposed) {
          return;
        }
        final Duration? newPosition = await position;
        if (newPosition == null) {
          return;
        }
        _updatePosition(newPosition);
      });

      // This ensures that the correct playback speed is always applied when
      // playing back. This is necessary because we do not set playback speed
      // when paused.
      await _applyPlaybackSpeed();
    } else {
      _timer?.cancel();
      await _videoPlayerPlatform.pause(_playerId);
    }
  }

  Future<void> _applyVolume() async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    await _videoPlayerPlatform.setVolume(_playerId, value.volume);
  }

  Future<void> _applyPlaybackSpeed() async {
    if (_isDisposedOrNotInitialized) {
      return;
    }

    // Setting the playback speed on iOS will trigger the video to play. We
    // prevent this from happening by not applying the playback speed until
    // the video is manually played from Flutter.
    if (!value.isPlaying) {
      return;
    }

    await _videoPlayerPlatform.setPlaybackSpeed(_playerId, value.playbackSpeed);
  }

  /// The position in the current video.
  Future<Duration?> get position async {
    if (_isDisposed) {
      return null;
    }
    return _videoPlayerPlatform.getPosition(_playerId);
  }

  /// Sets the video's current timestamp to be at [moment]. The next
  /// time the video is played it will resume from the given [moment].
  ///
  /// If [moment] is outside of the video's full range it will be automatically
  /// and silently clamped.
  Future<void> seekTo(Duration position) async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    if (position > value.duration) {
      position = value.duration;
    } else if (position < Duration.zero) {
      position = Duration.zero;
    }
    await _videoPlayerPlatform.seekTo(_playerId, position);
    _updatePosition(position);
  }

  /// Sets the audio volume of [this].
  ///
  /// [volume] indicates a value between 0.0 (silent) and 1.0 (full volume) on a
  /// linear scale.
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume.clamp(0.0, 1.0));
    await _applyVolume();
  }

  /// Sets the playback speed of [this].
  ///
  /// [speed] indicates a speed value with different platforms accepting
  /// different ranges for speed values. The [speed] must be greater than 0.
  ///
  /// The values will be handled as follows:
  /// * On web, the audio will be muted at some speed when the browser
  ///   determines that the sound would not be useful anymore. For example,
  ///   "Gecko mutes the sound outside the range `0.25` to `5.0`" (see https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/playbackRate).
  /// * On Android, some very extreme speeds will not be played back accurately.
  ///   Instead, your video will still be played back, but the speed will be
  ///   clamped by ExoPlayer (but the values are allowed by the player, like on
  ///   web).
  /// * On iOS, you can sometimes not go above `2.0` playback speed on a video.
  ///   An error will be thrown for if the option is unsupported. It is also
  ///   possible that your specific video cannot be slowed down, in which case
  ///   the plugin also reports errors.
  Future<void> setPlaybackSpeed(double speed) async {
    if (speed < 0) {
      throw ArgumentError.value(speed, 'Negative playback speeds are generally unsupported.');
    } else if (speed == 0) {
      throw ArgumentError.value(
        speed,
        'Zero playback speed is generally unsupported. Consider using [pause].',
      );
    }

    value = value.copyWith(playbackSpeed: speed);
    await _applyPlaybackSpeed();
  }

  /// Sets the caption offset.
  ///
  /// The [offset] will be used when getting the correct caption for a specific position.
  /// The [offset] can be positive or negative.
  ///
  /// The values will be handled as follows:
  /// *  0: This is the default behaviour. No offset will be applied.
  /// * >0: The caption will have a negative offset. So you will get caption text from the past.
  /// * <0: The caption will have a positive offset. So you will get caption text from the future.
  void setCaptionOffset(Duration offset) {
    value = value.copyWith(captionOffset: offset, caption: _getCaptionAt(value.position));
  }

  /// The closed caption based on the current [position] in the video.
  ///
  /// If there are no closed captions at the current [position], this will
  /// return an empty [Caption].
  ///
  /// If no [closedCaptionFile] was specified, this will always return an empty
  /// [Caption].

  Caption _getCaptionAt(Duration position) {
    final List<Caption>? sortedCaptions = _sortedCaptions;
    if (_closedCaptionFile == null || sortedCaptions == null) {
      return Caption.none;
    }

    final Duration delayedPosition = position + value.captionOffset;

    final int captionIndex = collection.binarySearch<Caption>(
      sortedCaptions,
      Caption(number: -1, start: delayedPosition, end: delayedPosition, text: ''),
      compare: (Caption candidate, Caption search) {
        if (search.start < candidate.start) {
          return 1;
        } else if (search.start > candidate.end) {
          return -1;
        } else {
          // delayedPosition is within [candidate.start, candidate.end]
          return 0;
        }
      },
    );

    // -1 means not found by the binary search.
    if (captionIndex == -1) {
      return Caption.none;
    }

    return sortedCaptions[captionIndex];
  }

  /// Returns the file containing closed captions for the video, if any.
  Future<ClosedCaptionFile>? get closedCaptionFile {
    return _closedCaptionFileFuture;
  }

  /// Sets a closed caption file.
  ///
  /// If [closedCaptionFile] is null, closed captions will be removed.
  Future<void> setClosedCaptionFile(Future<ClosedCaptionFile>? closedCaptionFile) async {
    _closedCaptionFileFuture = closedCaptionFile;
    // Reset sorted captions to force re-sort when setting a new file
    _sortedCaptions = null;
    await _updateClosedCaptionWithFuture(closedCaptionFile);
  }

  Future<void> _updateClosedCaptionWithFuture(Future<ClosedCaptionFile>? closedCaptionFile) async {
    if (closedCaptionFile != null) {
      _closedCaptionFile = await closedCaptionFile;

      // Only sort if we haven't sorted yet (first initialization)
      _sortedCaptions ??= List<Caption>.from(_closedCaptionFile!.captions)
        ..sort((Caption a, Caption b) {
          return a.start.compareTo(b.start);
        });

      value = value.copyWith(caption: _getCaptionAt(value.position));
    } else {
      _closedCaptionFile = null;
      _sortedCaptions = null;
      value = value.copyWith(caption: Caption.none);
    }
  }

  void _updatePosition(Duration position) {
    // The underlying native implementation on some platforms sometimes reports
    // a position slightly past the reported max duration. Clamp to the duration
    // to insulate clients from this behavior.
    if (position > value.duration) {
      position = value.duration;
    }
    value = value.copyWith(
      position: position,
      caption: _getCaptionAt(position),
      isCompleted: position == value.duration,
    );
  }

  @override
  void removeListener(VoidCallback listener) {
    // Prevent VideoPlayer from causing an exception to be thrown when attempting to
    // remove its own listener after the controller has already been disposed.
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }

  /// Gets the available audio tracks for the video.
  ///
  /// Returns a list of [VideoAudioTrack] objects containing metadata about
  /// each available audio track. The list may be empty if no audio tracks
  /// are available or if the video is not initialized.
  ///
  /// Throws an error if the video player is disposed.
  Future<List<VideoAudioTrack>> getAudioTracks() async {
    if (_isDisposed) {
      throw StateError('VideoPlayerController is disposed');
    }
    if (!value.isInitialized) {
      return <VideoAudioTrack>[];
    }
    final List<platform_interface.VideoAudioTrack> platformTracks = await _videoPlayerPlatform
        .getAudioTracks(_playerId);
    return platformTracks.map(_convertPlatformAudioTrack).toList();
  }

  /// Selects which audio track is chosen for playback from its [trackId]
  ///
  /// The [trackId] should match the ID of one of the tracks returned by
  /// [getAudioTracks]. If the track ID is not found or invalid, the
  /// platform may ignore the request or throw an exception.
  ///
  /// Throws an error if the video player is disposed or not initialized.
  Future<void> selectAudioTrack(String trackId) async {
    if (_isDisposedOrNotInitialized) {
      throw StateError('VideoPlayerController is disposed or not initialized');
    }
    // The platform implementation (e.g., Android) will wait for the track
    // selection to complete by listening to platform-specific events
    await _videoPlayerPlatform.selectAudioTrack(_playerId, trackId);
  }

  /// Returns whether audio track selection is supported on this platform.
  ///
  /// This method allows developers to query at runtime whether the current
  /// platform supports audio track selection functionality. This is useful
  /// for platforms like web where audio track selection may not be available.
  ///
  /// Returns `true` if [getAudioTracks] and [selectAudioTrack] are supported,
  /// `false` otherwise.
  ///
  /// Example usage:
  /// ```dart
  /// if (controller.isAudioTrackSupportAvailable()) {
  ///   final tracks = await controller.getAudioTracks();
  ///   // Show audio track selection UI
  /// } else {
  ///   // Hide audio track selection UI or show unsupported message
  /// }
  /// ```
  bool isAudioTrackSupportAvailable() {
    return _videoPlayerPlatform.isAudioTrackSupportAvailable();
  }

  bool get _isDisposedOrNotInitialized => _isDisposed || !value.isInitialized;

  /// Gets the available video tracks for the video.
  ///
  /// The returned list contains a [VideoTrack] for each track available
  /// for selection.
  ///
  /// For adaptive streams such as HLS or DASH, these often correspond to
  /// different quality levels with different resolutions or bitrates.
  /// For non-adaptive videos (MP4, MOV, etc.), platform implementations may
  /// return one or more tracks, or an empty list, depending on the asset and
  /// the metadata available.
  ///
  /// Note: On iOS 13-14, this returns an empty list as the AVAssetVariant API
  /// requires iOS 15+. On web, this throws an [UnimplementedError].
  ///
  /// Check [isVideoTrackSupportAvailable] before calling this method to ensure
  /// the platform supports video track selection.
  Future<List<VideoTrack>> getVideoTracks() async {
    if (_isDisposedOrNotInitialized) {
      return <VideoTrack>[];
    }
    final List<platform_interface.VideoTrack> platformTracks = await _videoPlayerPlatform
        .getVideoTracks(_playerId);
    return platformTracks
        .map((platform_interface.VideoTrack track) => VideoTrack._fromPlatform(track))
        .toList();
  }

  /// Selects which video track is chosen for playback.
  ///
  /// Pass a [VideoTrack] to select a specific track.
  /// Pass `null` to clear any manual selection and allow automatic selection.
  ///
  /// On iOS, this sets `preferredPeakBitRate` on the AVPlayerItem.
  /// On Android, this uses ExoPlayer's track selection override.
  /// On web, this throws an [UnimplementedError].
  ///
  /// Check [isVideoTrackSupportAvailable] before calling this method to ensure
  /// the platform supports video track selection.
  Future<void> selectVideoTrack(VideoTrack? track) async {
    if (_isDisposedOrNotInitialized) {
      return;
    }
    // Convert app-facing VideoTrack to platform interface VideoTrack
    final platform_interface.VideoTrack? platformTrack = track != null
        ? platform_interface.VideoTrack(
            id: track.id,
            isSelected: track.isSelected,
            label: track.label,
            bitrate: track.bitrate,
            width: track.width,
            height: track.height,
            frameRate: track.frameRate,
            codec: track.codec,
          )
        : null;
    await _videoPlayerPlatform.selectVideoTrack(_playerId, platformTrack);
  }

  /// Whether video track selection is supported on this platform.
  ///
  /// Use this to check before calling [getVideoTracks] or [selectVideoTrack]
  /// to avoid [UnimplementedError] exceptions on unsupported platforms.
  bool isVideoTrackSupportAvailable() {
    return _videoPlayerPlatform.isVideoTrackSupportAvailable();
  }
}

class _VideoAppLifeCycleObserver extends Object with WidgetsBindingObserver {
  _VideoAppLifeCycleObserver(this._controller);

  bool _wasPlayingBeforePause = false;
  final VideoPlayerController _controller;

  void initialize() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasPlayingBeforePause = _controller.value.isPlaying;
      _controller.pause();
    } else if (state == AppLifecycleState.resumed) {
      if (_wasPlayingBeforePause) {
        _controller.play();
      }
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// Signature for the [VideoPlayer.loadingBuilder] argument.
///
/// [progress] is the buffered fraction of the video (`0.0`–`1.0`); it is `0.0`
/// while the buffered range is not yet measurable, never `null`.
typedef VideoPlayerLoadingBuilder =
    Widget Function(BuildContext context, double progress);

/// Signature for the [VideoPlayer.errorBuilder] argument.
///
/// [error] is the [VideoPlayerValue.errorDescription] reported by the
/// controller, or `null` when no description is available.
typedef VideoPlayerErrorBuilder =
    Widget Function(BuildContext context, String? error);

/// Widget that displays the video controlled by [controller].
class VideoPlayer extends StatefulWidget {
  /// Uses the given [controller] for all video rendered in this widget.
  ///
  /// When [loadingBuilder] is provided it is shown while the controller is
  /// initializing or buffering. When [errorBuilder] is provided it is shown
  /// when [VideoPlayerValue.hasError] is true; otherwise the defaults (a black
  /// frame while loading and a centered error box) are used.
  const VideoPlayer(
    this.controller, {
    super.key,
    this.loadingBuilder,
    this.errorBuilder,
  });

  /// The [VideoPlayerController] responsible for the video being rendered in
  /// this widget.
  final VideoPlayerController controller;

  /// Widget shown while the controller is loading (not yet initialized) or
  /// buffering, with the buffered [progress] (`0.0`–`1.0`). Defaults to a
  /// black container.
  /// Fades out over 250 milliseconds when the video becomes ready, keeping
  /// the native video view mounted underneath.
  final VideoPlayerLoadingBuilder? loadingBuilder;

  /// Widget shown when the controller reports an error
  /// ([VideoPlayerValue.hasError]), in place of the video view, with the
  /// reported [error] description. Defaults to a centered error box.
  final VideoPlayerErrorBuilder? errorBuilder;

  @override
  State<VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayer> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(VideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, child) => _buildContent(context, value),
    );
  }

  Widget _buildContent(BuildContext context, VideoPlayerValue value) {
    final int playerId = widget.controller.playerId;

    if (value.hasError) {
      final VideoPlayerErrorBuilder? errorBuilder = widget.errorBuilder;
      return errorBuilder != null
          ? errorBuilder(context, value.errorDescription)
          : const Center(
              child: Icon(Icons.error_outline, size: 36),
            );
    }

    final bool isLoading = !value.isInitialized || value.isBuffering;
    final Widget video = playerId == VideoPlayerController.kUninitializedPlayerId
        ? Container()
        : _VideoPlayerWithRotation(
            rotation: value.rotationCorrection,
            child: _videoPlayerPlatform.buildViewWithOptions(
              platform_interface.VideoViewOptions(playerId: playerId),
            ),
          );
    if (widget.loadingBuilder == null) {
      return video;
    }
    // Keep the native iOS view (and its AVPlayerLayer) mounted while loading.
    // Removing it during buffering would also invalidate the layer used by PiP.
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        video,
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !isLoading,
            child: _VideoLoadingOverlay(
              isLoading: isLoading,
              progress: _bufferedProgress(value),
              builder: widget.loadingBuilder!,
            ),
          ),
        ),
      ],
    );
  }

  /// Buffered fraction of the video (`0.0`–`1.0`); `0.0` while the duration is
  /// not yet known and no buffered range is measurable.
  double _bufferedProgress(VideoPlayerValue value) {
    final Duration duration = value.duration;
    if (duration <= Duration.zero || value.buffered.isEmpty) {
      return 0.0;
    }
    final int bufferedMs = value.buffered.last.end.inMilliseconds;
    final int totalMs = duration.inMilliseconds;
    if (totalMs <= 0) {
      return 0.0;
    }
    return (bufferedMs / totalMs).clamp(0.0, 1.0).toDouble();
  }
}

/// One persistent loading layer, including when buffering reverses mid-fade.
class _VideoLoadingOverlay extends StatefulWidget {
  const _VideoLoadingOverlay({
    required this.isLoading,
    required this.progress,
    required this.builder,
  });

  final bool isLoading;
  final double progress;
  final VideoPlayerLoadingBuilder builder;

  @override
  State<_VideoLoadingOverlay> createState() => _VideoLoadingOverlayState();
}

class _VideoLoadingOverlayState extends State<_VideoLoadingOverlay> {
  late bool _showLoading;

  @override
  void initState() {
    super.initState();
    _showLoading = widget.isLoading;
  }

  @override
  void didUpdateWidget(_VideoLoadingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading) _showLoading = true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: widget.isLoading ? 1 : 0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      onEnd: () {
        if (!widget.isLoading && _showLoading) {
          setState(() => _showLoading = false);
        }
      },
      child: _showLoading
          ? SizedBox.expand(
              child: ColoredBox(
                color: Colors.black,
                child: widget.builder(context, widget.progress),
              ),
            )
          : const SizedBox.expand(),
    );
  }
}

class _VideoPlayerWithRotation extends StatelessWidget {
  const _VideoPlayerWithRotation({required this.rotation, required this.child})
    : assert(rotation % 90 == 0, 'Rotation must be a multiple of 90');

  final int rotation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (rotation == 0) {
      return child;
    }
    return RotatedBox(quarterTurns: rotation ~/ 90, child: child);
  }
}

/// Used to configure the [VideoProgressIndicator] widget's colors for how it
/// describes the video's status.
///
/// The widget uses default colors that are customizable through this class.
class VideoProgressColors {
  /// Any property can be set to any color. They each have defaults.
  ///
  /// [playedColor] defaults to red at 70% opacity. This fills up a portion of
  /// the [VideoProgressIndicator] to represent how much of the video has played
  /// so far.
  ///
  /// [bufferedColor] defaults to blue at 20% opacity. This fills up a portion
  /// of [VideoProgressIndicator] to represent how much of the video has
  /// buffered so far.
  ///
  /// [backgroundColor] defaults to gray at 50% opacity. This is the background
  /// color behind both [playedColor] and [bufferedColor] to denote the total
  /// size of the video compared to either of those values.
  const VideoProgressColors({
    this.playedColor = const Color.fromRGBO(255, 0, 0, 0.7),
    this.bufferedColor = const Color.fromRGBO(50, 50, 200, 0.2),
    this.backgroundColor = const Color.fromRGBO(200, 200, 200, 0.5),
  });

  /// [playedColor] defaults to red at 70% opacity. This fills up a portion of
  /// the [VideoProgressIndicator] to represent how much of the video has played
  /// so far.
  final Color playedColor;

  /// [bufferedColor] defaults to blue at 20% opacity. This fills up a portion
  /// of [VideoProgressIndicator] to represent how much of the video has
  /// buffered so far.
  final Color bufferedColor;

  /// [backgroundColor] defaults to gray at 50% opacity. This is the background
  /// color behind both [playedColor] and [bufferedColor] to denote the total
  /// size of the video compared to either of those values.
  final Color backgroundColor;
}

/// A scrubber to control [VideoPlayerController]s
class VideoScrubber extends StatefulWidget {
  /// Create a [VideoScrubber] handler with the given [child].
  ///
  /// [controller] is the [VideoPlayerController] that will be controlled by
  /// this scrubber.
  const VideoScrubber({super.key, required this.child, required this.controller});

  /// The widget that will be displayed inside the gesture detector.
  final Widget child;

  /// The [VideoPlayerController] that will be controlled by this scrubber.
  final VideoPlayerController controller;

  @override
  State<VideoScrubber> createState() => _VideoScrubberState();
}

class _VideoScrubberState extends State<VideoScrubber> {
  bool _controllerWasPlaying = false;

  VideoPlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    void seekToRelativePosition(Offset globalPosition) {
      final box = context.findRenderObject()! as RenderBox;
      final Offset tapPos = box.globalToLocal(globalPosition);
      final double relative = tapPos.dx / box.size.width;
      final Duration position = controller.value.duration * relative;
      controller.seekTo(position);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      child: widget.child,
      onHorizontalDragStart: (DragStartDetails details) {
        if (!controller.value.isInitialized) {
          return;
        }
        _controllerWasPlaying = controller.value.isPlaying;
        if (_controllerWasPlaying) {
          controller.pause();
        }
      },
      onHorizontalDragUpdate: (DragUpdateDetails details) {
        if (!controller.value.isInitialized) {
          return;
        }
        seekToRelativePosition(details.globalPosition);
      },
      onHorizontalDragEnd: (DragEndDetails details) {
        if (_controllerWasPlaying && controller.value.position != controller.value.duration) {
          controller.play();
        }
      },
      onTapDown: (TapDownDetails details) {
        if (!controller.value.isInitialized) {
          return;
        }
        seekToRelativePosition(details.globalPosition);
      },
    );
  }
}

/// Displays the play/buffering status of the video controlled by [controller].
///
/// If [allowScrubbing] is true, this widget will detect taps and drags and
/// seek the video accordingly.
///
/// [padding] allows to specify some extra padding around the progress indicator
/// that will also detect the gestures.
class VideoProgressIndicator extends StatefulWidget {
  /// Construct an instance that displays the play/buffering status of the video
  /// controlled by [controller].
  ///
  /// Defaults will be used for everything except [controller] if they're not
  /// provided. [allowScrubbing] defaults to false, and [padding] will default
  /// to `top: 5.0`.
  const VideoProgressIndicator(
    this.controller, {
    super.key,
    this.colors = const VideoProgressColors(),
    required this.allowScrubbing,
    this.padding = const EdgeInsets.only(top: 5.0),
  });

  /// The [VideoPlayerController] that actually associates a video with this
  /// widget.
  final VideoPlayerController controller;

  /// The default colors used throughout the indicator.
  ///
  /// See [VideoProgressColors] for default values.
  final VideoProgressColors colors;

  /// When true, the widget will detect touch input and try to seek the video
  /// accordingly. The widget ignores such input when false.
  ///
  /// Defaults to false.
  final bool allowScrubbing;

  /// This allows for visual padding around the progress indicator that can
  /// still detect gestures via [allowScrubbing].
  ///
  /// Defaults to `top: 5.0`.
  final EdgeInsets padding;

  @override
  State<VideoProgressIndicator> createState() => _VideoProgressIndicatorState();
}

class _VideoProgressIndicatorState extends State<VideoProgressIndicator> {
  VideoPlayerController get controller => widget.controller;

  VideoProgressColors get colors => widget.colors;

  void _didUpdateControllerValue() {
    setState(() {
      // The build method reads from controller.value.
    });
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(_didUpdateControllerValue);
  }

  @override
  void dispose() {
    controller.removeListener(_didUpdateControllerValue);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget progressIndicator;
    if (controller.value.isInitialized) {
      final int duration = controller.value.duration.inMilliseconds;
      final int position = controller.value.position.inMilliseconds;

      final double maxBuffering = duration == 0.0
          ? 0.0
          : controller.value.buffered
                    .map((platform_interface.DurationRange range) => range.end.inMilliseconds)
                    .fold(0, math.max) /
                duration;
      progressIndicator = Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          LinearProgressIndicator(
            value: maxBuffering,
            valueColor: AlwaysStoppedAnimation<Color>(colors.bufferedColor),
            backgroundColor: colors.backgroundColor,
          ),
          LinearProgressIndicator(
            value: duration == 0.0 ? 0.0 : position / duration,
            valueColor: AlwaysStoppedAnimation<Color>(colors.playedColor),
            backgroundColor: Colors.transparent,
          ),
        ],
      );
    } else {
      progressIndicator = LinearProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(colors.playedColor),
        backgroundColor: colors.backgroundColor,
      );
    }
    final Widget paddedProgressIndicator = Padding(
      padding: widget.padding,
      child: progressIndicator,
    );
    if (widget.allowScrubbing) {
      return VideoScrubber(controller: controller, child: paddedProgressIndicator);
    } else {
      return paddedProgressIndicator;
    }
  }
}

/// Widget for displaying closed captions on top of a video.
///
/// If [text] is null, this widget will not display anything.
///
/// If [textStyle] is supplied, it will be used to style the text in the closed
/// caption.
///
/// Note: in order to have closed captions, you need to specify a
/// [VideoPlayerController.closedCaptionFile].
///
/// Usage:
///
/// ```dart
/// Stack(children: <Widget>[
///   VideoPlayer(_controller),
///   ClosedCaption(text: _controller.value.caption.text),
/// ]),
/// ```
class ClosedCaption extends StatelessWidget {
  /// Creates a a new closed caption, designed to be used with
  /// [VideoPlayerValue.caption].
  ///
  /// If [text] is null or empty, nothing will be displayed.
  const ClosedCaption({super.key, this.text, this.textStyle});

  /// The text that will be shown in the closed caption, or null if no caption
  /// should be shown.
  /// If the text is empty the caption will not be shown.
  final String? text;

  /// Specifies how the text in the closed caption should look.
  ///
  /// If null, defaults to [DefaultTextStyle.of(context).style] with size 36
  /// font colored white.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final String? text = this.text;
    if (text == null || text.isEmpty) {
      return const SizedBox.shrink();
    }

    final TextStyle effectiveTextStyle =
        textStyle ??
        DefaultTextStyle.of(context).style.copyWith(fontSize: 36.0, color: Colors.white);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 24.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB8000000),
            borderRadius: BorderRadius.circular(2.0),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: Text(text, style: effectiveTextStyle),
          ),
        ),
      ),
    );
  }
}

/// Represents a video track in a video with its metadata.
///
/// For HLS/DASH adaptive streams, each [VideoTrack] represents a different
/// quality level (e.g., 1080p, 720p, 480p). For non-adaptive videos, platform
/// implementations may return a single track or no tracks, depending on the
/// metadata that is available.
@immutable
class VideoTrack {
  /// Constructs an instance of [VideoTrack].
  const VideoTrack({
    required this.id,
    required this.isSelected,
    this.label,
    this.bitrate,
    this.width,
    this.height,
    this.frameRate,
    this.codec,
  });

  /// Creates a [VideoTrack] from a platform interface [VideoTrack].
  factory VideoTrack._fromPlatform(platform_interface.VideoTrack track) {
    return VideoTrack(
      id: track.id,
      isSelected: track.isSelected,
      label: track.label,
      bitrate: track.bitrate,
      width: track.width,
      height: track.height,
      frameRate: track.frameRate,
      codec: track.codec,
    );
  }

  /// Unique identifier for the video track.
  ///
  /// The format is platform-specific:
  /// - Android: `"{groupIndex}_{trackIndex}"` (e.g., `"0_2"`)
  /// - iOS: `"variant_{bitrate}"` for HLS adaptive streams
  final String id;

  /// Whether this track is currently selected.
  final bool isSelected;

  /// Human-readable label for the track (e.g., "1080p", "720p").
  ///
  /// May be null if not available from the platform.
  final String? label;

  /// Bitrate of the video track in bits per second.
  ///
  /// May be null if not available from the platform.
  final int? bitrate;

  /// Video width in pixels.
  ///
  /// May be null if not available from the platform.
  final int? width;

  /// Video height in pixels.
  ///
  /// May be null if not available from the platform.
  final int? height;

  /// Frame rate in frames per second.
  ///
  /// May be null if not available from the platform.
  final double? frameRate;

  /// Video codec used (e.g., "avc1", "hevc", "vp9").
  ///
  /// May be null if not available from the platform.
  final String? codec;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is VideoTrack &&
            runtimeType == other.runtimeType &&
            id == other.id &&
            isSelected == other.isSelected &&
            label == other.label &&
            bitrate == other.bitrate &&
            width == other.width &&
            height == other.height &&
            frameRate == other.frameRate &&
            codec == other.codec;
  }

  @override
  int get hashCode => Object.hash(id, isSelected, label, bitrate, width, height, frameRate, codec);

  @override
  String toString() =>
      'VideoTrack('
      'id: $id, '
      'isSelected: $isSelected, '
      'label: $label, '
      'bitrate: $bitrate, '
      'width: $width, '
      'height: $height, '
      'frameRate: $frameRate, '
      'codec: $codec)';
}
