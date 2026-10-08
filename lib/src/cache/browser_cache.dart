/// Persistent media cache for browser playback.
library;

export 'browser_cache_stub.dart'
    if (dart.library.js_interop) 'web_video_player_cache.dart';
