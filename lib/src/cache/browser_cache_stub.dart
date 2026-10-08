import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Browser-only counterpart to the native filesystem video cache.
class WebVideoPlayerCache {
  WebVideoPlayerCache({
    this.namespace = 'video_player_custom_cache',
    this.maxCacheSizeBytes = 1 << 30,
  });

  static WebVideoPlayerCache instance = WebVideoPlayerCache();
  final String namespace;
  final int maxCacheSizeBytes;
  Future<bool> get supported async => false;

  Future<bool> have(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async => false;

  Future<String?> sourceFor(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async => null;

  Future<void> prefetch(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) async => throw UnsupportedError('WebVideoPlayerCache requires a browser');

  Future<void> warm(
    String uri, {
    String? cacheKey,
    Map<String, String>? headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) => prefetch(
    uri,
    cacheKey: cacheKey,
    headers: headers,
    formatHint: formatHint,
    isLive: isLive,
  );

  Future<void> clear() async {}
  Future<void> remove(
    String uri, {
    String? cacheKey,
    VideoFormat? formatHint,
  }) async {}
  Future<String> fetchSource(
    String uri, {
    required Map<String, String> headers,
    VideoFormat? formatHint,
    bool isLive = false,
  }) async => throw UnsupportedError('Browser fetch requires a browser');
  Future<int> totalSizeBytes() async => 0;
  void releaseSource(String uri) {}
  void dispose() {}
}
