import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;
import 'package:web/web.dart' as web;

/// Whether the browser exposes native audio track enumeration and selection.
/// Actual tracks depend on the loaded media and may be absent until metadata
/// becomes available.
bool get isAudioTrackSupportAvailable =>
    supportsAudioTracks(web.HTMLVideoElement());

/// Whether the browser exposes native video track enumeration and selection.
/// This does not indicate support for adaptive quality or a quality ladder.
bool get isVideoTrackSupportAvailable =>
    supportsVideoTracks(web.HTMLVideoElement());

bool supportsAudioTracks(web.HTMLVideoElement video) =>
    _audioTracks(video) != null;

bool supportsVideoTracks(web.HTMLVideoElement video) =>
    _videoTracks(video) != null;

web.AudioTrackList? _audioTracks(web.HTMLVideoElement video) {
  try {
    if (!video.hasProperty('audioTracks'.toJS).toDart ||
        video.getProperty<JSAny?>('audioTracks'.toJS) == null) {
      return null;
    }
    return video.audioTracks;
  } catch (_) {
    return null;
  }
}

web.VideoTrackList? _videoTracks(web.HTMLVideoElement video) {
  try {
    if (!video.hasProperty('videoTracks'.toJS).toDart ||
        video.getProperty<JSAny?>('videoTracks'.toJS) == null) {
      return null;
    }
    return video.videoTracks;
  } catch (_) {
    return null;
  }
}

/// Returns the browser's audio tracks, without inventing unavailable metadata.
List<platform.VideoAudioTrack> getAudioTracks(web.HTMLVideoElement video) {
  final tracks = _audioTracks(video);
  if (tracks == null) return const [];
  final snapshot = [for (var i = 0; i < tracks.length; i++) tracks[i]];
  final ids = _trackIds(snapshot.map((track) => track.id).toList());
  return [
    for (var i = 0; i < snapshot.length; i++)
      platform.VideoAudioTrack(
        id: ids[i],
        label: _nullableText(snapshot[i].label),
        language: _nullableText(snapshot[i].language),
        isSelected: snapshot[i].enabled,
      ),
  ];
}

/// Enables one native audio track and disables the other tracks. Looking up the
/// requested ID first leaves the current selection unchanged for an invalid ID.
void selectAudioTrack(web.HTMLVideoElement video, String id) {
  final tracks = _audioTracks(video);
  if (tracks == null) {
    throw UnsupportedError(
      'This browser does not expose HTMLMediaElement.audioTracks selection.',
    );
  }
  final snapshot = [for (var i = 0; i < tracks.length; i++) tracks[i]];
  final ids = _trackIds(snapshot.map((track) => track.id).toList());
  final selectedIndex = ids.indexOf(id);
  if (selectedIndex < 0) {
    throw ArgumentError.value(id, 'id', 'No audio track with this ID exists.');
  }
  // Enable the target before disabling the old track to avoid a temporary
  // selection with no audible track.
  snapshot[selectedIndex].enabled = true;
  for (var i = 0; i < snapshot.length; i++) {
    if (i != selectedIndex) snapshot[i].enabled = false;
  }
}

/// Returns native video tracks. The HTML API does not expose per-track bitrate,
/// dimensions, frame rate or codec, so those fields remain null.
List<platform.VideoTrack> getVideoTracks(web.HTMLVideoElement video) {
  final tracks = _videoTracks(video);
  if (tracks == null) return const [];
  final snapshot = [for (var i = 0; i < tracks.length; i++) tracks[i]];
  final ids = _trackIds(snapshot.map((track) => track.id).toList());
  return [
    for (var i = 0; i < snapshot.length; i++)
      platform.VideoTrack(
        id: ids[i],
        isSelected: snapshot[i].selected,
        label: _nullableText(snapshot[i].label),
      ),
  ];
}

/// Selects an explicit native video track. Setting its `selected` property also
/// deselects the previous track according to the HTML VideoTrack contract.
///
/// Null means automatic/adaptive quality in the package API. HTML videoTracks
/// has no corresponding operation, so that request cannot be fulfilled here.
void selectVideoTrack(web.HTMLVideoElement video, platform.VideoTrack? track) {
  if (track == null) {
    throw UnsupportedError(
      'The native HTML videoTracks API does not expose automatic quality '
      'selection. Select an explicit track returned by getVideoTracks().',
    );
  }
  final tracks = _videoTracks(video);
  if (tracks == null) {
    throw UnsupportedError(
      'This browser does not expose HTMLMediaElement.videoTracks selection.',
    );
  }
  final snapshot = [for (var i = 0; i < tracks.length; i++) tracks[i]];
  final ids = _trackIds(snapshot.map((track) => track.id).toList());
  final selectedIndex = ids.indexOf(track.id);
  if (selectedIndex < 0) {
    throw ArgumentError.value(
      track.id,
      'track.id',
      'No video track with this ID exists.',
    );
  }
  snapshot[selectedIndex].selected = true;
}

String? _nullableText(String text) => text.isEmpty ? null : text;

/// Preserve unique native IDs. Empty or duplicate IDs receive an index-based
/// fallback that cannot collide with any ID provided by the browser.
List<String> _trackIds(List<String> nativeIds) {
  final counts = <String, int>{};
  for (final id in nativeIds) {
    counts[id] = (counts[id] ?? 0) + 1;
  }
  final used = nativeIds.where((id) => id.isNotEmpty).toSet();
  return [
    for (var i = 0; i < nativeIds.length; i++)
      if (nativeIds[i].isNotEmpty && counts[nativeIds[i]] == 1)
        nativeIds[i]
      else
        _indexId(i, used),
  ];
}

String _indexId(int index, Set<String> used) {
  var id = 'web-track-$index';
  while (used.contains(id)) {
    id = '_$id';
  }
  used.add(id);
  return id;
}
