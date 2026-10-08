import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Keeps the display awake while this player's visible document is playing.
/// Each player owns its own sentinel, so pausing one never releases another.
class BrowserVideoWakeLock {
  BrowserVideoWakeLock(this._video) {
    for (final name in [
      'play',
      'playing',
      'pause',
      'ended',
      'vpcdocumentchanged',
    ]) {
      _subscriptions.add(
        web.EventStreamProvider<web.Event>(name)
            .forTarget(_video)
            .listen((_) => refresh()),
      );
    }
    refresh();
  }

  final web.HTMLVideoElement _video;
  final List<StreamSubscription<web.Event>> _subscriptions = [];
  web.Document? _document;
  StreamSubscription<web.Event>? _visibilitySubscription;
  StreamSubscription<web.Event>? _releaseSubscription;
  web.WakeLockSentinel? _sentinel;
  bool _enabled = true;
  bool _disposed = false;
  bool _requestPending = false;
  int _generation = 0;

  void setEnabled(bool enabled) {
    if (_disposed) return;
    _enabled = enabled;
    refresh();
  }

  bool get _shouldHold =>
      !_disposed &&
      _enabled &&
      !_video.paused &&
      !_video.ended &&
      _document?.visibilityState == 'visible';

  /// Rechecks playback and the owning document after visibility or PiP changes.
  void refresh() {
    if (_disposed) return;
    final document = _video.ownerDocument;
    if (document == null) {
      _generation++;
      _release();
      unawaited(_visibilitySubscription?.cancel());
      _visibilitySubscription = null;
      _document = null;
      return;
    }
    if (!identical(_document, document)) {
      _generation++;
      _release();
      unawaited(_visibilitySubscription?.cancel());
      _document = document;
      _visibilitySubscription = const web.EventStreamProvider<web.Event>(
        'visibilitychange',
      ).forTarget(document).listen((_) => refresh());
    }

    if (!_shouldHold) {
      _generation++;
      _release();
      return;
    }
    if (_sentinel != null && !_sentinel!.released) return;
    if (_requestPending) return;
    final window = document.defaultView;
    if (window == null || !window.isSecureContext) return;
    final navigator = window.navigator;
    if (!navigator.hasProperty('wakeLock'.toJS).toDart) return;

    _requestPending = true;
    unawaited(_request(navigator, _generation));
  }

  Future<void> _request(web.Navigator navigator, int generation) async {
    web.WakeLockSentinel? granted;
    try {
      granted = await navigator.wakeLock.request('screen').toDart;
      if (_disposed || generation != _generation || !_shouldHold) {
        await _releaseSentinel(granted);
      } else if (!granted.released) {
        _sentinel = granted;
        unawaited(_releaseSubscription?.cancel());
        _releaseSubscription =
            const web.EventStreamProvider<web.Event>('release')
                .forTarget(granted)
                .listen((_) {
                  if (identical(_sentinel, granted)) _sentinel = null;
                  // Wait for a playback/visibility change before retrying:
                  // the system may have released this lock to save power.
                });
      }
    } catch (_) {
      // Permissions, low battery and missing browser support are nonfatal.
    } finally {
      _requestPending = false;
      if (!_disposed && generation != _generation && _shouldHold) refresh();
    }
  }

  void _release() {
    final sentinel = _sentinel;
    _sentinel = null;
    unawaited(_releaseSubscription?.cancel());
    _releaseSubscription = null;
    if (sentinel != null) unawaited(_releaseSentinel(sentinel));
  }

  Future<void> _releaseSentinel(web.WakeLockSentinel sentinel) async {
    try {
      if (!sentinel.released) await sentinel.release().toDart;
    } catch (_) {
      // A document can close while the release promise is still pending.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _release();
    unawaited(_visibilitySubscription?.cancel());
    _visibilitySubscription = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _document = null;
  }
}
