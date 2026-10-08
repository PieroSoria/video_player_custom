import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web/web.dart' as web;

import '../../pip/video_player_custom_pip_platform_interface.dart';

@JS()
extension type _DocumentPictureInPicture(JSObject _) implements JSObject {
  external JSPromise<web.Window> requestWindow(_WindowOptions options);
}

@JS()
extension type _WindowOptions._(JSObject _) implements JSObject {
  external factory _WindowOptions({
    int width,
    int height,
    bool disallowReturnToOpener,
  });
}

@JS()
extension type _SafariVideo(JSObject _) implements JSObject {
  external bool webkitSupportsPresentationMode(String mode);
  external void webkitSetPresentationMode(String mode);
  external String get webkitPresentationMode;
}

enum _PipKind { document, video, safari }

String _browserErrorText(Object error) {
  if (error.isA<web.DOMException>()) {
    final exception = error as web.DOMException;
    return '${exception.name}: ${exception.message}';
  }
  return '$error';
}

/// Browser PiP implementation. Native video PiP uses the browser's own window
/// and controls. Document PiP provides a custom overlay only as a fallback,
/// reusing the existing video, decoder, position and event stream.
class WebVideoPlayerPip extends VideoPlayerPipPlatform {
  WebVideoPlayerPip({
    required web.HTMLVideoElement? Function(int playerId) resolveVideo,
    required web.HTMLElement? Function(int playerId) resolveHost,
    @visibleForTesting web.Window? browsingWindow,
  }) : _resolveVideo = resolveVideo, // ignore: prefer_initializing_formals
       _resolveHost = resolveHost, // ignore: prefer_initializing_formals
       _window = browsingWindow ?? web.window;

  final web.HTMLVideoElement? Function(int) _resolveVideo;
  final web.HTMLElement? Function(int) _resolveHost;
  final web.Window _window;
  final StreamController<VideoPlayerPipPlatformEvent> _events =
      StreamController<VideoPlayerPipPlatformEvent>.broadcast();
  final Map<int, _TrackedPlayer> _trackedPlayers = {};
  _PipSession? _session;
  bool _disposed = false;
  // Native video PiP requests cannot be cancelled or identified by request ID.
  // Serialize only this path so an old completion cannot close a new owner.
  bool _nativeRequestPending = false;

  @override
  Stream<VideoPlayerPipPlatformEvent> get events => _events.stream;

  @override
  bool get currentPipState => !_disposed && (_session?.active ?? false);

  bool get _documentSupported =>
      _window.isSecureContext &&
      _window.top == _window &&
      _window.hasProperty('documentPictureInPicture'.toJS).toDart &&
      _window.getProperty<JSAny?>('documentPictureInPicture'.toJS) != null;

  bool get _nativeSupported =>
      _window.isSecureContext &&
      _window.document.hasProperty('pictureInPictureEnabled'.toJS).toDart &&
      _window.document.pictureInPictureEnabled;

  bool _safariSupported(web.HTMLVideoElement video) {
    try {
      return video.hasProperty('webkitSupportsPresentationMode'.toJS).toDart &&
          _SafariVideo(video)
              .webkitSupportsPresentationMode('picture-in-picture');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isPipSupported() => Future<bool>.value(
    !_disposed &&
        (_documentSupported ||
            _nativeSupported ||
            _trackedPlayers.values.any(
              (player) => _safariSupported(player.video),
            ) ||
            _safariSupported(web.HTMLVideoElement())),
  );

  @override
  Future<bool> isInPipMode() =>
      Future<bool>.value(!_disposed && (_session?.active ?? false));

  /// Observe PiP started from the browser's own video controls as well as from
  /// the package's public API.
  void playerCreated(int playerId) {
    final video = _resolveVideo(playerId);
    if (_disposed ||
        video == null ||
        identical(_trackedPlayers[playerId]?.video, video)) {
      return;
    }
    _trackedPlayers.remove(playerId)?.dispose();
    final tracked = _TrackedPlayer(video);
    _trackedPlayers[playerId] = tracked;
    tracked.listen('enterpictureinpicture', (_) {
      _adoptNative(playerId, video, _PipKind.video);
    });
    tracked.listen('leavepictureinpicture', (_) {
      final session = _session;
      if (session != null &&
          session.video == video &&
          session.kind == _PipKind.video) {
        _finish(session, pause: true);
      }
    });
    if (video.hasProperty('webkitSetPresentationMode'.toJS).toDart) {
      tracked.listen('webkitpresentationmodechanged', (_) {
        if (_SafariVideo(video).webkitPresentationMode ==
            'picture-in-picture') {
          _adoptNative(playerId, video, _PipKind.safari);
        } else {
          final session = _session;
          if (session != null &&
              session.video == video &&
              session.kind == _PipKind.safari) {
            _finish(session, pause: true);
          }
        }
      });
    }
  }

  void _adoptNative(int playerId, web.HTMLVideoElement video, _PipKind kind) {
    final host = _resolveHost(playerId);
    if (_disposed ||
        host == null ||
        !identical(_resolveVideo(playerId), video)) {
      return;
    }
    if (_session?.video == video) {
      return;
    }
    final previous = _session;
    if (previous != null) {
      _finish(previous, pause: true);
      previous.pipWindow?.close();
    }
    final session = _PipSession(playerId, video, host, kind)..active = true;
    _session = session;
    _showPlaceholder(session);
    video.style.visibility = 'hidden';
    _emit(session, entered: true);
  }

  void _emit(_PipSession session, {bool? entered, String? error}) {
    if (!_events.isClosed) {
      _events.add(
        VideoPlayerPipPlatformEvent(
          playerId: session.playerId,
          isInPip: entered ?? session.active,
          error: error,
        ),
      );
    }
  }

  void _error(int playerId, Object error) {
    if (!_events.isClosed) {
      _events.add(
        VideoPlayerPipPlatformEvent(
          playerId: playerId,
          isInPip: _session?.active == true && _session?.playerId == playerId,
          error:
              'Unable to open Picture in Picture: ${_browserErrorText(error)}',
        ),
      );
    }
  }

  @override
  Future<bool> enterPipMode(int playerId, {int? width, int? height}) async {
    // The feature request below must run before the first await. Awaiting a
    // support check or closing another window loses transient user activation.
    if (_disposed ||
        (width != null && width <= 0) ||
        (height != null && height <= 0)) {
      return false;
    }
    final video = _resolveVideo(playerId);
    final host = _resolveHost(playerId);
    if (video == null ||
        host == null ||
        video.readyState < 1 ||
        video.videoWidth == 0 ||
        video.disablePictureInPicture) {
      _error(playerId, 'The video is not ready or PiP is disabled.');
      return false;
    }
    playerCreated(playerId);
    final current = _session;
    if (current?.playerId == playerId && current?.active == true) {
      return true;
    }
    final _PipKind kind;
    // Prefer the browser's video window so its native controls and chrome are
    // used even when Document PiP is also available.
    if (_nativeSupported &&
        video.hasProperty('requestPictureInPicture'.toJS).toDart) {
      kind = _PipKind.video;
    } else if (_safariSupported(video)) {
      kind = _PipKind.safari;
    } else if (_documentSupported) {
      kind = _PipKind.document;
    } else {
      _error(playerId, 'This browser does not support Picture in Picture.');
      return false;
    }
    if (_nativeRequestPending) {
      _error(
        playerId,
        'A previous Picture in Picture request is still pending.',
      );
      return false;
    }
    if (current != null) {
      _finish(current, pause: true);
      current.pipWindow?.close();
    }
    final session = _PipSession(playerId, video, host, kind);
    _session = session;
    try {
      switch (kind) {
        case _PipKind.document:
          final api = _DocumentPictureInPicture(
            _window.getProperty<JSObject>('documentPictureInPicture'.toJS),
          );
          // Do not await anything before requesting the privileged window.
          final request = api.requestWindow(
            _WindowOptions(
              width: width ?? 480,
              height: height ?? 270,
              disallowReturnToOpener: true,
            ),
          );
          final pipWindow = await request.toDart;
          session.pipWindow = pipWindow;
          if (!_isLive(session) || pipWindow.closed) {
            pipWindow.close();
            return false;
          }
          session.listen(pipWindow, 'pagehide', (_) {
            _finish(session, pause: true);
          });
          _showPlaceholder(session);
          session.ui = _PipControls(
            session,
            onRestore: () => _restore(session),
            onClose: () {
              _finish(session, pause: true);
              pipWindow.close();
            },
            onError: (error) => _emit(session, error: _browserErrorText(error)),
          );
          session.ui!.mount(pipWindow.document);
        case _PipKind.video:
          _nativeRequestPending = true;
          session.listen(video, 'leavepictureinpicture', (_) {
            _finish(session, pause: true);
          });
          try {
            final request = video.requestPictureInPicture();
            await request.toDart;
          } finally {
            _nativeRequestPending = false;
          }
          if (!_isLive(session)) {
            if (_window.document.pictureInPictureElement == video) {
              await _window.document.exitPictureInPicture().toDart;
            }
            return false;
          }
          _showPlaceholder(session);
          video.style.visibility = 'hidden';
        case _PipKind.safari:
          session.listen(video, 'webkitpresentationmodechanged', (_) {
            if (_SafariVideo(video).webkitPresentationMode !=
                'picture-in-picture') {
              _finish(session, pause: true);
            }
          });
          _SafariVideo(video).webkitSetPresentationMode('picture-in-picture');
          if (!_isLive(session) ||
              _SafariVideo(video).webkitPresentationMode !=
                  'picture-in-picture') {
            _finish(session, pause: false);
            return false;
          }
          _showPlaceholder(session);
          video.style.visibility = 'hidden';
      }
      if (!_isLive(session)) {
        return false;
      }
      session.active = true;
      _emit(session, entered: true);
      return true;
    } catch (error) {
      if (_isLive(session)) {
        _finish(session, pause: false);
        session.pipWindow?.close();
        _error(playerId, error);
      }
      return false;
    }
  }

  bool _isLive(_PipSession session) =>
      !_disposed &&
      identical(_session, session) &&
      !session.finished &&
      identical(_resolveVideo(session.playerId), session.video);

  void _showPlaceholder(_PipSession session) {
    final placeholder = web.HTMLDivElement()
      ..className = 'video-player-pip-placeholder'
      ..setAttribute('role', 'status')
      ..style.cssText =
          'position:absolute;inset:0;display:flex;'
          'align-items:center;justify-content:center;flex-direction:column;'
          'gap:12px;background:#000;color:#fff;font:16px Arial,sans-serif;';
    final icon = web.HTMLSpanElement()
      ..textContent = '▣'
      ..style.fontSize = '36px';
    final label = web.HTMLSpanElement()..textContent = 'Picture in Picture';
    placeholder
      ..appendChild(icon)
      ..appendChild(label);
    session.placeholder = placeholder;
    session.host.appendChild(placeholder);
  }

  int _position(_PipSession session) {
    final seconds = session.video.currentTime;
    return seconds.isFinite ? (seconds * 1000).round() : 0;
  }

  void _restore(_PipSession session) {
    if (!_isLive(session)) {
      return;
    }
    // Focus from this click before any asynchronous work consumes activation.
    _window.focus();
    _finish(session, pause: true, restored: true);
    session.pipWindow?.close();
  }

  void _finish(
    _PipSession session, {
    required bool pause,
    bool restored = false,
  }) {
    if (session.finished) {
      return;
    }
    session.finished = true;
    final wasActive = session.active;
    session.active = false;
    if (pause) {
      session.video.pause();
    }
    final positionMs = _position(session);
    session.removeListeners();
    session.placeholder?.remove();
    session.placeholder = null;
    // The persistent platform-view host stays in Flutter while its video moves.
    // Reattach even to a detached host so disposal remains safe.
    if (session.video.parentNode != session.host) {
      session.host.appendChild(session.video);
    }
    // Adopt the video back before detaching the PiP UI, so a programmatic exit
    // never removes the playing video together with its container.
    session.ui?.dispose();
    session.ui = null;
    if (session.originalStyle == null) {
      session.video.removeAttribute('style');
    } else {
      session.video.setAttribute('style', session.originalStyle!);
    }
    session.video.controls = session.originalControls;
    session.video.dispatchEvent(web.Event('vpcdocumentchanged'));
    if (identical(_session, session)) {
      _session = null;
    }
    if (wasActive && !_events.isClosed) {
      _events.add(
        VideoPlayerPipPlatformEvent(
          playerId: session.playerId,
          isInPip: false,
          isRestored: restored,
          positionMs: restored ? positionMs : null,
        ),
      );
    }
  }

  Future<bool> _closeSession({required bool pause}) async {
    final session = _session;
    if (session == null) {
      return true;
    }
    _finish(session, pause: pause);
    try {
      switch (session.kind) {
        case _PipKind.document:
          session.pipWindow?.close();
        case _PipKind.video:
          if (_window.document.pictureInPictureElement == session.video) {
            await _window.document.exitPictureInPicture().toDart;
          }
        case _PipKind.safari:
          _SafariVideo(session.video).webkitSetPresentationMode('inline');
      }
      return true;
    } catch (error) {
      _emit(session, entered: false, error: _browserErrorText(error));
      return false;
    }
  }

  @override
  Future<bool> exitPipMode() => _closeSession(pause: false);

  @override
  Future<void> reset() async {
    await _closeSession(pause: true);
  }

  /// Close only the PiP window owned by the player being disposed.
  void playerDisposed(int playerId) {
    _trackedPlayers.remove(playerId)?.dispose();
    if (_session?.playerId == playerId) {
      unawaited(_closeSession(pause: true));
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final tracked in _trackedPlayers.values) {
      tracked.dispose();
    }
    _trackedPlayers.clear();
    await _closeSession(pause: true);
    await _events.close();
  }
}

class _EventBinding {
  _EventBinding(this.target, this.name, this.callback);
  final web.EventTarget target;
  final String name;
  final JSFunction callback;
  void remove() => target.removeEventListener(name, callback);
}

class _TrackedPlayer {
  _TrackedPlayer(this.video);
  final web.HTMLVideoElement video;
  final List<_EventBinding> listeners = [];

  void listen(String name, void Function(web.Event) fn) {
    final callback = fn.toJS;
    video.addEventListener(name, callback);
    listeners.add(_EventBinding(video, name, callback));
  }

  void dispose() {
    for (final listener in listeners) {
      listener.remove();
    }
    listeners.clear();
  }
}

class _PipSession {
  _PipSession(this.playerId, this.video, this.host, this.kind)
    : originalStyle = video.getAttribute('style'),
      originalControls = video.controls;
  final int playerId;
  final web.HTMLVideoElement video;
  final web.HTMLElement host;
  final _PipKind kind;
  final String? originalStyle;
  final bool originalControls;
  final List<_EventBinding> listeners = [];
  web.Window? pipWindow;
  web.HTMLDivElement? placeholder;
  _PipControls? ui;
  bool active = false;
  bool finished = false;

  void listen(
    web.EventTarget target,
    String name,
    void Function(web.Event) fn,
  ) {
    final callback = fn.toJS;
    target.addEventListener(name, callback);
    listeners.add(_EventBinding(target, name, callback));
  }

  void removeListeners() {
    for (final binding in listeners) {
      binding.remove();
    }
    listeners.clear();
  }
}

class _PipControls {
  _PipControls(
    this.session, {
    required this.onRestore,
    required this.onClose,
    required this.onError,
  });
  final _PipSession session;
  final void Function() onRestore;
  final void Function() onClose;
  final void Function(Object) onError;
  late web.HTMLDivElement root;
  late web.HTMLDivElement controls;
  late web.HTMLButtonElement play;
  late web.HTMLInputElement seek;
  late web.HTMLSpanElement time;
  web.HTMLStyleElement? _style;
  Timer? _hideTimer;
  bool _hovering = false;
  bool _scrubbing = false;
  bool _disposed = false;
  double _rangeStart = 0;
  double _rangeEnd = 0;

  web.HTMLVideoElement get video => session.video;

  // Mouse clicks may leave a button focused. Only keyboard-visible focus keeps
  // the overlay open after the pointer leaves the video.
  bool get _hasFocus => root.querySelector(':focus-visible') != null;

  void mount(web.Document document) {
    document.title = 'Video (PiP)';
    _style = web.HTMLStyleElement()..textContent = _pipCss;
    document.head!.appendChild(_style!);
    document.body!.style.cssText =
        'margin:0;background:transparent;overflow:hidden;';
    root = web.HTMLDivElement()..id = 'vpc-pip-root';
    controls = web.HTMLDivElement()
      ..id = 'vpc-pip-controls'
      ..setAttribute('data-visible', 'true');
    video
      ..controls = false
      ..style.cssText =
          'display:block;width:100%;height:100%;'
          'object-fit:cover;background:transparent;';
    root.appendChild(video);

    final center = web.HTMLDivElement()..className = 'vpc-center';
    final backward = _button(
      'vpc-pip-backward',
      _PipIcon.backward,
      'Rewind 10 seconds',
    );
    play = _button('vpc-pip-play', _PipIcon.play, 'Play');
    final forward = _button(
      'vpc-pip-forward',
      _PipIcon.forward,
      'Forward 10 seconds',
    );
    center
      ..appendChild(backward)
      ..appendChild(play)
      ..appendChild(forward);
    final top = web.HTMLDivElement()..className = 'vpc-top';
    final restore = _button(
      'vpc-pip-restore',
      _PipIcon.restore,
      'Return to video',
    );
    final close = _button(
      'vpc-pip-close',
      _PipIcon.close,
      'Close Picture in Picture',
    );
    top
      ..appendChild(restore)
      ..appendChild(close);
    final bottom = web.HTMLDivElement()..className = 'vpc-bottom';
    time = web.HTMLSpanElement()..id = 'vpc-pip-time';
    seek = web.HTMLInputElement()
      ..id = 'vpc-pip-seek'
      ..type = 'range'
      ..step = '0.01'
      ..min = '0'
      ..max = '0'
      ..value = '0'
      ..setAttribute('aria-label', 'Video playback position');
    bottom
      ..appendChild(time)
      ..appendChild(seek);
    controls
      ..appendChild(top)
      ..appendChild(center)
      ..appendChild(bottom);
    root.appendChild(controls);
    document.body!.appendChild(root);
    video.dispatchEvent(web.Event('vpcdocumentchanged'));
    session.listen(backward, 'click', (_) => _skip(-10));
    session.listen(forward, 'click', (_) => _skip(10));
    session.listen(play, 'click', (_) => _toggle());
    session.listen(restore, 'click', (_) => onRestore());
    session.listen(close, 'click', (_) => onClose());
    session.listen(root, 'pointerenter', (_) {
      _hovering = true;
      _show();
    });
    session.listen(root, 'pointermove', (_) => _show());
    session.listen(root, 'pointerleave', (_) {
      _hovering = false;
      _scheduleHide();
    });
    session.listen(root, 'focusin', (_) => _show());
    session.listen(root, 'focusout', (_) => _scheduleHide());
    session.listen(seek, 'pointerdown', (_) {
      _scrubbing = true;
      _show();
    });
    session.listen(seek, 'input', (_) {
      final value = double.tryParse(seek.value);
      if (value != null) {
        _seek(value);
      }
    });
    session.listen(document, 'pointerup', (_) {
      _scrubbing = false;
      _scheduleHide();
    });
    session.listen(document, 'pointercancel', (_) {
      _scrubbing = false;
      _scheduleHide();
    });
    session.listen(seek, 'change', (_) {
      _scrubbing = false;
      _scheduleHide();
    });
    session.listen(document, 'keydown', (event) {
      final keyboard = event as web.KeyboardEvent;
      // Range/buttons retain their native keyboard behavior.
      if (event.target == seek || event.target.isA<web.HTMLButtonElement>()) {
        return;
      }
      switch (keyboard.key) {
        case ' ':
        case 'k':
          event.preventDefault();
          _toggle();
        case 'ArrowLeft':
          event.preventDefault();
          _skip(-10);
        case 'ArrowRight':
          event.preventDefault();
          _skip(10);
      }
    });
    for (final name in [
      'timeupdate',
      'durationchange',
      'progress',
      'loadedmetadata',
      'play',
      'pause',
      'ended',
      'seeking',
      'seeked',
    ]) {
      session.listen(video, name, (_) => _update());
    }
    _update();
    _scheduleHide();
  }

  web.HTMLButtonElement _button(String id, _PipIcon icon, String label) {
    final button = web.HTMLButtonElement()
      ..id = id
      ..type = 'button'
      ..title = label
      ..setAttribute('aria-label', label);
    _setIcon(button, icon);
    return button;
  }

  void _setIcon(web.HTMLButtonElement button, _PipIcon icon) {
    if (button.getAttribute('data-icon') == icon.name) return;
    button.setAttribute('data-icon', icon.name);
    while (button.firstChild != null) {
      button.removeChild(button.firstChild!);
    }
    final document = button.ownerDocument!;
    const namespace = 'http://www.w3.org/2000/svg';
    final svg = document.createElementNS(namespace, 'svg')
      ..setAttribute('viewBox', '0 0 24 24')
      ..setAttribute('aria-hidden', 'true')
      ..setAttribute('focusable', 'false');
    final path = document.createElementNS(namespace, 'path');
    switch (icon) {
      case _PipIcon.play:
        path.setAttribute('d', 'M8 5v14l11-7z');
        path.setAttribute('fill', 'currentColor');
      case _PipIcon.pause:
        path.setAttribute('d', 'M7 5h4v14H7zM14 5h4v14h-4z');
        path.setAttribute('fill', 'currentColor');
      case _PipIcon.backward:
      case _PipIcon.forward:
        path.setAttribute(
          'd',
          icon == _PipIcon.backward
              ? 'M9 5a9 9 0 1 1-5 8M9 1v4H5'
              : 'M15 5a9 9 0 1 0 5 8M15 1v4h4',
        );
        path.setAttribute('fill', 'none');
        path.setAttribute('stroke', 'currentColor');
        path.setAttribute('stroke-width', '1.8');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
      case _PipIcon.restore:
        path.setAttribute('d', 'M10 3H3v7M3 3l8 8M14 3h7v18H3v-7');
        path.setAttribute('fill', 'none');
        path.setAttribute('stroke', 'currentColor');
        path.setAttribute('stroke-width', '1.8');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
      case _PipIcon.close:
        path.setAttribute('d', 'M6 6l12 12M18 6 6 18');
        path.setAttribute('fill', 'none');
        path.setAttribute('stroke', 'currentColor');
        path.setAttribute('stroke-width', '2');
        path.setAttribute('stroke-linecap', 'round');
    }
    svg.appendChild(path);
    if (icon == _PipIcon.backward || icon == _PipIcon.forward) {
      final text = document.createElementNS(namespace, 'text')
        ..setAttribute('x', '12')
        ..setAttribute('y', '16.5')
        ..setAttribute('text-anchor', 'middle')
        ..setAttribute('fill', 'currentColor')
        ..setAttribute('font-family', 'Arial,sans-serif')
        ..setAttribute('font-size', '8')
        ..setAttribute('font-weight', '700')
        ..textContent = '10';
      svg.appendChild(text);
    }
    button.appendChild(svg);
  }

  void _show() {
    if (_disposed) {
      return;
    }
    _hideTimer?.cancel();
    controls.setAttribute('data-visible', 'true');
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_hovering || _scrubbing || _hasFocus || _disposed) {
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!_disposed && !_hovering && !_scrubbing && !_hasFocus) {
        controls.setAttribute('data-visible', 'false');
      }
    });
  }

  void _toggle() {
    _show();
    if (video.paused || video.ended) {
      // Calling play synchronously here preserves the button's activation.
      unawaited(
        video.play().toDart.then<void>(
          (_) {},
          onError: (Object error) {
            onError(error);
          },
        ),
      );
    } else {
      video.pause();
    }
    _update();
    _scheduleHide();
  }

  void _skip(double seconds) {
    _show();
    _updateRange();
    _seek(video.currentTime + seconds);
    _scheduleHide();
  }

  void _updateRange() {
    final duration = video.duration;
    if (duration.isFinite && duration > 0) {
      _rangeStart = 0;
      _rangeEnd = duration;
    } else if (video.seekable.length > 0) {
      final last = video.seekable.length - 1;
      _rangeStart = video.seekable.start(last);
      _rangeEnd = video.seekable.end(last);
    } else {
      _rangeStart = 0;
      _rangeEnd = 0;
    }
  }

  void _seek(double position) {
    if (_disposed || !position.isFinite) {
      return;
    }
    _updateRange();
    if (_rangeEnd <= _rangeStart) {
      return;
    }
    // currentTime updates the decoded frame even while paused; no second
    // player or forced play/pause is necessary for a preview.
    video.currentTime = position.clamp(_rangeStart, _rangeEnd).toDouble();
    _update();
  }

  void _update() {
    if (_disposed) {
      return;
    }
    _updateRange();
    final current = video.currentTime.isFinite ? video.currentTime : 0.0;
    seek
      ..disabled = _rangeEnd <= _rangeStart
      ..min = '$_rangeStart'
      ..max = '$_rangeEnd';
    if (!_scrubbing) {
      seek.value = '${current.clamp(_rangeStart, _rangeEnd)}';
    }
    final playing = !video.paused && !video.ended;
    _setIcon(play, playing ? _PipIcon.pause : _PipIcon.play);
    play
      ..title = playing ? 'Pause' : 'Play'
      ..setAttribute('aria-label', playing ? 'Pause' : 'Play');
    final duration = video.duration;
    time.textContent =
        '${_formatTime(current)} / '
        '${duration.isInfinite ? 'LIVE' : _formatTime(duration)}';
    seek.setAttribute('aria-valuetext', time.textContent!);
    if (_rangeEnd > _rangeStart) {
      final range = _rangeEnd - _rangeStart;
      final progress = ((current - _rangeStart) / range).clamp(0, 1) * 100;
      final layers = <String>[
        'linear-gradient(to right,#f44336 0%,#f44336 $progress%,'
            'transparent $progress%,transparent 100%)',
      ];
      for (var i = 0; i < video.buffered.length; i++) {
        final start =
            ((video.buffered.start(i) - _rangeStart) / range).clamp(0, 1) * 100;
        final end =
            ((video.buffered.end(i) - _rangeStart) / range).clamp(0, 1) * 100;
        layers.add(
          'linear-gradient(to right,transparent 0%,'
          'transparent $start%,rgba(255,255,255,.7) $start%,rgba(255,255,255,.7) $end%,'
          'transparent $end%,transparent 100%)',
        );
      }
      // Keep a generous pointer hit area while drawing a thin progress line.
      seek.style.backgroundImage =
          '${layers.join(',')},linear-gradient(rgba(255,255,255,.32),rgba(255,255,255,.32))';
    }
  }

  String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      return '--:--';
    }
    final total = seconds.floor();
    final hours = total ~/ 3600;
    final minutes = (total ~/ 60) % 60;
    final remainder = (total % 60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$remainder';
    }
    return '$minutes:$remainder';
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _hideTimer?.cancel();
    _style?.remove();
    root.remove();
  }
}

enum _PipIcon { backward, play, pause, forward, restore, close }

const _pipCss = '''
html,body{height:100%;width:100%;margin:0;background:transparent;color:#fff}
#vpc-pip-root{position:relative;width:100vw;height:100vh;font-family:Arial,sans-serif;overflow:hidden}
#vpc-pip-controls{position:absolute;inset:0;opacity:1;transition:opacity .16s ease;pointer-events:none}
#vpc-pip-controls[data-visible="false"]{opacity:0}
#vpc-pip-controls[data-visible="false"] button,#vpc-pip-controls[data-visible="false"] input{pointer-events:none}
#vpc-pip-controls button{display:grid;place-items:center;border:0;border-radius:8px;color:#fff;background:transparent;cursor:pointer;pointer-events:auto;min-width:44px;height:44px;padding:7px;-webkit-tap-highlight-color:transparent}
#vpc-pip-controls button svg{display:block;width:30px;height:30px;pointer-events:none;filter:drop-shadow(0 1px 2px rgba(0,0,0,.7));transition:transform .12s ease,opacity .12s ease}
#vpc-pip-controls button:hover svg{transform:scale(1.1)}
#vpc-pip-controls button:active svg{transform:scale(.94);opacity:.85}
#vpc-pip-controls button:focus-visible,#vpc-pip-seek:focus-visible{outline:none}
#vpc-pip-controls button:focus-visible svg{transform:scale(1.1);filter:drop-shadow(0 1px 2px rgba(0,0,0,.7)) drop-shadow(0 0 3px rgba(255,255,255,.85))}
.vpc-center{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);display:flex;gap:22px;align-items:center}
#vpc-pip-play{width:56px;height:56px}
#vpc-pip-play svg{width:40px;height:40px}
.vpc-top{position:absolute;right:8px;top:8px;display:flex;gap:6px}
.vpc-top button{min-width:32px!important;height:32px!important;padding:5px!important}
.vpc-top button svg{width:22px;height:22px}
.vpc-bottom{position:absolute;bottom:0;left:0;right:0;padding:8px 12px 12px;box-sizing:border-box}
#vpc-pip-time{display:block;font-size:12px;font-variant-numeric:tabular-nums;margin-bottom:4px;text-shadow:0 1px 3px rgba(0,0,0,.8)}
#vpc-pip-seek{display:block;box-sizing:border-box;width:100%;height:20px;border-radius:3px;margin:0;appearance:none;-webkit-appearance:none;cursor:pointer;pointer-events:auto;background-color:transparent;background-image:linear-gradient(rgba(255,255,255,.32),rgba(255,255,255,.32));background-size:100% 3px;background-position:center;background-repeat:no-repeat;touch-action:none}
#vpc-pip-seek:disabled{cursor:default;opacity:.5}
#vpc-pip-seek::-webkit-slider-thumb{appearance:none;-webkit-appearance:none;width:10px;height:10px;border-radius:50%;background:#f44336}
#vpc-pip-seek::-moz-range-thumb{border:0;width:10px;height:10px;border-radius:50%;background:#f44336}
#vpc-pip-seek:focus-visible::-webkit-slider-thumb{box-shadow:0 0 0 2px #fff}
#vpc-pip-seek:focus-visible::-moz-range-thumb{box-shadow:0 0 0 2px #fff}
#vpc-pip-seek::-moz-range-track{background:transparent}
@media(max-width:280px){.vpc-center{gap:8px}.vpc-bottom{padding-left:8px;padding-right:8px}}
@media(max-height:140px){#vpc-pip-time{display:none}.vpc-bottom{padding:6px 10px 9px}.vpc-center{gap:10px}#vpc-pip-controls .vpc-center button{min-width:44px;height:44px;padding:8px}#vpc-pip-controls .vpc-center button svg{width:26px;height:26px}#vpc-pip-play{width:44px;height:44px!important}.vpc-top{top:4px;right:4px}.vpc-top button{min-width:28px!important;height:28px!important;padding:4px!important}.vpc-top button svg{width:20px;height:20px}}
@media(prefers-reduced-motion:reduce){#vpc-pip-controls,#vpc-pip-controls button svg{transition:none}}
''';
