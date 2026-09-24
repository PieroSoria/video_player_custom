import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_custom/src/cache/video_player_cache.dart';

void main() {
  late Directory tempDir;
  late VideoPlayerCache cache;
  late _RecordingPlatform fakePlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_test_');
    cache = VideoPlayerCache(tempDir);
    VideoPlayerCache.instance = cache;
    fakePlatform = _RecordingPlatform();
    VideoPlayerPlatform.instance = fakePlatform;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<HttpServer> serve(List<int> body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.binary
        ..add(body);
      request.response.close();
    }, onError: (_) {});
    return server;
  }

  String uri(HttpServer server, {String path = '/media/clip.mp4'}) =>
      'http://${server.address.address}:${server.port}$path';

  Future<HlsFixture> serveHls() async {
    final List<int> seg1 = Uint8List.fromList(utf8.encode('segment-one'));
    final List<int> seg2 = Uint8List.fromList(utf8.encode('segment-two'));
    final String master = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
/media/variant.m3u8
''';
    final String variant = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="/keys/token.key"
#EXTINF:10.0,
/media/seg1.ts
#EXTINF:10.0,
/media/seg2.ts
#EXT-X-ENDLIST
''';
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      switch (request.uri.path) {
        case '/media/master.m3u8':
          request.response.write(master);
        case '/media/variant.m3u8':
          request.response.write(variant);
        case '/keys/token.key':
          request.response.write('{"kty":"oct","k":"aGVsbG8ta2V5"}');
        case '/media/seg1.ts':
          request.response.add(seg1);
        case '/media/seg2.ts':
          request.response.add(seg2);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.close();
    }, onError: (_) {});
    return HlsFixture(
      server: server,
      masterUrl: uri(server, path: '/media/master.m3u8'),
      segments: <List<int>>[seg1, seg2],
    );
  }

  Future<DashFixture> serveDash() async {
    final List<int> init = Uint8List.fromList(utf8.encode('mp4-init'));
    final List<int> seg1 = Uint8List.fromList(utf8.encode('segment-one'));
    final List<int> seg2 = Uint8List.fromList(utf8.encode('segment-two'));
    final String mpd = '''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
  mediaPresentationDuration="PT6S" minBufferTime="PT1S"
  profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
  <Period>
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
      <Representation id="v1" mimeType="video/mp4" codecs="avc1.64001f"
        bandwidth="500000" width="1280" height="720">
        <SegmentTemplate timescale="1" duration="3" startNumber="1"
          media="/seg/v1_\$Number\$.m4s" initialization="/seg/v1_init.mp4"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      switch (request.uri.path) {
        case '/media/master.mpd':
          request.response.write(mpd);
        case '/seg/v1_1.m4s':
          request.response.add(seg1);
        case '/seg/v1_2.m4s':
          request.response.add(seg2);
        case '/seg/v1_init.mp4':
          request.response.add(init);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.close();
    }, onError: (_) {});
    return DashFixture(
      server: server,
      masterUrl: uri(server, path: '/media/master.mpd'),
      segments: <List<int>>[seg1, seg2],
    );
  }

  Future<SmoothStreamingFixture> serveSmooth() async {
    final List<int> video1 =
        Uint8List.fromList(utf8.encode('video-fragment-1'));
    final List<int> video2 =
        Uint8List.fromList(utf8.encode('video-fragment-2'));
    final List<int> audio1 =
        Uint8List.fromList(utf8.encode('audio-fragment-1'));
    final List<int> audio2 =
        Uint8List.fromList(utf8.encode('audio-fragment-2'));
    final String manifest = '''<SmoothStreamingMedia MajorVersion="2"
  MinorVersion="1" Duration="6666666" TimeScale="10000000">
  <StreamIndex Type="video" Chunks="2" TimeScale="10000000"
    Url="QualityLevels({bitrate})/Fragments(video={start time})">
    <QualityLevel Index="0" Bitrate="500000" FourCC="H264" Width="1280" Height="720"/>
    <c t="0" d="3333333"/>
    <c t="3333333" d="3333333"/>
  </StreamIndex>
  <StreamIndex Type="audio" Chunks="2" TimeScale="10000000"
    Url="QualityLevels({bitrate})/Fragments(audio={start time})">
    <QualityLevel Index="0" Bitrate="128000" FourCC="AACL"/>
    <c t="0" d="3333333"/>
    <c t="3333333" d="3333333"/>
  </StreamIndex>
</SmoothStreamingMedia>''';
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      switch (request.uri.path) {
        case '/Manifest':
          request.response.write(manifest);
        case '/QualityLevels(500000)/Fragments(video=0)':
          request.response.add(video1);
        case '/QualityLevels(500000)/Fragments(video=3333333)':
          request.response.add(video2);
        case '/QualityLevels(128000)/Fragments(audio=0)':
          request.response.add(audio1);
        case '/QualityLevels(128000)/Fragments(audio=3333333)':
          request.response.add(audio2);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.close();
    }, onError: (_) {});
    return SmoothStreamingFixture(
      server: server,
      masterUrl: uri(server, path: '/Manifest'),
      videoFragments: <List<int>>[video1, video2],
      audioFragments: <List<int>>[audio1, audio2],
    );
  }

  test('prefetch downloads to disk and reuses the entry', () async {
    final body = Uint8List.fromList(utf8.encode('fake-mp4-bytes'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    expect(await cache.have(url, cacheKey: 'alpha'), isFalse);
    await cache.prefetch(url, cacheKey: 'alpha');
    expect(await cache.have(url, cacheKey: 'alpha'), isTrue);

    final file = await cache.fileFor(url, cacheKey: 'alpha');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), body);

    // A second prefetch does not re-download (the file already exists).
    await cache.prefetch(url, cacheKey: 'alpha');
    expect(await cache.fileFor(url, cacheKey: 'alpha'), isNotNull);
  });

  test('prefetch forwards http headers to the server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? receivedToken;
    server.listen((request) {
      receivedToken = request.headers.value('x-token');
      request.response
        ..add(List<int>.filled(8, 1))
        ..close();
    }, onError: (_) {});
    addTearDown(server.close);

    await cache.prefetch(
      uri(server),
      cacheKey: 'headers',
      headers: const <String, String>{'x-token': 'abc123'},
    );
    expect(receivedToken, 'abc123');
  });

  test('download failure leaves no partial file behind', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    }, onError: (_) {});
    addTearDown(server.close);

    await expectLater(
      cache.prefetch(uri(server), cacheKey: 'broken'),
      throwsA(isA<HttpException>()),
    );
    expect(await cache.have(uri(server), cacheKey: 'broken'), isFalse);
    final leftovers = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });

  test('concurrent prefetches of the same entry share one download', () async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      hits++;
      request.response
        ..headers.contentType = ContentType.binary
        ..add(List<int>.filled(8 * 1024, 7));
      request.response.close();
    }, onError: (_) {});
    addTearDown(server.close);
    final url = uri(server);

    await Future.wait([
      cache.prefetch(url, cacheKey: 'shared'),
      cache.prefetch(url, cacheKey: 'shared'),
      cache.prefetch(url, cacheKey: 'shared'),
    ]);
    expect(hits, 1);
  });

  test('LRU eviction removes the oldest entry over the limit', () async {
    final server = await serve(List<int>.filled(1024, 1));
    addTearDown(server.close);
    final url = uri(server);

    final small = VideoPlayerCache(tempDir, maxCacheSizeBytes: 2048);
    await small.prefetch(url, cacheKey: 'first');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await small.prefetch(url, cacheKey: 'second');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await small.prefetch(url, cacheKey: 'third');

    expect(await small.have(url, cacheKey: 'third'), isTrue);
    expect(await small.have(url, cacheKey: 'second'), isTrue);
    // Oldest entry was evicted to stay under the 2 KiB budget (3 x 1 KiB).
    expect(await small.have(url, cacheKey: 'first'), isFalse);
  });

  test('hash-derived key is stable and extension is preserved', () async {
    final body = Uint8List.fromList(utf8.encode('x'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    await cache.prefetch(url);
    final byHash = await cache.fileFor(url);
    expect(byHash, isNotNull);
    expect(byHash!.path, endsWith('.mp4'), reason: 'keeps the .mp4 suffix');

    final again = await cache.fileFor(url);
    expect(again!.path, byHash.path, reason: 'same hash every time');
  });

  test('initialize() uses the cached local file when one exists', () async {
    final body = Uint8List.fromList(utf8.encode('cached-video'));
    final server = await serve(body);
    addTearDown(server.close);
    final url = uri(server);

    // Prime the cache first.
    await cache.prefetch(url, cacheKey: 'mine');
    final cachedFile = await cache.fileFor(url, cacheKey: 'mine');

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      cacheKey: 'mine',
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    await controller.dispose();

    expect(fakePlatform.dataSources, isNotEmpty);
    final sent = fakePlatform.dataSources.last;
    expect(sent.uri, cachedFile!.uri.toString());
    expect(sent.httpHeaders, isEmpty);
  });

  test('initialize() streams from the network and prefetches on a miss',
      () async {
    final server = await serve(List<int>.filled(64, 1));
    addTearDown(server.close);
    final url = uri(server);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      cacheKey: 'cold',
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    // Playback used the network URL itself, with headers passed through.
    expect(fakePlatform.dataSources.last.uri, url);
    // The background prefetch completes on its own.
    await cache.warm(url, cacheKey: 'cold');
    expect(await cache.have(url, cacheKey: 'cold'), isTrue);
    await controller.dispose();
  });

  test('live sources stream from the network and never write to the cache',
      () async {
    final server = await serve(List<int>.filled(64, 1));
    addTearDown(server.close);
    final url = uri(server);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      cacheKey: 'live',
      isLive: true,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    // Playback used the network URL itself.
    expect(fakePlatform.dataSources.last.uri, url);
    // Give a (suppressed) background prefetch time to run, then assert that
    // nothing was written to the cache.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await cache.have(url, cacheKey: 'live'), isFalse);
    await controller.dispose();
  });

  test('HLS prefetch downloads playlists, segments and keys locally',
      () async {
    final HlsFixture fixture = await serveHls();
    addTearDown(fixture.server.close);

    expect(
      await cache.have(
        fixture.masterUrl,
        cacheKey: 'show',
        formatHint: VideoFormat.hls,
      ),
      isFalse,
    );
    await cache.prefetch(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );

    final File? master = await cache.fileFor(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );
    expect(master, isNotNull);
    final String localMaster = await master!.readAsString();
    expect(localMaster, isNot(contains(fixture.server.address.address)),
        reason: 'rewritten master points to local files');
    expect(localMaster, isNot(contains('/media/')));

    // The variant playlist and both segments were downloaded onto disk.
    final Directory entry = Directory('${tempDir.path}/show');
    expect(await entry.exists(), isTrue);
    final List<String> names = await entry
        .list()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    expect(names, contains('master.m3u8'));
    expect(names, anyElement(endsWith('.ts')));
    expect(names, anyElement(endsWith('.m3u8')));
    final File segment = entry
        .listSync()
        .firstWhere((FileSystemEntity e) => e.path.endsWith('.ts')) as File;
    expect(await segment.readAsBytes(), fixture.segments.first);
  });

  test('initialize() plays a cached HLS presentation from local files',
      () async {
    final HlsFixture fixture = await serveHls();
    addTearDown(fixture.server.close);

    // First open: streaming + background download.
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    expect(fakePlatform.dataSources.last.uri, fixture.masterUrl);
    expect(fakePlatform.dataSources.last.formatHint, VideoFormat.hls);
    await cache.warm(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );
    expect(
      await cache.have(
        fixture.masterUrl,
        cacheKey: 'show',
        formatHint: VideoFormat.hls,
      ),
      isTrue,
    );
    await controller.dispose();

    // Second open: the local rewritten master is used, not the network.
    final controller2 = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller2.initialize();
    final DataSource sent = fakePlatform.dataSources.last;
    expect(sent.uri, startsWith('file:'), reason: 'cached local HLS used');
    expect(sent.uri, endsWith('/show/master.m3u8'));
    expect(sent.httpHeaders, isEmpty);
    await controller2.dispose();
  });

  test('cached HLS manifest is served over the loopback HTTP server',
      () async {
    final HlsFixture fixture = await serveHls();
    addTearDown(fixture.server.close);
    await cache.prefetch(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );

    final Uri? served = await cache.serveManifestHttp(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );
    expect(served, isNotNull);
    expect(served!.host, '127.0.0.1');
    expect(served.path, endsWith('/show/master.m3u8'));

    final File? masterFile = await cache.fileFor(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );
    final String localMaster = await masterFile!.readAsString();

    final HttpClient client = HttpClient();
    addTearDown(client.close);

    // The master playlist is served with the Apple mpegurl content type and
    // identical bytes to the cached file.
    final HttpClientResponse masterResponse =
        await (await client.getUrl(served)).close();
    expect(masterResponse.statusCode, HttpStatus.ok);
    expect(
        masterResponse.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl');
    expect(await masterResponse.transform(utf8.decoder).join(), localMaster);

    // The referenced variant playlist resolves through the server too.
    final String variantName = localMaster
        .split('\n')
        .firstWhere((String l) => l.isNotEmpty && !l.startsWith('#'));
    final String servedVariant =
        await (await client.getUrl(served.resolve(variantName))).close().then(
              (HttpClientResponse r) async =>
                  await r.transform(utf8.decoder).join(),
            );
    expect(servedVariant, startsWith('#EXTM3U'));
    expect(servedVariant, isNot(contains('/media/')));

    // A TS segment is served with the exact bytes of the downloaded file.
    final String segmentName = servedVariant
        .split('\n')
        .firstWhere((String l) =>
            l.isNotEmpty && !l.startsWith('#') && l.endsWith('.ts'));
    final List<int> segmentBytes =
        await (await client.getUrl(served.resolve(variantName).resolve(segmentName)))
            .close()
            .then((HttpClientResponse r) async => await r.fold<List<int>>(
                <int>[], (List<int> a, List<int> b) => a..addAll(b)));
    expect(segmentBytes, fixture.segments.first);

    // Partial requests return 206 with the requested slice.
    final HttpClientRequest rangeRequest = await client.getUrl(served);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-9');
    final HttpClientResponse rangeResponse = await rangeRequest.close();
    expect(rangeResponse.statusCode, HttpStatus.partialContent);
    expect(
      await rangeResponse.transform(utf8.decoder).join(),
      localMaster.substring(0, 10),
    );
  });

  test('HLS forward buffer is derived from the rewritten segment duration',
      () async {
    final HlsFixture fixture = await serveHls();
    addTearDown(fixture.server.close);
    await cache.prefetch(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );

    final File? master = await cache.fileFor(
      fixture.masterUrl,
      cacheKey: 'show',
      formatHint: VideoFormat.hls,
    );
    // The rewritten master has no EXT-X-TARGETDURATION, so the value is read
    // from the referenced (rewritten) variant playlist: 10 seconds.
    expect(
      await VideoPlayerCache.hlsTargetDurationSeconds(master!),
      10.0,
    );

    // A master declaring the value directly returns it immediately.
    final Directory directDir = Directory('${tempDir.path}/direct');
    await directDir.create(recursive: true);
    final File direct = File('${directDir.path}/master.m3u8');
    await direct.writeAsString('''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg.ts
''');
    expect(await VideoPlayerCache.hlsTargetDurationSeconds(direct), 4.0);

    // A non-HLS file reports no target duration.
    final File notHls = File('${directDir.path}/not.m3u8');
    await notHls.writeAsString('just bytes');
    expect(await VideoPlayerCache.hlsTargetDurationSeconds(notHls), isNull);
  });

  test('DASH prefetch downloads segments and rewrites the manifest to'
      ' local files', () async {
    final DashFixture fixture = await serveDash();
    addTearDown(fixture.server.close);

    expect(
      await cache.have(
        fixture.masterUrl,
        cacheKey: 'film',
        formatHint: VideoFormat.dash,
      ),
      isFalse,
    );
    await cache.prefetch(
      fixture.masterUrl,
      cacheKey: 'film',
      formatHint: VideoFormat.dash,
    );

    final File? master = await cache.fileFor(
      fixture.masterUrl,
      cacheKey: 'film',
      formatHint: VideoFormat.dash,
    );
    expect(master, isNotNull);
    final String localManifest = await master!.readAsString();
    expect(localManifest, isNot(contains('/seg/')),
        reason: 'rewritten manifest points at local files');
    expect(localManifest, contains('<SegmentURL media="e'));

    final Directory entry = Directory('${tempDir.path}/film');
    final List<String> names = await entry
        .list()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    expect(names, contains('master.mpd'));
    expect(names.where((String n) => n.endsWith('.m4s')), hasLength(2));
    expect(names.where((String n) => n.startsWith('init')), hasLength(1));
    final File segment =
        entry.listSync().firstWhere((FileSystemEntity e) => e.path.endsWith('.m4s'))
            as File;
    expect(await segment.readAsBytes(), fixture.segments.first);
  });

  test('initialize() plays a cached DASH presentation from local files',
      () async {
    final DashFixture fixture = await serveDash();
    addTearDown(fixture.server.close);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'film',
      formatHint: VideoFormat.dash,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    expect(fakePlatform.dataSources.last.uri, fixture.masterUrl);
    await cache.warm(fixture.masterUrl,
        cacheKey: 'film', formatHint: VideoFormat.dash);
    await controller.dispose();

    final controller2 = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'film',
      formatHint: VideoFormat.dash,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller2.initialize();
    final DataSource sent = fakePlatform.dataSources.last;
    expect(sent.uri, startsWith('file:'), reason: 'cached local DASH used');
    expect(sent.uri, endsWith('/film/master.mpd'));
    expect(sent.httpHeaders, isEmpty);
    await controller2.dispose();
  });

  test('Smooth Streaming prefetch downloads fragments and rewrites the'
      ' manifest to local files', () async {
    final SmoothStreamingFixture fixture = await serveSmooth();
    addTearDown(fixture.server.close);

    await cache.prefetch(
      fixture.masterUrl,
      cacheKey: 'smooth',
      formatHint: VideoFormat.ss,
    );

    final File? master = await cache.fileFor(
      fixture.masterUrl,
      cacheKey: 'smooth',
      formatHint: VideoFormat.ss,
    );
    expect(master, isNotNull);
    final String localManifest = await master!.readAsString();
    expect(localManifest, isNot(contains('QualityLevels(')),
        reason: 'template rewritten to local names');
    expect(localManifest, contains('Url="v{bitrate}_{start time}.ismv"'));
    expect(localManifest, contains('Url="a{bitrate}_{start time}.isma"'));

    final Directory entry = Directory('${tempDir.path}/smooth');
    final List<String> names = await entry
        .list()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    expect(names, contains('master.ism'));
    expect(names, contains('v500000_0.ismv'));
    expect(names, contains('v500000_3333333.ismv'));
    expect(names, contains('a128000_0.isma'));
    expect(names, contains('a128000_3333333.isma'));
    final File fragment = entry
        .listSync()
        .firstWhere((FileSystemEntity e) => e.path == '${entry.path}${Platform.pathSeparator}v500000_0.ismv')
        as File;
    expect(await fragment.readAsBytes(), fixture.videoFragments.first);
  });

  test('initialize() plays a cached Smooth Streaming presentation from'
      ' local files', () async {
    final SmoothStreamingFixture fixture = await serveSmooth();
    addTearDown(fixture.server.close);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'smooth',
      formatHint: VideoFormat.ss,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller.initialize();
    expect(fakePlatform.dataSources.last.uri, fixture.masterUrl);
    await cache.warm(fixture.masterUrl,
        cacheKey: 'smooth', formatHint: VideoFormat.ss);
    await controller.dispose();

    final controller2 = VideoPlayerController.networkUrl(
      Uri.parse(fixture.masterUrl),
      cacheKey: 'smooth',
      formatHint: VideoFormat.ss,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
    );
    await controller2.initialize();
    final DataSource sent = fakePlatform.dataSources.last;
    expect(sent.uri, startsWith('file:'), reason: 'cached local SS used');
    expect(sent.uri, endsWith('/smooth/master.ism'));
    expect(sent.httpHeaders, isEmpty);
    await controller2.dispose();
  });

  test('live DASH and Smooth Streaming manifests are never cached', () async {
    final List<(List<int>, VideoFormat)> cases = <(List<int>, VideoFormat)>[
      (
        Uint8List.fromList(utf8.encode(
            '<MPD type="dynamic"><Period/></MPD>')),
        VideoFormat.dash,
      ),
      (
        Uint8List.fromList(utf8.encode(
            '<SmoothStreamingMedia IsLive="true"><StreamIndex Type="video"><c t="0" d="1"/></StreamIndex></SmoothStreamingMedia>')),
        VideoFormat.ss,
      ),
    ];
    for (final (List<int> body, VideoFormat format) in cases) {
      final HttpServer server = await serve(body);
      addTearDown(server.close);
      final String url = uri(server);
      await expectLater(
        cache.prefetch(url, cacheKey: 'live', formatHint: format),
        throwsA(isA<FormatException>()),
      );
      expect(await cache.have(url, cacheKey: 'live', formatHint: format),
          isFalse);
    }
  });
}

class HlsFixture {
  HlsFixture({
    required this.server,
    required this.masterUrl,
    required this.segments,
  });

  final HttpServer server;
  final String masterUrl;
  final List<List<int>> segments;
}

class DashFixture {
  DashFixture({
    required this.server,
    required this.masterUrl,
    required this.segments,
  });

  final HttpServer server;
  final String masterUrl;
  final List<List<int>> segments;
}

class SmoothStreamingFixture {
  SmoothStreamingFixture({
    required this.server,
    required this.masterUrl,
    required this.videoFragments,
    required this.audioFragments,
  });

  final HttpServer server;
  final String masterUrl;
  final List<List<int>> videoFragments;
  final List<List<int>> audioFragments;
}

class _RecordingPlatform extends VideoPlayerPlatform {
  final List<DataSource> dataSources = <DataSource>[];
  int _nextPlayerId = 0;
  final Map<int, StreamController<VideoEvent>> _streams =
      <int, StreamController<VideoEvent>>{};

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final StreamController<VideoEvent> stream = StreamController<VideoEvent>();
    _streams[_nextPlayerId] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(100, 100),
        duration: const Duration(seconds: 1),
      ),
    );
    dataSources.add(options.dataSource);
    return _nextPlayerId++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return _streams[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await _streams.remove(playerId)?.close();
  }
}