import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_file_details.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

class _RealHttp extends HttpOverrides {}

class _Local extends LocalSource {
  int closes = 0, stats = 0;
  int size = 1024;
  Future<void>? waitForClose;

  @override
  Future<SourceEntry> stat(String path) async {
    stats++;
    return SourceEntry(
      name: 'episode.mp4',
      path: path,
      size: size,
      modified: 1700000000000,
    );
  }

  @override
  Future<void> close() async {
    closes++;
    await waitForClose;
  }
}

Future<void> _drainRetirement() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inspections read current size and never reuse a cached snapshot',
    () async {
      final source = _Local();
      var probes = 0;
      final service = MediaFileDetailsService(
        probe: (uri, cancel) async {
          expect(uri, '/library/episode.mp4');
          probes++;
          return MediaFileProbeResult(
            container: 'mov,mp4,m4a,3gp,3g2,mj2',
            properties: {'时长': '00:00:02.000'},
            tracks: [
              MediaFileTrackDetails(
                type: 'video',
                id: 1,
                properties: {'编码': 'H.264', '分辨率': '320 × 180'},
              ),
            ],
          );
        },
      );
      Future<MediaFileDetails> inspect() => service.inspect(
        openSource: () async => source,
        path: '/library/episode.mp4',
        fileName: 'old-name.mkv',
        sourceName: '本地视频',
        cancel: CancelToken(),
      );
      final first = await inspect();
      source.size = 2048;
      final second = await inspect();
      expect(first.size, 1024);
      expect(second.size, 2048);
      expect(first.fileName, 'episode.mp4');
      expect(first.sourceName, '本地视频');
      expect(first.format, 'MP4');
      expect(first.modified, 1700000000000);
      expect(first.properties['文件路径'], '/library/episode.mp4');
      expect(first.tracks.single.properties['编码'], 'H.264');
      expect(probes, 2);
      expect(source.stats, 2);
      expect(source.closes, 2);
      expect(() => first.properties['new'] = 'value', throwsUnsupportedError);
      expect(() => first.tracks.clear(), throwsUnsupportedError);
      expect(
        () => first.tracks.single.properties['new'] = 'value',
        throwsUnsupportedError,
      );
    },
  );

  test('no queue and no release of admission before probe cleanup', () async {
    final source = _Local();
    final probing = Completer<void>();
    final cleanup = Completer<void>();
    final service = MediaFileDetailsService(
      probe: (_, cancel) async {
        probing.complete();
        await cancel.whenCancelled;
        await cleanup.future;
        throw const Cancelled();
      },
    );
    final cancel = CancelToken();
    Future<MediaFileDetails> inspect(CancelToken token) => service.inspect(
      openSource: () async => source,
      path: '/episode.mp4',
      cancel: token,
    );
    final work = inspect(cancel);
    await probing.future;
    await expectLater(inspect(CancelToken()), throwsA(isA<AppFailure>()));
    cancel.cancel();
    await expectLater(work, throwsA(isA<Cancelled>()));
    await expectLater(inspect(CancelToken()), throwsA(isA<AppFailure>()));
    expect(source.closes, 1);
    var resumed = false;
    final waiting = service.waitUntilIdle(CancelToken()).then((_) {
      resumed = true;
    });
    final cancelWaiting = CancelToken();
    final abandoned = service.waitUntilIdle(cancelWaiting);
    cancelWaiting.cancel();
    await expectLater(abandoned, throwsA(isA<Cancelled>()));
    await _drainRetirement();
    expect(resumed, isFalse);
    cleanup.complete();
    await waiting;
    expect(resumed, isTrue);
    expect(source.closes, 1);
  });

  test('cancelled late connections close and keep admission bounded', () async {
    final connection = Completer<SourceAdapter>();
    final source = _Local();
    var probes = 0;
    final service = MediaFileDetailsService(
      probe: (_, _) async {
        probes++;
        return MediaFileProbeResult();
      },
    );
    final cancel = CancelToken();
    final work = service.inspect(
      openSource: () => connection.future,
      path: '/episode.mp4',
      cancel: cancel,
    );
    cancel.cancel();
    await expectLater(work, throwsA(isA<Cancelled>()));
    await expectLater(
      service.inspect(
        openSource: () async => source,
        path: '/episode.mp4',
        cancel: CancelToken(),
      ),
      throwsA(isA<AppFailure>()),
    );
    connection.complete(source);
    await _drainRetirement();
    expect(source.closes, 1);
    expect(probes, 0);
    await service.inspect(
      openSource: () async => _Local(),
      path: '/episode.mp4',
      cancel: CancelToken(),
    );
    expect(probes, 1);
  });

  test('slow source close cannot delay a ready result indefinitely', () async {
    final release = Completer<void>();
    final source = _Local()..waitForClose = release.future;
    final service = MediaFileDetailsService(
      probe: (_, _) async => MediaFileProbeResult(),
    );
    Future<MediaFileDetails> inspect() => service.inspect(
      openSource: () async => source,
      path: '/episode.mp4',
      cancel: CancelToken(),
    );
    try {
      final result = await inspect().timeout(const Duration(seconds: 1));
      expect(result.size, 1024);
      await expectLater(inspect(), throwsA(isA<AppFailure>()));
    } finally {
      release.complete();
    }
    await _drainRetirement();
    expect((await inspect()).size, 1024);
  });

  test(
    'remote inspection keeps credentials inside its private range bridge',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      final subscription = server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          'Basic dXNlcjpzZWNyZXQ=',
        );
        expect(request.uri.queryParameters['token'], 'signed-secret');
        seen.add(request.method);
        request.response.headers.set('Accept-Ranges', 'bytes');
        if (request.method == 'HEAD') {
          request.response.contentLength = 1024;
        } else {
          expect(request.headers.value('range'), 'bytes=0-3');
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Range', 'bytes 0-3/1024');
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final service = MediaFileDetailsService(
        probe: (uri, _) async {
          expect(uri, isNot(contains('secret')));
          final client = HttpOverrides.runWithHttpOverrides(
            HttpClient.new,
            _RealHttp(),
          );
          try {
            final request = await client.getUrl(Uri.parse(uri));
            request.headers.set('Range', 'bytes=0-3');
            final response = await request.close();
            expect(await response.expand((chunk) => chunk).toList(), [
              1,
              2,
              3,
              4,
            ]);
          } finally {
            client.close(force: true);
          }
          return MediaFileProbeResult(container: 'mov,mp4');
        },
      );
      try {
        final result = await service.inspect(
          openSource: () async => HttpSource(
            'http://127.0.0.1:${server.port}/episode.mp4?token=signed-secret',
            user: 'user',
            password: 'secret',
          ),
          path: '',
          cancel: CancelToken(),
        );
        expect(result.fileName, 'episode.mp4');
        expect(result.format, 'MP4');
        expect(result.size, 1024);
        expect(result.properties.containsKey('读取状态'), isFalse);
        expect(seen, ['HEAD', 'GET']);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'timeout cancels probe and reports a bounded retryable failure',
    () async {
      final source = _Local();
      final service = MediaFileDetailsService(
        requestTimeout: const Duration(milliseconds: 20),
        probe: (_, cancel) async {
          await cancel.whenCancelled;
          throw const Cancelled();
        },
      );
      await expectLater(
        service.inspect(
          openSource: () async => source,
          path: '/episode.mp4',
          cancel: CancelToken(),
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );
      await _drainRetirement();
      expect(source.closes, 1);
    },
  );

  test(
    'demuxer failure still returns fresh file facts without private errors',
    () async {
      final source = _Local();
      final service = MediaFileDetailsService(
        probe: (_, _) async => throw StateError(
          'https://name:secret@example.test/private?token=secret',
        ),
      );
      final details = await service.inspect(
        openSource: () async => source,
        path:
            'https://name:secret@example.test/episode.mp4?token=secret#secret',
        fileName: 'https://name:secret@example.test/episode.mp4?token=secret',
        sourceName: 'https://name:secret@example.test/?token=secret',
        cancel: CancelToken(),
      );
      expect(details.size, 1024);
      expect(details.fileName, 'episode.mp4');
      expect(details.format, 'MP4');
      expect(details.properties['读取状态'], contains('未能读取'));
      expect(details.properties.toString(), isNot(contains('secret')));
      expect(details.sourceName, isNot(contains('secret')));
      expect(source.closes, 1);
    },
  );

  const fixture = String.fromEnvironment('FILE_DETAILS_FIXTURE');
  test(
    'native worker reads real container and video/audio/subtitle headers',
    () async {
      MediaKit.ensureInitialized();
      final file = File(fixture);
      expect(await file.exists(), isTrue);
      final mainLoopTicks = <int>[];
      final clock = Stopwatch()..start();
      final tick = Timer.periodic(const Duration(milliseconds: 5), (_) {
        mainLoopTicks.add(clock.elapsedMilliseconds);
      });
      final details = await MediaFileDetailsService().inspect(
        openSource: () async => LocalSource(),
        path: fixture,
        cancel: CancelToken(),
      );
      tick.cancel();
      expect(details.size, await file.length());
      expect(details.properties.containsKey('读取状态'), isFalse);
      expect(details.metadata.toString(), isNot(contains('secret')));
      expect(details.properties['时长'], isNotEmpty);
      expect(
        details.tracks.where((track) => track.type == 'video'),
        isNotEmpty,
      );
      expect(
        details.tracks.where((track) => track.type == 'audio'),
        isNotEmpty,
      );
      final video = details.tracks.firstWhere((track) => track.type == 'video');
      expect(video.properties['分辨率'], isNotEmpty);
      expect(video.properties['编码'], isNotEmpty);
      expect(video.properties['帧率'], isNotEmpty);
      final audio = details.tracks.firstWhere((track) => track.type == 'audio');
      expect(audio.properties['采样率'], isNotEmpty);
      expect(audio.properties['声道数'], isNotEmpty);
      expect(mainLoopTicks, isNotEmpty);
      // Controlled responsiveness evidence only, not a device FPS benchmark.
      // ignore: avoid_print
      print({
        'format': details.format,
        'properties': details.properties,
        'tracks': [
          for (final track in details.tracks)
            {
              'type': track.type,
              'properties': track.properties,
              'metadata': track.metadata,
            },
        ],
        'metadata': details.metadata,
        'elapsedMs': clock.elapsedMilliseconds,
        'mainLoopTicks': mainLoopTicks.length,
      });
    },
    skip: fixture.isEmpty,
  );
}
