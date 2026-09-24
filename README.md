<?code-excerpt path-base="example/lib"?>

# Video Player plugin for Flutter

[![pub package](https://img.shields.io/pub/v/video_player.svg)](https://pub.dev/packages/video_player)

A Flutter video player for Android, iOS, macOS, Windows, Linux and web.

| Platform | Playback backend | Picture-in-Picture |
|----------|------------------|--------------------|
| Android SDK 24+ | Vendored Media3 | Android 8+ with device support |
| iOS 15+ | Shared AVFoundation | Supported devices, using `VideoViewType.platformView` |
| macOS 12+ | Shared AVFoundation | Not implemented |
| Windows | media_kit | Compact, always-on-top application window |
| Linux | media_kit / libmpv | Not implemented |
| Web | HTML video | Not implemented |

Flutter registers the correct backend automatically. Import
`package:video_player_custom/video_player_custom.dart` for playback and PiP.
Unsupported PiP operations return `false`; `reset()` completes without error.

### Code organization

- `lib/video_player.dart`: shared controller and widgets.
- `lib/src/platform_impl/`: Android, AVFoundation, web and desktop adapters.
- `lib/src/pip/`: public PiP API and method-channel implementation.
- `android/`: native playback and PiP, registered together.
- `darwin/video_player_custom/`: a shared Swift package for iOS and macOS;
  iOS-only PiP sources are conditionally compiled.
- Windows and Linux use the native playback plugins supplied by `media_kit`.
  `windows/` adds native window management for Windows PiP. The platform folders
  inside `example/` are the application runners and are required to build it.

### Windows and Linux

The [media_kit desktop backend](https://pub.dev/packages/video_player_media_kit)
and its native dependency packages are included in this
package. Linux additionally requires libmpv and the GTK/OpenGL development
libraries. On Ubuntu, install `libmpv-dev libgtk-3-dev libepoxy-dev` along with
Flutter's Linux build prerequisites. Windows requires Flutter's Visual Studio
C++ desktop toolchain. Build and test each desktop app on its own operating
system. Advanced track selection and view options depend on backend support.

### Windows Picture-in-Picture

Use `await controller.enterPipMode(width: 360, height: 240)` after initialization
while a `VideoPlayer(controller)` is mounted beneath a Navigator/Overlay (as in
`MaterialApp`). The plugin turns the existing application window into a compact,
movable, resizable, always-on-top player. It displays only the video and
play/pause and restore controls. This is a compact mode for the application
window, not a separate second window; the original screen stays mounted.
Playback uses the same media_kit player, preserving its position and audio.

Call `controller.exitPipMode()` or use the restore control to restore the original
window placement, maximized state and always-on-top setting. The native close
and maximize buttons also restore the application while in PiP. Removing the
video widget, disposing its controller, or calling `VideoPlayerPip.reset()` exits
PiP. Only one player may use PiP at a time. The default texture view works on
Windows; `VideoViewType.platformView` is not required. Dimensions are outer-window
pixels, clamped to the monitor work area with a minimum size of 160 by 120.

The example player's PiP button exercises this flow. Run the Windows integration
checks from `example/`:

```sh
flutter test integration_test/windows_video_player_test.dart -d windows
flutter build windows --release
```

Apple builds use Swift Package Manager for this plugin and CocoaPods for
dependencies that have not yet adopted Swift Package Manager.
The vendored Apple modules use the `video_player_custom_avfoundation` prefix,
Objective-C symbols use `VPC`, and platform channels have package-specific
names to avoid collisions with the official `video_player_avfoundation` package.
Keep these namespaces when updating the vendored code or regenerating Pigeon
messages, including the matching Dart channel names.

![The example app running in iOS](https://github.com/flutter/packages/blob/main/packages/video_player/video_player/doc/demo_ipod.gif?raw=true)

## Setup

### iOS

If you need to access videos using `http` (rather than `https`) URLs, you will need to add
the appropriate `NSAppTransportSecurity` permissions to your app's _Info.plist_ file, located
in `<project root>/ios/Runner/Info.plist`. See
[Apple's documentation](https://developer.apple.com/documentation/bundleresources/information_property_list/nsapptransportsecurity)
to determine the right combination of entries for your use case and supported iOS versions.

### Android

If you are using network-based videos, ensure that the following permission is present in your
Android Manifest file, located in `<project root>/android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

### macOS

If you are using network-based videos, you will need to [add the
`com.apple.security.network.client`
entitlement](https://flutter.dev/to/macos-entitlements)

### Web

> The Web platform does **not** support `dart:io`, so avoid using the `VideoPlayerController.file` constructor for the plugin. Using the constructor attempts to create a `VideoPlayerController.file` that will throw an `UnimplementedError`.

\* Different web browsers may have different video-playback capabilities (supported formats, autoplay...). Check [package:video_player_web](https://pub.dev/packages/video_player_web) for more web-specific information.

The `VideoPlayerOptions.mixWithOthers` option can't be implemented in web, at least at the moment. If you use this option in web it will be silently ignored.

## Supported Formats

- On iOS and macOS, the backing player is [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer).
  The supported formats vary depending on the version of iOS, [AVURLAsset](https://developer.apple.com/documentation/avfoundation/avurlasset) class
  has [audiovisualTypes](https://developer.apple.com/documentation/avfoundation/avurlasset/1386800-audiovisualtypes?language=objc) that you can query for supported av formats.
- On Android, the backing player is [ExoPlayer](https://google.github.io/ExoPlayer/),
  please refer [here](https://google.github.io/ExoPlayer/supported-formats.html) for list of supported formats.
- On Web, available formats depend on your users' browsers (vendor and version). Check [package:video_player_web](https://pub.dev/packages/video_player_web) for more specific information.

## Example

<?code-excerpt "basic.dart (basic-example)"?>
```dart
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

  @override
  void initState() {
    super.initState();
    _controller =
        VideoPlayerController.networkUrl(
            Uri.parse('https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4'),
          )
          ..initialize().then((_) {
            // Ensure the first frame is shown after the video is initialized, even before the play button has been pressed.
            setState(() {});
          });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Demo',
      home: Scaffold(
        body: Center(
          child: _controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                )
              : Container(),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            setState(() {
              _controller.value.isPlaying ? _controller.pause() : _controller.play();
            });
          },
          child: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

```

## Usage

The following section contains usage information that goes beyond what is included in the
documentation in order to give a more elaborate overview of the API.

This is not complete as of now. You can contribute to this section by [opening a pull request](https://github.com/flutter/packages/pulls).

# Video Player on Flutter (vendado PiP)

This package includes a first-class, platform-native Picture-in-Picture (PiP) API on top of the
complete `video_player` implementation, without requiring any extra package:

```dart
// Enter PiP with the default size.
await controller.enterPipMode();

// Or specify the PiP window size (falls back to the native defaults if omitted).
await controller.enterPipMode(width: 220, height: 124);

// React to PiP lifecycle changes.
controller.onPipModeChanged.listen((PipModeChanged event) {
  debugPrint('isInPip=${event.isInPip} isRestored=${event.isRestored}');
});

// Exit PiP (no-op if not currently in PiP mode).
await controller.exitPipMode();
```

Use `controller.isPipSupported()` before entering PiP. Android's host activity
must declare `android:supportsPictureInPicture="true"`. On iOS, enable the audio
background mode and create the controller with `VideoViewType.platformView` so
PiP can use the visible player's layer. The example includes these settings.

### Loading and error builders

[`VideoPlayer`] can take over the loading (initializing/buffering) and error states with the
[`loadingBuilder`] and [`errorBuilder`] arguments, respectively:

Mount `VideoPlayer(controller, ...)` before initialization finishes. Assign the
controller to your widget as soon as you create it, then call `initialize()` and
`play()`. Do not hide `VideoPlayer` behind an external `isInitialized` condition:
its builders must be mounted to display initialization progress and failures.
Keep the controller mounted on an initialization error so `errorBuilder` can
display it. The widget listens for state changes and fades loading out over
250 milliseconds, without requiring a parent `setState` or value listener.
See `example/lib/basic.dart` for the complete flow.

```dart
VideoPlayer(
  controller,
  loadingBuilder: (context, progress) => Center(
    child: LinearProgressIndicator(value: progress),
  ),
  errorBuilder: (context, error) => Center(
    child: Text(
      error ?? 'Error loading video.',
      textAlign: TextAlign.center,
    ),
  ),
)
```

- **`loadingBuilder: (context, progress)`** — shown while the controller is
  initializing/buffering. `progress` is the buffered fraction (`0.0`–`1.0`),
  `0.0` while the buffered range is not yet measurable (never `null`).
- **`errorBuilder: (context, error)`** — shown in place of the video when
  `controller.value.hasError` is true. `error` is `value.errorDescription`, or
  `null` when no description is available.

When neither is provided, the widget keeps the official `video_player` behaviour (a black frame
while loading and a centered error icon on failure).

### Playback speed

You can set the playback speed on your `_controller` (instance of `VideoPlayerController`) by
calling `_controller.setPlaybackSpeed`. `setPlaybackSpeed` takes a `double` speed value indicating
the rate of playback for your video.
For example, when given a value of `2.0`, your video will play at 2x the regular playback speed
and so on.

To learn about playback speed limitations, see the [`setPlaybackSpeed` method documentation](https://pub.dev/documentation/video_player/latest/video_player/VideoPlayerController/setPlaybackSpeed.html).

Furthermore, see the example app for an example playback speed implementation.

### Disk cache for network videos

When you pass a `cacheKey` to `VideoPlayerController.networkUrl`, the plugin
keeps the downloaded file on disk so later openings are instant and work
offline:

```dart
final controller = VideoPlayerController.networkUrl(
  Uri.parse('https://example.com/video.mp4'),
  cacheKey: 'weekly-highlights',
);
```

- On a **cache hit**, `initialize()` plays the local file directly (no network).
- On a **cache miss**, it streams from the network as usual while the file is
  downloaded in the background for the next time. Downloads are streamed to
  disk in chunks, so device memory is not saturated even for large files.
- **HLS** (`.m3u8`/`.m3u`, or `formatHint: VideoFormat.hls`) is cached whole:
  playlists, segments and AES-128 keys are downloaded and their references
  rewritten to local files, so the next open plays the `file://` master
  playlist without network.
- **DASH** (`.mpd`, or `formatHint: VideoFormat.dash`) and **Smooth
  Streaming** (`Manifest`, or `formatHint: VideoFormat.ss`) are cached whole
  too: the manifest is parsed, every segment/fragment is downloaded and the
  manifest is rewritten to point at local files (the quality ladder is kept).
- **iOS/macOS**: AVFoundation cannot play manifest playlists (`.m3u8`/`.mpd`)
  from a `file://` path, so on those platforms the cached presentation is
  served to the player over an in-process loopback HTTP server
  (`http://127.0.0.1:<port>/...`) — offline playback works the same. Single
  files (MP4, MKV, ...) play directly from disk everywhere. If the backend
  blocks cleartext HTTP, add `NSAllowsLocalNetworking` under
  `NSAppTransportSecurity` in `Info.plist`. For HLS playback, the player is
  configured with a longer forward media buffer than the platform default so
  the playhead does not outrun the video decoder (which otherwise shows as
  audio continuing while the picture freezes); the small initial wait to fill
  that buffer is reported as buffering to the `loadingBuilder`.
- **Live**: pass `isLive: true` and the source is never written to the cache
  (a manifest snapshot goes stale in seconds). Live manifests themselves
  (dynamic DASH, DVR/Smooth Streaming) are also rejected by the downloaders
  and keep streaming live.
- **Web (`kIsWeb`)** never caches: the disk cache is desktop/mobile only.

Point `VideoPlayerCache.instance` to a persistent directory to keep files
across launches, and tune the LRU budget:

```dart
import 'dart:io';
import 'package:video_player_custom/video_player_custom.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  VideoPlayerCache.instance = VideoPlayerCache(
    Directory('${dir.path}/videocache'),
    maxCacheSizeBytes: 1 << 30, // 1 GiB, oldest entries evicted first
  );
  runApp(const MyApp());
}
```

Use the utility API for pre-warming, queries and cleanup:

```dart
await VideoPlayerCache.instance.warm(uri, cacheKey: 'key'); // background download
final file = await VideoPlayerCache.instance.fileFor(uri, cacheKey: 'key');
final cached = await VideoPlayerCache.instance.have(uri, cacheKey: 'key');
await VideoPlayerCache.instance.clear(); // drop every cached entry
```

### Video view type

You can set the video view type of your controller (instance of `VideoPlayerController`) during its creation by passing the `videoViewType` argument.  
If set to `VideoViewType.platformView`, platform views will be used instead of texture view on supported platforms.

The relative performance of the different view types may vary by platform, and on some platforms the use of platform views may have correctness issues in certain circumstances due to limitations of Flutter's platform view system.
