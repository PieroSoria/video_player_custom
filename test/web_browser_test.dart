@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:video_player_custom/src/cache/browser_cache.dart';
import 'package:video_player_custom/src/platform_impl/web/web_pip.dart';
import 'package:video_player_custom/src/platform_impl/web/web_tracks.dart'
    as tracks;
import 'package:video_player_custom/src/platform_impl/web/web_wake_lock.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip_platform_interface.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip.dart';
import 'package:video_player_custom/video_player_custom_web.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;
import 'package:web/web.dart' as web;

@JS('eval')
external JSAny? _eval(JSString source);

Future<void> _event(web.EventTarget target, String type) {
  final result = Completer<void>();
  late JSFunction listener;
  listener = ((web.Event _) {
    target.removeEventListener(type, listener);
    result.complete();
  }).toJS;
  target.addEventListener(type, listener);
  return result.future.timeout(const Duration(seconds: 10));
}

Future<web.Blob> _recordFixture() async {
  // Generate a valid two-color WebM locally. No external URL, codec binary,
  // or source asset is needed to prove cached bytes decode in the browser.
  return (_eval(
    r'''
    (async () => {
      const canvas = document.createElement('canvas');
      canvas.width = 32; canvas.height = 24;
      const context = canvas.getContext('2d');
      context.fillStyle = '#ff0000'; context.fillRect(0, 0, 32, 24);
      const stream = canvas.captureStream(20);
      const recorder = new MediaRecorder(stream, {mimeType: 'video/webm;codecs=vp8'});
      const chunks = [];
      const stopped = new Promise((resolve, reject) => {
        recorder.ondataavailable = event => chunks.push(event.data);
        recorder.onstop = resolve;
        recorder.onerror = reject;
      });
      recorder.start();
      let frame = 0;
      const timer = setInterval(() => {
        context.fillStyle = frame++ % 2 ? '#ff0000' : '#0000ff';
        context.fillRect(0, 0, 32, 24);
      }, 50);
      await new Promise(resolve => setTimeout(resolve, 1300));
      clearInterval(timer);
      recorder.stop();
      await stopped;
      stream.getTracks().forEach(track => track.stop());
      return new Blob(chunks, {type: 'video/webm'});
    })()
  '''
        .toJS,
  ) as JSPromise<web.Blob>).toDart;
}

Future<web.HTMLVideoElement> _loadVideo(String source) async {
  final video = web.HTMLVideoElement()
    ..muted = true
    ..playsInline = true;
  web.document.body!.appendChild(video);
  final loaded = _event(video, 'loadeddata');
  video.src = source;
  video.load();
  await loaded;
  return video;
}

void _releaseVideo(web.HTMLVideoElement video) {
  video.pause();
  video.removeAttribute('src');
  video.load();
  video.remove();
}

web.Blob _bytes(String text) => web.Blob(
  <JSAny>[utf8.encode(text).toJS].toJS,
  web.BlobPropertyBag(type: 'application/octet-stream'),
);

class _FetchStub {
  _FetchStub(this.response) {
    original = web.window.getProperty<JSFunction>('fetch'.toJS);
    web.window.setProperty(
      'fetch'.toJS,
      ((JSAny request, JSAny? init) {
        final url = request.isA<JSString>()
            ? (request as JSString).toDart
            : (request as web.Request).url;
        final properties = init as JSObject?;
        final headerInit = properties?.getProperty<JSObject?>('headers'.toJS);
        requests.add(url);
        headers.add(
          headerInit == null ? web.Headers() : web.Headers(headerInit),
        );
        return Future<web.Response>.sync(() => response(url)).toJS;
      }).toJS,
    );
  }

  final FutureOr<web.Response> Function(String url) response;
  late final JSFunction original;
  final List<String> requests = <String>[];
  final List<web.Headers> headers = <web.Headers>[];

  void restore() => web.window.setProperty('fetch'.toJS, original);

  Future<web.Response> fetchBlob(String source) => (original.callAsFunction(
    web.window,
    source.toJS,
  ) as JSPromise<web.Response>).toDart;
}

web.Response _response(web.Blob body, {int status = 200}) => web.Response(
  body,
  web.ResponseInit(
    status: status,
    headers: <String, String>{'Content-Type': body.type}.jsify() as JSObject,
  ),
);

void _allowHlsForStorageTest() {
  // Chromium cannot decode native HLS. This override isolates playlist storage
  // and rewriting; only the WebM fixture tests assert actual media playback.
  _eval(
    r'''
    globalThis.__vpcCanPlayType = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function(type) {
      if (type.toLowerCase().includes('mpegurl')) return 'maybe';
      return globalThis.__vpcCanPlayType.call(this, type);
    };
  '''
        .toJS,
  );
  addTearDown(() {
    _eval(
      r'''
      HTMLMediaElement.prototype.canPlayType = globalThis.__vpcCanPlayType;
      delete globalThis.__vpcCanPlayType;
    '''
          .toJS,
    );
  });
}

class _DocumentPipMock {
  _DocumentPipMock({this.disableNative = true}) {
    frame = context.document.createElement('iframe') as web.HTMLIFrameElement;
    frame.style.display = 'none';
    context.document.body!.appendChild(frame);
    child = frame.contentWindow!;
    final api = JSObject();
    api.setProperty(
      'requestWindow'.toJS,
      ((JSObject options) {
        lastOptions = options;
        return Future<web.Window>.value(child).toJS;
      }).toJS,
    );
    context.setProperty('__vpcMockPipApi'.toJS, api);
    context.setProperty('__vpcMockDisableNativePip'.toJS, disableNative.toJS);
    _eval(
      r'''
      window.top.__vpcOldPipApi = Object.getOwnPropertyDescriptor(window.top, 'documentPictureInPicture');
      Object.defineProperty(window.top, 'documentPictureInPicture', {
        value: window.top.__vpcMockPipApi, configurable: true
      });
      if (window.top.__vpcMockDisableNativePip) {
        window.top.__vpcOldNativePipEnabled = Object.getOwnPropertyDescriptor(window.top.document, 'pictureInPictureEnabled');
        Object.defineProperty(window.top.document, 'pictureInPictureEnabled', {
          value: false, configurable: true
        });
      }
    '''
          .toJS,
    );
    child.setProperty(
      'close'.toJS,
      (() {
        closes++;
        child.dispatchEvent(web.Event('pagehide'));
      }).toJS,
    );
  }

  final web.Window context = web.window.top!;
  final bool disableNative;
  late final web.HTMLIFrameElement frame;
  late final web.Window child;
  JSObject? lastOptions;
  int closes = 0;

  void dispose() {
    frame.remove();
    _eval(
      r'''
      if (window.top.__vpcOldPipApi) {
        Object.defineProperty(window.top, 'documentPictureInPicture', window.top.__vpcOldPipApi);
      } else {
        delete window.top.documentPictureInPicture;
      }
      if (window.top.__vpcMockDisableNativePip) {
        if (window.top.__vpcOldNativePipEnabled) {
          Object.defineProperty(window.top.document, 'pictureInPictureEnabled', window.top.__vpcOldNativePipEnabled);
        } else {
          delete window.top.document.pictureInPictureEnabled;
        }
      }
      delete window.top.__vpcOldPipApi;
      delete window.top.__vpcOldNativePipEnabled;
      delete window.top.__vpcMockPipApi;
      delete window.top.__vpcMockDisableNativePip;
    '''
          .toJS,
    );
  }
}

web.HTMLVideoElement _controlledVideo() {
  // The real playback tests above cover decoding. A controlled media clock
  // lets DOM controls exercise precise 10-second jumps and both timeline ends.
  return _eval(
    r'''
    (() => {
      const video = document.createElement('video');
      let position = 20, paused = true;
      Object.defineProperties(video, {
        readyState: {get: () => 4}, videoWidth: {get: () => 640},
        videoHeight: {get: () => 360}, duration: {get: () => 120},
        paused: {get: () => paused}, ended: {get: () => false},
        currentTime: {
          get: () => position,
          set: value => {position = value; video.dispatchEvent(new Event('timeupdate'));}
        }
      });
      video.play = () => {
        paused = false; video.dispatchEvent(new Event('play')); return Promise.resolve();
      };
      video.pause = () => {paused = true; video.dispatchEvent(new Event('pause'));};
      return video;
    })()
  '''
        .toJS,
  ) as web.HTMLVideoElement;
}

void _mockNativePipApi({web.Document? document}) {
  web.window.setProperty('__vpcNativeDocument'.toJS, document ?? web.document);
  _eval(
    r'''
    const nativeDocument = globalThis.__vpcNativeDocument;
    globalThis.__vpcNativeDescriptors = {
      enabled: Object.getOwnPropertyDescriptor(nativeDocument, 'pictureInPictureEnabled'),
      element: Object.getOwnPropertyDescriptor(nativeDocument, 'pictureInPictureElement'),
      exit: Object.getOwnPropertyDescriptor(nativeDocument, 'exitPictureInPicture'),
      request: Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'requestPictureInPicture')
    };
    Object.defineProperty(nativeDocument, 'pictureInPictureEnabled', {value: true, configurable: true});
    Object.defineProperty(nativeDocument, 'pictureInPictureElement', {
      get: () => globalThis.__vpcNativeVideo || null, configurable: true
    });
    Object.defineProperty(nativeDocument, 'exitPictureInPicture', {
      value: () => {
        const video = globalThis.__vpcNativeVideo;
        globalThis.__vpcNativeVideo = null;
        if (video) video.dispatchEvent(new Event('leavepictureinpicture'));
        return Promise.resolve();
      }, configurable: true
    });
    Object.defineProperty(HTMLVideoElement.prototype, 'requestPictureInPicture', {
      value: function() {
        globalThis.__vpcNativeVideo = this;
        this.dispatchEvent(new Event('enterpictureinpicture'));
        return Promise.resolve({width: 480, height: 270});
      }, configurable: true
    });
  '''
        .toJS,
  );
  addTearDown(() {
    _eval(
      r'''
      const saved = globalThis.__vpcNativeDescriptors;
      const nativeDocument = globalThis.__vpcNativeDocument;
      for (const [key, property] of [
        ['enabled', 'pictureInPictureEnabled'], ['element', 'pictureInPictureElement'],
        ['exit', 'exitPictureInPicture']
      ]) {
        if (saved[key]) Object.defineProperty(nativeDocument, property, saved[key]);
        else delete nativeDocument[property];
      }
      if (saved.request) Object.defineProperty(HTMLVideoElement.prototype, 'requestPictureInPicture', saved.request);
      else delete HTMLVideoElement.prototype.requestPictureInPicture;
      delete globalThis.__vpcNativeDescriptors;
      delete globalThis.__vpcNativeVideo;
      delete globalThis.__vpcNativeDocument;
    '''
          .toJS,
    );
  });
}

void _mockSafariPipApi(web.HTMLVideoElement video) {
  _mockNativePipApi();
  _eval(
    "Object.defineProperty(document, 'pictureInPictureEnabled', {value: false, configurable: true});"
        .toJS,
  );
  video.setProperty('webkitPresentationMode'.toJS, 'inline'.toJS);
  video.setProperty(
    'webkitSupportsPresentationMode'.toJS,
    ((JSString mode) => mode.toDart == 'picture-in-picture').toJS,
  );
  video.setProperty(
    'webkitSetPresentationMode'.toJS,
    ((JSString mode) {
      video.setProperty('webkitPresentationMode'.toJS, mode);
      video.dispatchEvent(web.Event('webkitpresentationmodechanged'));
    }).toJS,
  );
}

void main() {
  late web.Blob fixture;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fixture = await _recordFixture();
  });

  test('generated local media decodes, plays, pauses and seeks', () async {
    final source = web.URL.createObjectURL(fixture);
    final video = await _loadVideo(source);
    addTearDown(() {
      _releaseVideo(video);
      web.URL.revokeObjectURL(source);
    });
    expect(video.videoWidth, 32);
    expect(video.videoHeight, 24);
    await video.play().toDart;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(video.currentTime, greaterThan(0));
    video.pause();
    expect(video.paused, isTrue);
    final sought = _event(video, 'seeked');
    video.currentTime = 0.1;
    await sought;
    expect(video.currentTime, closeTo(0.1, 0.03));
  });

  group('persistent browser cache', () {
    late WebVideoPlayerCache cache;
    late String namespace;

    setUp(() {
      namespace = 'vpc_browser_test_${DateTime.now().microsecondsSinceEpoch}';
      cache = WebVideoPlayerCache(namespace: namespace);
    });

    tearDown(() async {
      await cache.clear();
      cache.dispose();
    });

    test('completed bytes survive reopen and play with network offline', () async {
      const uri = 'https://media.test/offline.webm';
      final online = _FetchStub((_) => _response(fixture));
      addTearDown(online.restore);
      expect(await cache.supported, isTrue);
      await cache.prefetch(uri, cacheKey: 'offline');
      expect(online.requests, <String>[uri.toString()]);
      expect(await cache.have(uri, cacheKey: 'offline'), isTrue);
      expect(await cache.totalSizeBytes(), fixture.size);
      online.restore();

      // A second object reads persisted IndexedDB state. Network failure makes
      // it impossible for the test to succeed by downloading the source again.
      final offline = _FetchStub((_) => throw StateError('Network offline'));
      addTearDown(offline.restore);
      final reopened = WebVideoPlayerCache(namespace: namespace);
      addTearDown(reopened.dispose);
      final source = await reopened.sourceFor(uri, cacheKey: 'offline');
      expect(source, startsWith('blob:'));
      final video = await _loadVideo(source!);
      try {
        expect(video.videoWidth, 32);
        await video.play().toDart;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(video.currentTime, greaterThan(0));
        expect(offline.requests, isEmpty);
      } finally {
        _releaseVideo(video);
        reopened.releaseSource(source);
      }
    });

    test(
      'sends requested headers and does not redownload a cache hit',
      () async {
        const uri = 'https://media.test/private.mp4';
        final network = _FetchStub((_) => _response(_bytes('complete video')));
        addTearDown(network.restore);
        await cache.prefetch(
          uri,
          cacheKey: 'user/private',
          headers: <String, String>{'Authorization': 'Bearer browser-test'},
        );
        await cache.prefetch(uri, cacheKey: 'user/private');
        expect(network.requests, hasLength(1));
        expect(
          network.headers.single.get('Authorization'),
          'Bearer browser-test',
        );
        await cache.remove(uri, cacheKey: 'user/private');
        expect(await cache.have(uri, cacheKey: 'user/private'), isFalse);
        expect(await cache.totalSizeBytes(), 0);
      },
    );

    test(
      'partial responses and failed downloads leave no completed entry',
      () async {
        const uri = 'https://media.test/incomplete.mp4';
        final network = _FetchStub(
          (_) => _response(_bytes('partial'), status: 206),
        );
        addTearDown(network.restore);
        await expectLater(cache.prefetch(uri), throwsStateError);
        expect(await cache.have(uri), isFalse);
        expect(await cache.totalSizeBytes(), 0);
      },
    );

    test('explicit live sources bypass storage and fetching', () async {
      const uri = 'https://media.test/live.m3u8';
      final network = _FetchStub((_) => throw StateError('Should not fetch'));
      addTearDown(network.restore);
      await cache.prefetch(uri, isLive: true);
      expect(await cache.have(uri), isFalse);
      expect(network.requests, isEmpty);
    });

    test('live HLS playlists never become completed offline entries', () async {
      _allowHlsForStorageTest();
      const uri = 'https://media.test/live.m3u8';
      final network = _FetchStub(
        (_) => _response(
          _bytes('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n'),
        ),
      );
      addTearDown(network.restore);
      await expectLater(cache.prefetch(uri), throwsFormatException);
      expect(await cache.have(uri), isFalse);
      expect(await cache.totalSizeBytes(), 0);
    });

    test(
      'eviction removes the oldest entry within the configured byte limit',
      () async {
        cache.dispose();
        cache = WebVideoPlayerCache(
          namespace: namespace,
          maxCacheSizeBytes: 20,
        );
        const a = 'https://media.test/a.mp4';
        const b = 'https://media.test/b.mp4';
        const c = 'https://media.test/c.mp4';
        final network = _FetchStub((_) => _response(_bytes('0123456789')));
        addTearDown(network.restore);
        await cache.prefetch(a);
        await Future<void>.delayed(const Duration(milliseconds: 3));
        await cache.prefetch(b);
        await Future<void>.delayed(const Duration(milliseconds: 3));
        final aLease = await cache.sourceFor(a);
        cache.releaseSource(aLease!);
        await Future<void>.delayed(const Duration(milliseconds: 3));
        await cache.prefetch(c);
        expect(await cache.have(a), isTrue);
        expect(await cache.have(b), isFalse);
        expect(await cache.have(c), isTrue);
        expect(await cache.totalSizeBytes(), 20);
      },
    );

    test('HLS VOD rewrites every cached segment to an offline blob', () async {
      _allowHlsForStorageTest();
      const uri = 'https://media.test/media/master.m3u8';
      final network = _FetchStub((url) {
        if (url.endsWith('master.m3u8')) {
          return _response(
            _bytes(
              '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nfirst.ts\n'
              '#EXTINF:6,\nsecond.ts\n#EXT-X-ENDLIST\n',
            ),
          );
        }
        return _response(_bytes(url.endsWith('first.ts') ? 'one' : 'two'));
      });
      addTearDown(network.restore);
      await cache.prefetch(uri);
      expect(network.requests, <String>[
        uri.toString(),
        'https://media.test/media/first.ts',
        'https://media.test/media/second.ts',
      ]);
      final source = await cache.sourceFor(uri);
      expect(source, startsWith('blob:'));
      final playlist = (await (await network.fetchBlob(
        source!,
      )).text().toDart).toDart;
      expect(playlist, contains('#EXT-X-ENDLIST'));
      final segments = playlist
          .split('\n')
          .where((line) => line.startsWith('blob:'));
      expect(segments, hasLength(2));
      final contents = await Future.wait(
        segments.map(
          (segment) async =>
              (await (await network.fetchBlob(segment)).text().toDart).toDart,
        ),
      );
      expect(contents, <String>['one', 'two']);
      cache.releaseSource(source);
    });

    test(
      'clear does not allow a stale in-flight prefetch to repopulate storage',
      () async {
        const uri = 'https://media.test/stale.mp4';
        final pending = Completer<web.Response>();
        final network = _FetchStub((_) => pending.future);
        addTearDown(network.restore);
        final download = cache.prefetch(uri);
        final observed = download.then<void>((_) {}, onError: (Object _) {});
        while (network.requests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await cache.clear();
        pending.complete(_response(_bytes('finished after clear')));
        await observed;
        expect(await cache.have(uri), isFalse);
        expect(await cache.totalSizeBytes(), 0);
      },
    );

    test(
      'remove cancels the old download and preserves a fresh same-key download',
      () async {
        const uri = 'https://media.test/removed.mp4';
        final first = Completer<web.Response>();
        final second = Completer<web.Response>();
        var calls = 0;
        final network = _FetchStub(
          (_) => ++calls == 1 ? first.future : second.future,
        );
        addTearDown(network.restore);
        final stale = cache.prefetch(uri, cacheKey: 'shared');
        final staleResult = expectLater(stale, throwsStateError);
        while (network.requests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await cache.remove(uri, cacheKey: 'shared');
        final fresh = cache.prefetch(uri, cacheKey: 'shared');
        while (network.requests.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        first.complete(_response(_bytes('stale bytes')));
        await staleResult;
        expect(await cache.have(uri, cacheKey: 'shared'), isFalse);
        final deduplicated = cache.prefetch(uri, cacheKey: 'shared');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(network.requests, hasLength(2));
        second.complete(_response(_bytes('fresh bytes')));
        await Future.wait([fresh, deduplicated]);
        expect(await cache.have(uri, cacheKey: 'shared'), isTrue);
        final source = await cache.sourceFor(uri, cacheKey: 'shared');
        final body = (await (await network.fetchBlob(
          source!,
        )).text().toDart).toDart;
        expect(body, 'fresh bytes');
        cache.releaseSource(source);
      },
    );

    test(
      'temporary authenticated playback ignores the persistent size limit',
      () async {
        cache.dispose();
        cache = WebVideoPlayerCache(namespace: namespace, maxCacheSizeBytes: 0);
        final network = _FetchStub((_) => _response(fixture));
        addTearDown(network.restore);
        final source = await cache.fetchSource(
          'https://media.test/private.webm',
          headers: <String, String>{'Authorization': 'Bearer temporary'},
        );
        final video = await _loadVideo(source);
        try {
          expect(video.videoWidth, 32);
          expect(
            network.headers.single.get('Authorization'),
            'Bearer temporary',
          );
          expect(await cache.totalSizeBytes(), 0);
        } finally {
          _releaseVideo(video);
          cache.releaseSource(source);
        }
      },
    );

    test('clear preserves a pending temporary authenticated source', () async {
      final pending = Completer<web.Response>();
      final network = _FetchStub((_) => pending.future);
      addTearDown(network.restore);
      final fetching = cache.fetchSource(
        'https://media.test/private.webm',
        headers: <String, String>{'Authorization': 'Bearer temporary'},
      );
      while (network.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await cache.clear();
      pending.complete(_response(fixture));
      final source = await fetching;
      final video = await _loadVideo(source);
      try {
        expect(video.videoWidth, 32);
        expect(await cache.totalSizeBytes(), 0);
      } finally {
        _releaseVideo(video);
        cache.releaseSource(source);
      }
    });
  });

  group('Document PiP controls', () {
    late _DocumentPipMock browser;
    late WebVideoPlayerPip pip;
    late web.HTMLVideoElement video;
    late web.HTMLDivElement host;
    late List<VideoPlayerPipPlatformEvent> events;
    late StreamSubscription<VideoPlayerPipPlatformEvent> subscription;

    setUp(() {
      browser = _DocumentPipMock();
      video = _controlledVideo();
      host = web.HTMLDivElement()..appendChild(video);
      web.document.body!.appendChild(host);
      events = [];
      pip = WebVideoPlayerPip(
        resolveVideo: (id) => id == 7 ? video : null,
        resolveHost: (id) => id == 7 ? host : null,
        browsingWindow: browser.context,
      );
      subscription = pip.events.listen(events.add);
    });

    tearDown(() async {
      await pip.dispose();
      await subscription.cancel();
      host.remove();
      browser.dispose();
    });

    web.HTMLElement control(String id) =>
        browser.child.document.getElementById(id)! as web.HTMLElement;

    test('moves only the owner video and restores it when exiting', () async {
      expect(await pip.enterPipMode(7, width: 480, height: 270), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(await pip.isInPipMode(), isTrue);
      expect(video.ownerDocument, browser.child.document);
      expect(host.textContent, contains('Picture in Picture'));
      expect(events.single.playerId, 7);
      expect(events.single.isInPip, isTrue);
      expect(
        browser.lastOptions!.getProperty<JSNumber>('width'.toJS).toDartInt,
        480,
      );
      expect(
        browser.lastOptions!
            .getProperty<JSBoolean>('disallowReturnToOpener'.toJS)
            .toDart,
        isTrue,
      );
      await pip.exitPipMode();
      await Future<void>.delayed(Duration.zero);
      expect(video.parentElement, host);
      expect(host.querySelector('.video-player-pip-placeholder'), isNull);
      expect(await pip.isInPipMode(), isFalse);
      expect(events.last.isInPip, isFalse);
    });

    test(
      'skip buttons, play toggle and timeline update the same media element',
      () async {
        expect(await pip.enterPipMode(7), isTrue);
        control('vpc-pip-backward').click();
        expect(video.currentTime, 10);
        control('vpc-pip-forward').click();
        expect(video.currentTime, 20);
        control('vpc-pip-play').click();
        expect(video.paused, isFalse);
        expect(control('vpc-pip-play').getAttribute('aria-label'), 'Pause');
        control('vpc-pip-play').click();
        expect(video.paused, isTrue);
        final range = control('vpc-pip-seek') as web.HTMLInputElement;
        range.value = '72.5';
        range.dispatchEvent(web.Event('input'));
        expect(video.currentTime, 72.5);
        expect(control('vpc-pip-time').textContent, contains('1:12'));
        video.currentTime = 3;
        control('vpc-pip-backward').click();
        expect(video.currentTime, 0);
        video.currentTime = 117;
        control('vpc-pip-forward').click();
        expect(video.currentTime, 120);
      },
    );

    test(
      'hover keeps controls visible and leaving hides them after a delay',
      () async {
        expect(await pip.enterPipMode(7), isTrue);
        final root = control('vpc-pip-root');
        final overlay = control('vpc-pip-controls');
        root.dispatchEvent(web.Event('pointerenter'));
        await Future<void>.delayed(const Duration(milliseconds: 2700));
        expect(overlay.getAttribute('data-visible'), 'true');
        root.dispatchEvent(web.Event('pointerleave'));
        expect(overlay.getAttribute('data-visible'), 'true');
        await Future<void>.delayed(const Duration(milliseconds: 2700));
        expect(overlay.getAttribute('data-visible'), 'false');
        root.dispatchEvent(web.Event('pointermove'));
        expect(overlay.getAttribute('data-visible'), 'true');
      },
    );

    test(
      'restore reports the current position and stops the floating session',
      () async {
        expect(await pip.enterPipMode(7), isTrue);
        video.currentTime = 37.25;
        control('vpc-pip-restore').click();
        await Future<void>.delayed(Duration.zero);
        expect(events.last.isRestored, isTrue);
        expect(events.last.positionMs, 37250);
        expect(events.last.isInPip, isFalse);
        expect(video.parentElement, host);
        expect(video.paused, isTrue);
        expect(browser.closes, 1);
      },
    );

    test('disposing a different player preserves the active owner', () async {
      expect(await pip.enterPipMode(7), isTrue);
      pip.playerDisposed(99);
      expect(await pip.isInPipMode(), isTrue);
      pip.playerDisposed(7);
      await Future<void>.delayed(Duration.zero);
      expect(await pip.isInPipMode(), isFalse);
      expect(video.parentElement, host);
      expect(browser.closes, 1);
    });
  });

  group('native browser track APIs', () {
    test('absent audio and video APIs expose no invented tracks', () {
      final video = web.HTMLVideoElement();
      video.setProperty('audioTracks'.toJS, null);
      video.setProperty('videoTracks'.toJS, null);
      expect(tracks.getAudioTracks(video), isEmpty);
      expect(tracks.getVideoTracks(video), isEmpty);
      expect(
        () => tracks.selectAudioTrack(video, 'missing'),
        throwsUnsupportedError,
      );
      expect(
        () => tracks.selectVideoTrack(
          video,
          const platform.VideoTrack(id: 'missing', isSelected: false),
        ),
        throwsUnsupportedError,
      );
    });

    test(
      'native audio selection validates IDs before changing enabled tracks',
      () {
        final video = _eval(
          r'''
        (() => {
          const video = document.createElement('video');
          Object.defineProperty(video, 'audioTracks', {value: [
            {id: 'en', label: 'English', language: 'en', enabled: true},
            {id: 'es', label: 'Español', language: 'es', enabled: false},
            {id: '', label: '', language: '', enabled: false},
            {id: 'web-track-2', label: '', language: '', enabled: false},
            {id: 'duplicate', label: '', language: '', enabled: false},
            {id: 'duplicate', label: '', language: '', enabled: false}
          ]});
          return video;
        })()
      '''
              .toJS,
        ) as web.HTMLVideoElement;
        final available = tracks.getAudioTracks(video);
        expect(available.map((track) => track.id).toSet(), hasLength(6));
        expect(available.first.language, 'en');
        expect(available[2].label, isNull);
        tracks.selectAudioTrack(video, 'es');
        expect(
          tracks
              .getAudioTracks(video)
              .where((track) => track.isSelected)
              .single
              .id,
          'es',
        );
        expect(
          () => tracks.selectAudioTrack(video, 'missing'),
          throwsArgumentError,
        );
        expect(
          tracks
              .getAudioTracks(video)
              .where((track) => track.isSelected)
              .single
              .id,
          'es',
        );
      },
    );

    test('explicit video selection leaves adaptive metadata unavailable', () {
      final video = _eval(
        r'''
        (() => {
          const video = document.createElement('video');
          let selected = 0;
          const items = ['main', 'alternative'].map((id, index) => ({
            id, label: id,
            get selected() {return selected === index;},
            set selected(value) {if(value) selected = index;}
          }));
          Object.defineProperty(video, 'videoTracks', {value: items});
          return video;
        })()
      '''
            .toJS,
      ) as web.HTMLVideoElement;
      final available = tracks.getVideoTracks(video);
      expect(available.first.width, isNull);
      expect(available.first.height, isNull);
      expect(available.first.bitrate, isNull);
      tracks.selectVideoTrack(video, available.last);
      expect(
        tracks
            .getVideoTracks(video)
            .where((track) => track.isSelected)
            .single
            .id,
        'alternative',
      );
      expect(
        () => tracks.selectVideoTrack(video, null),
        throwsUnsupportedError,
      );
      expect(
        () => tracks.selectVideoTrack(
          video,
          const platform.VideoTrack(id: 'missing', isSelected: false),
        ),
        throwsArgumentError,
      );
      expect(
        tracks
            .getVideoTracks(video)
            .where((track) => track.isSelected)
            .single
            .id,
        'alternative',
      );
    });
  });

  group('native browser PiP', () {
    late web.HTMLVideoElement video;
    late web.HTMLDivElement host;
    late WebVideoPlayerPip pip;
    late List<VideoPlayerPipPlatformEvent> events;
    late StreamSubscription<VideoPlayerPipPlatformEvent> subscription;

    setUp(() {
      video = _controlledVideo();
      host = web.HTMLDivElement()..appendChild(video);
      web.document.body!.appendChild(host);
      events = [];
      pip = WebVideoPlayerPip(
        resolveVideo: (id) => id == 7 ? video : null,
        resolveHost: (id) => id == 7 ? host : null,
      );
      subscription = pip.events.listen(events.add);
    });

    tearDown(() async {
      await pip.dispose();
      await subscription.cancel();
      host.remove();
    });

    test(
      'native video PiP takes priority over Document PiP and preserves playback on exit',
      () async {
        final documentBrowser = _DocumentPipMock(disableNative: false);
        _mockNativePipApi(document: documentBrowser.context.document);
        await pip.dispose();
        await subscription.cancel();
        pip = WebVideoPlayerPip(
          resolveVideo: (id) => id == 7 ? video : null,
          resolveHost: (id) => id == 7 ? host : null,
          browsingWindow: documentBrowser.context,
        );
        subscription = pip.events.listen(events.add);
        try {
          await video.play().toDart;
          expect(await pip.enterPipMode(7, width: 480, height: 270), isTrue);
          await Future<void>.delayed(Duration.zero);
          expect(documentBrowser.lastOptions, isNull);
          expect(
            documentBrowser.context.document.pictureInPictureElement,
            video,
          );
          expect(video.ownerDocument, web.document);
          expect(video.style.visibility, 'hidden');
          expect(events.where((event) => event.isInPip), hasLength(1));
          expect(await pip.exitPipMode(), isTrue);
          await Future<void>.delayed(Duration.zero);
          expect(await pip.isInPipMode(), isFalse);
          expect(video.style.visibility, isEmpty);
          expect(video.paused, isFalse);
          expect(events.where((event) => !event.isInPip), hasLength(1));
        } finally {
          await pip.dispose();
          documentBrowser.dispose();
        }
      },
    );

    test(
      'native video PiP tracks external browser entry and close exactly once',
      () async {
        _mockNativePipApi();
        pip.playerCreated(7);
        await video.play().toDart;
        await video.requestPictureInPicture().toDart;
        await Future<void>.delayed(Duration.zero);
        expect(await pip.isInPipMode(), isTrue);
        expect(events.where((event) => event.isInPip), hasLength(1));
        expect(video.style.visibility, 'hidden');
        expect(host.textContent, contains('Picture in Picture'));
        await web.document.exitPictureInPicture().toDart;
        await Future<void>.delayed(Duration.zero);
        expect(await pip.isInPipMode(), isFalse);
        expect(events.where((event) => !event.isInPip), hasLength(1));
        expect(video.style.visibility, isEmpty);
        expect(video.paused, isTrue);
        expect(host.querySelector('.video-player-pip-placeholder'), isNull);
      },
    );

    test('Safari presentation mode hides inline video and preserves playback on programmatic exit', () async {
      _mockSafariPipApi(video);
      pip.playerCreated(7);
      expect(await pip.isPipSupported(), isTrue);
      await video.play().toDart;
      expect(await pip.enterPipMode(7), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        video.getProperty<JSString>('webkitPresentationMode'.toJS).toDart,
        'picture-in-picture',
      );
      expect(video.style.visibility, 'hidden');
      expect(events.where((event) => event.isInPip), hasLength(1));
      expect(await pip.exitPipMode(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        video.getProperty<JSString>('webkitPresentationMode'.toJS).toDart,
        'inline',
      );
      expect(video.style.visibility, isEmpty);
      expect(video.paused, isFalse);
      expect(events.where((event) => !event.isInPip), hasLength(1));
    });

    test('denied native PiP emits a typed error and leaves the inline video intact', () async {
      _mockNativePipApi();
      video.setProperty(
        'requestPictureInPicture'.toJS,
        _eval(
          "(() => Promise.reject(new DOMException('Click required', 'NotAllowedError')))"
              .toJS,
        ),
      );
      expect(await pip.enterPipMode(7), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(await pip.isInPipMode(), isFalse);
      expect(events, hasLength(1));
      expect(events.single.playerId, 7);
      expect(events.single.isInPip, isFalse);
      expect(events.single.error, contains('NotAllowedError: Click required'));
      expect(video.parentElement, host);
      expect(video.style.visibility, isEmpty);
      expect(host.querySelector('.video-player-pip-placeholder'), isNull);
    });
  });

  group('browser screen wake lock', () {
    late web.HTMLVideoElement video;
    late BrowserVideoWakeLock lock;
    late List<JSObject> sentinels;
    late Completer<web.WakeLockSentinel>? pending;

    setUp(() {
      video = _controlledVideo();
      web.document.body!.appendChild(video);
      final navigator = web.document.defaultView!.navigator;
      sentinels = [];
      pending = null;
      final api = JSObject();
      api.setProperty(
        'request'.toJS,
        ((JSString type) {
          expect(type.toDart, 'screen');
          final sentinel = _eval(
            r'''(() => {
          const sentinel = new EventTarget();
          sentinel.released = false;
          sentinel.release = () => {
            sentinel.released = true;
            sentinel.dispatchEvent(new Event('release'));
            return Promise.resolve();
          };
          return sentinel;
        })()'''
                .toJS,
          ) as web.WakeLockSentinel;
          sentinels.add(sentinel);
          return pending?.future.toJS ??
              Future<web.WakeLockSentinel>.value(sentinel).toJS;
        }).toJS,
      );
      navigator.setProperty('__vpcWakeLockApi'.toJS, api);
      _eval(
        r'''
        globalThis.__vpcWakeLockDescriptor = Object.getOwnPropertyDescriptor(navigator, 'wakeLock');
        Object.defineProperty(navigator, 'wakeLock', {value: navigator.__vpcWakeLockApi, configurable: true});
      '''
            .toJS,
      );
      lock = BrowserVideoWakeLock(video);
    });

    tearDown(() {
      lock.dispose();
      _eval(
        r'''
        if(globalThis.__vpcWakeLockDescriptor) Object.defineProperty(navigator, 'wakeLock', globalThis.__vpcWakeLockDescriptor);
        else delete navigator.wakeLock;
        delete navigator.__vpcWakeLockApi;
        delete globalThis.__vpcWakeLockDescriptor;
      '''
            .toJS,
      );
      video.remove();
    });

    bool released(int index) =>
        sentinels[index].getProperty<JSBoolean>('released'.toJS).toDart;

    test(
      'acquires while playing and releases on pause, disable and dispose',
      () async {
        expect(sentinels, isEmpty);
        await video.play().toDart;
        await Future<void>.delayed(Duration.zero);
        expect(sentinels, hasLength(1));
        expect(released(0), isFalse);
        video.pause();
        await Future<void>.delayed(Duration.zero);
        expect(released(0), isTrue);
        await video.play().toDart;
        await Future<void>.delayed(Duration.zero);
        expect(sentinels, hasLength(2));
        lock.setEnabled(false);
        await Future<void>.delayed(Duration.zero);
        expect(released(1), isTrue);
        lock.setEnabled(true);
        await Future<void>.delayed(Duration.zero);
        expect(sentinels, hasLength(3));
        lock.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(released(2), isTrue);
      },
    );

    test('a late grant after pausing is immediately released', () async {
      pending = Completer<web.WakeLockSentinel>();
      await video.play().toDart;
      await Future<void>.delayed(Duration.zero);
      expect(sentinels, hasLength(1));
      video.pause();
      pending!.complete(sentinels.single as web.WakeLockSentinel);
      await Future<void>.delayed(Duration.zero);
      expect(released(0), isTrue);
    });
  });

  test('registered public controller reuses persisted source offline and receives paused seeks', () async {
    VideoPlayerCustomWeb.registerWith(webPluginRegistrar);
    final backend =
        platform.VideoPlayerPlatform.instance as VideoPlayerCustomWeb;
    final previousCache = WebVideoPlayerCache.instance;
    final cache = WebVideoPlayerCache(
      namespace: 'vpc_public_test_${DateTime.now().microsecondsSinceEpoch}',
    );
    WebVideoPlayerCache.instance = cache;
    const source = 'https://media.test/public-controller.webm';
    final network = _FetchStub((_) => _response(fixture));
    await cache.prefetch(source, cacheKey: 'public-controller');
    network.restore();
    final offline = _FetchStub((_) => throw StateError('Network offline'));
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(source),
      cacheKey: 'public-controller',
    );
    addTearDown(() async {
      await controller.dispose();
      await backend.pip.dispose();
      offline.restore();
      WebVideoPlayerCache.instance = previousCache;
      await cache.clear();
      cache.dispose();
    });
    await controller.initialize();
    expect(controller.value.isInitialized, isTrue);
    expect(controller.value.size.width, 32);
    await controller.setVolume(0);
    await controller.play();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await controller.pause();
    await backend.seekTo(
      controller.playerId,
      const Duration(milliseconds: 300),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(controller.value.isPlaying, isFalse);
    expect(controller.value.position.inMilliseconds, closeTo(300, 35));
    expect(controller.value.isCompleted, isFalse);
    expect(offline.requests, isEmpty);

    _mockNativePipApi();
    final modes = <PipModeChanged>[];
    final subscription = VideoPlayerPip.instance.onPipModeChanged.listen(
      modes.add,
    );
    addTearDown(() async {
      await subscription.cancel();
      VideoPlayerPip.instance.dispose();
    });
    expect(await VideoPlayerPip.enterPipMode(controller), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(modes.where((event) => event.isInPip), hasLength(1));
    expect(modes.single.playerId, controller.playerId);
    final sameVideo = web.window.getProperty<web.HTMLVideoElement>(
      '__vpcNativeVideo'.toJS,
    );
    expect(sameVideo.src, startsWith('blob:'));
    expect(sameVideo.style.visibility, 'hidden');
    expect(await VideoPlayerPip.isInPipMode(), isTrue);
    expect(await VideoPlayerPip.exitPipMode(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(modes.where((event) => !event.isInPip), hasLength(1));
    expect(sameVideo.style.visibility, isEmpty);
    expect(await VideoPlayerPip.isInPipMode(), isFalse);

    // Document PiP's explicit restore event also reaches the public typed API.
    final documentBrowser = _DocumentPipMock();
    final publicHost = sameVideo.parentElement! as web.HTMLElement;
    final documentPip = WebVideoPlayerPip(
      resolveVideo: (id) => id == controller.playerId ? sameVideo : null,
      resolveHost: (id) => id == controller.playerId ? publicHost : null,
      browsingWindow: documentBrowser.context,
    );
    VideoPlayerPipPlatform.instance = documentPip;
    addTearDown(() async {
      await documentPip.dispose();
      VideoPlayerPipPlatform.instance = backend.pip;
      documentBrowser.dispose();
    });
    expect(await VideoPlayerPip.enterPipMode(controller), isTrue);
    await Future<void>.delayed(Duration.zero);
    // An ordinary iframe may reload adopted media; it is only a DOM mock of a
    // privileged Document PiP window. Verify reporting from its current clock.
    if (sameVideo.readyState < 2) await _event(sameVideo, 'loadeddata');
    final restoredSeek = _event(sameVideo, 'seeked');
    sameVideo.currentTime = 0.3;
    await restoredSeek;
    (documentBrowser.child.document.getElementById('vpc-pip-restore')!
            as web.HTMLElement)
        .click();
    await Future<void>.delayed(Duration.zero);
    final restored = modes.singleWhere((event) => event.isRestored);
    expect(restored.playerId, controller.playerId);
    expect(restored.isInPip, isFalse);
    expect(restored.position!.inMilliseconds, closeTo(300, 35));
    expect(await VideoPlayerPip.isInPipMode(), isFalse);
  });
}
