import 'dart:async';

import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'web_video_player_cache.dart';

Future<String?> resolveBrowserCachedSource(
  String uri, {
  String? cacheKey,
  Map<String, String>? headers,
  VideoFormat? formatHint,
  bool isLive = false,
}) async {
  if (cacheKey == null || isLive) {
    return null;
  }
  final WebVideoPlayerCache cache = WebVideoPlayerCache.instance;
  try {
    final String? cached = await cache.sourceFor(
      uri,
      cacheKey: cacheKey,
      formatHint: formatHint,
    );
    if (cached != null) {
      return cached;
    }
    if (headers?.isNotEmpty ?? false) {
      await cache.prefetch(
        uri,
        cacheKey: cacheKey,
        headers: headers,
        formatHint: formatHint,
      );
      return await cache.sourceFor(
        uri,
        cacheKey: cacheKey,
        formatHint: formatHint,
      );
    }
    unawaited(
      cache
          .prefetch(
            uri,
            cacheKey: cacheKey,
            headers: headers,
            formatHint: formatHint,
          )
          .catchError((Object _) {}),
    );
  } catch (_) {
    // Storage, quota, CORS and unsupported formats must not stop streaming.
  }
  return null;
}

void releaseBrowserCachedSource(String uri) {
  releaseBrowserCacheLease(uri);
}

Future<String> fetchBrowserVideoSource(
  String uri, {
  required Map<String, String> headers,
  VideoFormat? formatHint,
  bool isLive = false,
}) => WebVideoPlayerCache.instance.fetchSource(
  uri,
  headers: headers,
  formatHint: formatHint,
  isLive: isLive,
);
