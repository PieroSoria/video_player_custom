// Manual top-level browser fixture for privileged PiP testing. Run from example:
// flutter run -d web-server -t ../test/support/web_pip_smoke.dart
// The ordinary browser suite runs inside an iframe where Document PiP is blocked.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:material_ui/material_ui.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final parameters = Uri.base.queryParameters;
  final preview = parameters['preview'] == '1';
  final width = _previewSize(parameters['width'], 480, 180, 1200);
  final height = _previewSize(parameters['height'], 270, 90, 800);
  if (preview) {
    _installDesignPreview(width, height);
  }
  final controller = VideoPlayerController.asset(
    'assets/Butterfly-209.webm',
    videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
  );
  final modes = <Map<String, Object?>>[];
  final errors = <String>[];
  bool? enterResult;
  VideoPlayerPip.instance.onPipModeChanged.listen((event) {
    modes.add({
      'active': event.isInPip,
      'restored': event.isRestored,
      'positionMs': event.position?.inMilliseconds,
      'playerId': event.playerId,
    });
  });
  VideoPlayerPip.instance.onPipError.listen(errors.add);
  await controller.initialize();
  await controller.setVolume(0);
  await controller.play();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    ),
  );

  final enter = web.HTMLButtonElement()
    ..id = 'smoke-enter-pip'
    ..textContent = preview
        ? 'Show PiP design preview'
        : 'Open Picture in Picture'
    ..style.cssText =
        'position:fixed;left:12px;top:${preview ? 54 : 12}px;'
        'z-index:99999;padding:16px;';
  enter.addEventListener(
    'click',
    ((web.Event _) {
      // The privileged request is made inside this trusted click callback.
      unawaited(
        VideoPlayerPip.enterPipMode(
          controller,
          width: preview ? width : 480,
          height: preview ? height : 270,
        ).then((result) => enterResult = result),
      );
    }).toJS,
  );
  web.document.body!.appendChild(enter);
  web.window.setProperty(
    '__vpcSmokeState'.toJS,
    (() => jsonEncode({
      'initialized': controller.value.isInitialized,
      'durationMs': controller.value.duration.inMilliseconds,
      'positionMs': controller.value.position.inMilliseconds,
      'playing': controller.value.isPlaying,
      'enterResult': enterResult,
      'modes': modes,
      'errors': errors,
      'designPreview': preview,
    }).toJS).toJS,
  );
}

int _previewSize(String? value, int fallback, int minimum, int maximum) {
  final parsed = int.tryParse(value ?? '');
  return parsed != null && parsed >= minimum && parsed <= maximum
      ? parsed
      : fallback;
}

// Explicit fixture-only mock. This mounts the real PiP controls and the same
// video in an ordinary iframe; it does not emulate browser chrome or prove
// floating-window support. Production package code never installs this API.
void _installDesignPreview(int width, int height) {
  web.document.title = 'PiP design preview';
  final label = web.HTMLDivElement()
    ..id = 'smoke-preview-label'
    ..textContent =
        'PiP design preview · Visual only · Real PiP retains the browser frame'
    ..style.cssText =
        'position:fixed;left:12px;top:12px;z-index:99999;'
        'padding:8px 12px;background:#fff;color:#222;font:14px Arial,sans-serif;';
  final frame = web.HTMLIFrameElement()
    ..id = 'smoke-pip-preview'
    ..title = 'PiP design preview, visual only'
    ..style.cssText =
        'display:none;position:fixed;left:12px;top:124px;z-index:99998;'
        'width:${width}px;height:${height}px;border:0;';
  web.document.body!
    ..appendChild(label)
    ..appendChild(frame);
  final child = frame.contentWindow!;
  child.setProperty(
    'close'.toJS,
    (() {
      child.dispatchEvent(web.Event('pagehide'));
      frame.style.display = 'none';
    }).toJS,
  );
  final api = JSObject();
  api.setProperty(
    'requestWindow'.toJS,
    ((JSObject _) {
      frame.style.display = 'block';
      return Future<web.Window>.value(child).toJS;
    }).toJS,
  );
  final descriptor = JSObject()
    ..setProperty('value'.toJS, api)
    ..setProperty('configurable'.toJS, true.toJS);
  // This visual fixture previews the Document PiP fallback only. Native video
  // PiP remains the production default and is not represented by the iframe.
  final nativeDescriptor = JSObject()
    ..setProperty('value'.toJS, false.toJS)
    ..setProperty('configurable'.toJS, true.toJS);
  web.window
      .getProperty<JSObject>('Object'.toJS)
      .getProperty<JSFunction>('defineProperty'.toJS)
      .callAsFunction(
        null,
        web.document,
        'pictureInPictureEnabled'.toJS,
        nativeDescriptor,
      );
  web.window
      .getProperty<JSObject>('Object'.toJS)
      .getProperty<JSFunction>('defineProperty'.toJS)
      .callAsFunction(
        null,
        web.window,
        'documentPictureInPicture'.toJS,
        descriptor,
      );
}
