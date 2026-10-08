import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Position changes initiated by native controls rather than the Dart timer.
class PlaybackPositionEvent extends VideoEvent {
  PlaybackPositionEvent(this.position)
    : super(eventType: VideoEventType.unknown);

  final Duration position;
}
