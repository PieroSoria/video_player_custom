import 'package:video_player_platform_interface/video_player_platform_interface.dart';

Future<String?> resolveBrowserCachedSource(
  String uri, {
  String? cacheKey,
  Map<String, String>? headers,
  VideoFormat? formatHint,
  bool isLive = false,
}) async => null;

void releaseBrowserCachedSource(String uri) {}

Future<String> fetchBrowserVideoSource(
  String uri, {
  required Map<String, String> headers,
  VideoFormat? formatHint,
  bool isLive = false,
}) async => throw UnsupportedError('Browser fetch requires a browser');
