# Browser verification

Run the browser suite from the package root with a locally installed Chrome:

```sh
flutter test --platform chrome test/web_browser_test.dart
```

The suite records a short WebM locally with `Canvas.captureStream` and
`MediaRecorder`. It verifies decoding, play/pause/seek, IndexedDB reads after
reopening the cache, offline playback, headers, eviction, and cancellation of
downloads during removal or clearing. Requests for the offline tests are
stubbed, so they need no media server or Internet connection.

Document PiP controls, native video PiP, Safari presentation mode, browser track
lists, and wake-lock permissions use API mocks. The public controller test also
checks that typed PiP entry/exit/restore callbacks reach the Dart API and that
seeking while paused updates the controller's position. These mocks do not
verify an operating-system floating window or Safari's actual decoder.

## Manual floating-window test

Flutter's ordinary browser test runner embeds tests in an iframe. Document PiP
requires a top-level page and a trusted user click. The standalone fixture uses
the public package API, `material_ui`, and the example's bundled WebM asset:

```sh
cd example
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 52731 -t ../test/support/web_pip_smoke.dart
```

Open `http://127.0.0.1:52731` in a
desktop browser that supports native video PiP and click
**Open Picture in Picture**. Check the following:

1. The original view displays the PiP message while the floating window plays
   the same video without restarting or duplicating playback.
2. The window uses the browser's native controls, even when Document PiP is
   available. Verify play/pause, resizing and any seek controls the browser
   provides; their appearance and available actions are browser-owned.
3. The native window follows the video's aspect ratio without the package's
   custom button overlay or Document PiP title bar. An origin indicator, if
   displayed, is controlled by the browser.
4. Returning to the main page closes PiP and restores the video. Closing PiP
   pauses it. Reopen PiP to check that the session can be reused.

For diagnostics, `window.__vpcSmokeState()` returns initialization, playback,
position, PiP results, typed callbacks, and errors as JSON. It is a fixture-only
hook and is not part of the package API.

For visual checks without a privileged floating window, open the same fixture
with `?preview=1`. The explicitly labelled preview mounts the real video and
Document PiP fallback controls in an ordinary iframe with native video PiP
disabled for that fixture only. It does not emulate or hide the browser's
origin header and does not verify native floating-window support. Optional
`width` and `height` query parameters control its viewport, for example
`?preview=1&width=555&height=384` and `?preview=1&width=240&height=135`.
Click **Show PiP design preview**, then check hover, keyboard focus, and the
timeline at both sizes.

## Environment notes

On this Windows machine, Edge 154 was used for the automated suite with a
temporary launcher that forwards its DevTools endpoint to Flutter. Edge's
startup process detaches before Flutter can read its stderr; setting
`CHROME_EXECUTABLE` directly to `msedge.exe` can therefore fail despite the
browser being running. A normal Chrome installation avoids that launcher
workaround.

Flutter 3.47.6 on this machine also requested CanvasKit from a Windows path
containing backslashes. A temporary `test/canvaskit` junction to the Flutter
SDK's `bin/cache/flutter_web_sdk/canvaskit` directory allowed the test server
to resolve its assets. The junction is local test setup, excluded from Git,
and can be removed after verification; it is not a package dependency.
