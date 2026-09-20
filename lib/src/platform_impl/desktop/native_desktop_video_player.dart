// A desktop-only [VideoPlayerPlatform] that talks to the bundled native
// backends over a shared method-channel contract:
//
//   * Windows: Windows Media Foundation (decode A/V) + WASAPI (audio) +
//     Flutter pixel-buffer texture (video).
//   * Linux: GStreamer (decode A/V) + Flutter pixel-buffer texture.
//
// The native side is one of the plugin's own backends, so no third-party
// playback package (e.g. media_kit) is involved.
//
// Method channel: `video_player_custom/desktop`
// Event channels: `video_player_custom/desktop/events/<playerId>`

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The name of the method channel shared by the Windows and Linux backends.
const String kDesktopMethodChannel = 'video_player_custom/desktop';

/// A [VideoPlayerPlatform] for Windows and Linux that renders frames through
/// a [Texture] backed by the native video backend.
class NativeDesktopVideoPlayer extends VideoPlayerPlatform {
  /// Creates a new native desktop player.
  NativeDesktopVideoPlayer({
    @visibleForTesting MethodChannel? methodChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(kDesktopMethodChannel);

  final MethodChannel _methodChannel;

  /// All players, keyed by player ID (which equals the texture ID).
  final Map<int, _DesktopPlayer> _players = <int, _DesktopPlayer>{};

  /// Registers this class as the default instance of [VideoPlayerPlatform].
  static void registerWith() {
    VideoPlayerPlatform.instance = NativeDesktopVideoPlayer();
  }

  @override
  Future<void> init() async {
    // Drop all active players (e.g. after a full restart).
    final List<int> ids = _players.keys.toList();
    for (final int id in ids) {
      await dispose(id);
    }
  }

  @override
  Future<void> dispose(int playerId) async {
    final _DesktopPlayer? player = _players.remove(playerId);
    if (player == null) {
      return;
    }
    await player.dispose();
    await _methodChannel.invokeMethod<void>('dispose', {'playerId': playerId});
  }

  @override
  Future<int?> create(DataSource dataSource) {
    return createWithOptions(
      VideoCreationOptions(
        dataSource: dataSource,
        viewType: VideoViewType.textureView,
      ),
    );
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final DataSource dataSource = options.dataSource;
    final String uri;
    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        final String? asset = dataSource.asset;
        if (asset == null) {
          throw ArgumentError('"asset" must be non-null for an asset data source');
        }
        uri = await _resolveAsset(asset, dataSource.package);
      case DataSourceType.network:
      case DataSourceType.file:
      case DataSourceType.contentUri:
        uri = dataSource.uri!;
    }

    final Map<String, dynamic> arguments = <String, dynamic>{
      'uri': uri,
      'httpHeaders': dataSource.httpHeaders,
      'viewType': options.viewType == VideoViewType.platformView
          ? 'platformView'
          : 'textureView',
    };
    final Map<String, dynamic>? result = await _methodChannel.invokeMapMethod<String, dynamic>(
      'create',
      arguments,
    );
    if (result == null) {
      throw PlatformException(code: 'video_player', message: 'create failed');
    }
    final int playerId = result['playerId']! as int;
    final int textureId = result['textureId']! as int;
    final _DesktopPlayer player = _DesktopPlayer(
      playerId,
      textureId,
      _methodChannel,
      EventChannel('$kDesktopMethodChannel/events/$playerId'),
    );
    _players[playerId] = player;
    return playerId;
  }

  /// Returns the on-disk path for a bundled asset.
  Future<String> _resolveAsset(String asset, String? package) async {
    final String key = package == null ? asset : 'packages/$package/$asset';
    // Desktop builds keep bundled assets next to the executable under
    // `data/flutter_assets`, so resolve the file directly.
    final String executableDir = File(Platform.resolvedExecutable).parent.path;
    final File assetFile = File('$executableDir${Platform.pathSeparator}data'
        '${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}$key');
    if (assetFile.existsSync()) {
      return assetFile.path;
    }
    // Fall back to reading through the asset bundle into a temporary file.
    final ByteData data = await rootBundle.load(key);
    final File temporaryFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'video_player_custom_${asset.hashCode}.tmp',
    );
    await temporaryFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return temporaryFile.path;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) {
    return _methodChannel.invokeMethod<void>('setLooping', {'playerId': playerId, 'looping': looping});
  }

  @override
  Future<void> play(int playerId) {
    return _methodChannel.invokeMethod<void>('play', {'playerId': playerId});
  }

  @override
  Future<void> pause(int playerId) {
    return _methodChannel.invokeMethod<void>('pause', {'playerId': playerId});
  }

  @override
  Future<void> setVolume(int playerId, double volume) {
    return _methodChannel.invokeMethod<void>('setVolume', {'playerId': playerId, 'volume': volume});
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) {
    return _methodChannel.invokeMethod<void>('setPlaybackSpeed', {'playerId': playerId, 'speed': speed});
  }

  @override
  Future<void> seekTo(int playerId, Duration position) {
    return _methodChannel.invokeMethod<void>('seekTo', {'playerId': playerId, 'positionMs': position.inMilliseconds});
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    final int positionMs = await _methodChannel.invokeMethod<int>('getPosition', {'playerId': playerId}) ?? 0;
    return Duration(milliseconds: positionMs);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final _DesktopPlayer? player = _players[playerId];
    if (player == null) {
      throw StateError(
        'VideoPlayer for playerId $playerId is not found, check if it is disposed.',
      );
    }
    return player.videoEvents;
  }

  @override
  Widget buildView(int playerId) {
    return buildViewWithOptions(VideoViewOptions(playerId: playerId));
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    final _DesktopPlayer? player = _players[options.playerId];
    if (player == null) {
      throw StateError(
        'VideoPlayer for playerId ${options.playerId} is not found, check if it is disposed.',
      );
    }
    // Desktop platform views are not supported; always render through a texture.
    return Texture(textureId: player.textureId);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future<void>.value();

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) => Future<void>.value();
}

/// A single player instance bound to a per-player event channel.
class _DesktopPlayer {
  _DesktopPlayer(
    this.playerId,
    this.textureId,
    this._methodChannel,
    this._eventChannel,
  );

  final int playerId;

  /// The registered native texture ID used by [Texture].
  final int textureId;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final StreamController<VideoEvent> _eventStreamController =
      StreamController<VideoEvent>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  Timer? _bufferPollingTimer;
  int _lastBufferPosition = -1;
  bool _isDisposed = false;

  /// Returns the stream of [VideoEvent]s emitted by the native player.
  Stream<VideoEvent> get videoEvents {
    _eventSubscription ??= _eventChannel.receiveBroadcastStream().listen(
      _onStreamEvent,
      onError: (Object e) {
        _eventStreamController.addError(e);
      },
    );
    return _eventStreamController.stream;
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _bufferPollingTimer?.cancel();
    _bufferPollingTimer = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _eventStreamController.close();
  }

  void _onStreamEvent(dynamic event) {
    final Map<dynamic, dynamic> map = event as Map<dynamic, dynamic>;
    // The strings here must match the ones emitted by the native backends.
    if (map['event'] == 'error') {
      _eventStreamController.addError(
        PlatformException(code: 'video_error', message: map['message'] as String?),
      );
      return;
    }
    if (map['event'] == 'initialized') {
      // No native buffer-position event exists; poll it like the Android
      // backend does. The range reported is the file if fully known.
      _bufferPollingTimer ??= Timer.periodic(const Duration(seconds: 1), (Timer timer) async {
        final int? position = await _methodChannel.invokeMethod<int>(
          'getBufferedPosition',
          {'playerId': playerId},
        );
        if (_isDisposed || position == null) {
          return;
        }
        if (position != _lastBufferPosition) {
          _lastBufferPosition = position;
          _eventStreamController.add(
            VideoEvent(
              eventType: VideoEventType.bufferingUpdate,
              buffered: <DurationRange>[
                DurationRange(Duration.zero, Duration(milliseconds: position)),
              ],
            ),
          );
        }
      });
    }
    _eventStreamController.add(switch (map['event']) {
      'initialized' => VideoEvent(
        eventType: VideoEventType.initialized,
        duration: Duration(milliseconds: map['duration'] as int),
        size: Size(
          (map['width'] as num?)?.toDouble() ?? 0.0,
          (map['height'] as num?)?.toDouble() ?? 0.0,
        ),
      ),
      'completed' => VideoEvent(eventType: VideoEventType.completed),
      'bufferingUpdate' => VideoEvent(
        eventType: VideoEventType.bufferingUpdate,
        buffered: (map['values'] as List<dynamic>)
            .map<DurationRange>(_toDurationRange)
            .toList(),
      ),
      'bufferingStart' => VideoEvent(eventType: VideoEventType.bufferingStart),
      'bufferingEnd' => VideoEvent(eventType: VideoEventType.bufferingEnd),
      'isPlayingStateUpdate' => VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: map['isPlaying'] as bool,
      ),
      _ => VideoEvent(eventType: VideoEventType.unknown),
    });
  }

  DurationRange _toDurationRange(dynamic value) {
    final List<dynamic> pair = value as List<dynamic>;
    final int startMilliseconds = pair[0] as int;
    final int durationMilliseconds = pair[1] as int;
    return DurationRange(
      Duration(milliseconds: startMilliseconds),
      Duration(milliseconds: startMilliseconds + durationMilliseconds),
    );
  }
}