import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

final _authorization = 'Basic ${base64Encode(utf8.encode('user:password'))}';

Future<void> _video(HttpRequest request) async {
  request.response.headers.set('Accept-Ranges', 'bytes');
  request.response.contentLength = 1024;
  if (request.method == 'GET') {
    final range = ByteRange.parse(request.headers.value('range'), 1024)!;
    request.response.statusCode = 206;
    request.response.contentLength = range.length;
    request.response.headers.set(
      'Content-Range',
      'bytes ${range.start}-${range.end}/1024',
    );
    request.response.add([
      for (var index = range.start; index <= range.end; index++) index % 256,
    ]);
  }
  await request.response.close();
}

void main() {
  for (final status in [301, 302, 303, 307, 308]) {
    test('WebDAV worker follows HTTP $status for probes and seeks', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <(String, String, String?)>[];
      server.listen((request) async {
        requests.add((
          request.method,
          Uri.decodeComponent(request.uri.path),
          request.headers.value('range'),
        ));
        expect(request.headers.value('authorization'), _authorization);
        if (request.uri.path.startsWith('/dav/')) {
          request.response.statusCode = status;
          request.response.headers.set(
            'Location',
            '../download/video?signature=a%2Bb%2Fc&expires=123',
          );
          await request.response.close();
        } else {
          expect(request.uri.query, 'signature=a%2Bb%2Fc&expires=123');
          if (request.method == 'GET') {
            expect(request.headers.value('accept-encoding'), 'identity');
          }
          await _video(request);
        }
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/dav/',
        webdav: true,
        user: 'user',
        password: 'password',
      );
      final client = HttpClient();
      RangeBridge? bridge;
      try {
        bridge = await RangeBridge.open(source, '中文 视频.mkv');
        await source.close();
        expect(bridge.entry.name, '中文 视频.mkv');
        expect(bridge.entry.path, '中文 视频.mkv');
        expect(bridge.entry.size, 1024);
        expect(bridge.entry.seekable, isTrue);
        for (final (start, end) in [(0, 31), (800, 815), (40, 49)]) {
          final request = await client.getUrl(bridge.uri);
          request.headers.set('Range', 'bytes=$start-$end');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(await response.expand((bytes) => bytes).toList(), [
            for (var index = start; index <= end; index++) index % 256,
          ]);
        }
        expect(requests, [
          ('HEAD', '/dav/中文 视频.mkv', null),
          ('HEAD', '/download/video', null),
          for (final range in [
            'bytes=0-31',
            'bytes=800-815',
            'bytes=40-49',
          ]) ...[
            ('GET', '/dav/中文 视频.mkv', range),
            ('GET', '/download/video', range),
          ],
        ]);
      } finally {
        client.close(force: true);
        await bridge?.close();
        await source.close();
        await server.close(force: true);
      }
    });
  }

  for (final headStatus in [200, 405, 501]) {
    test(
      'redirected HEAD $headStatus falls back to a redirected range probe',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final methods = <String>[];
        server.listen((request) async {
          methods.add('${request.method} ${request.uri.path}');
          if (request.uri.path == '/dav/video.mkv') {
            request.response.statusCode = 302;
            request.response.headers.set('Location', '/download');
            await request.response.close();
          } else if (request.method == 'HEAD') {
            request.response.statusCode = headStatus;
            // A 200 HEAD without Accept-Ranges/size also needs the GET probe.
            await request.response.close();
          } else {
            expect(request.headers.value('range'), 'bytes=0-0');
            await _video(request);
          }
        });
        final source = HttpSource(
          'http://127.0.0.1:${server.port}/dav/',
          webdav: true,
        );
        try {
          final entry = await source.stat('video.mkv');
          expect(entry.size, 1024);
          expect(entry.seekable, isTrue);
          expect(methods, [
            'HEAD /dav/video.mkv',
            'HEAD /download',
            'GET /dav/video.mkv',
            'GET /download',
          ]);
        } finally {
          await source.close();
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'cross-origin redirects strip credentials for the rest of each chain',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final credentials = <(String, String?)>[];
      origin.listen((request) async {
        credentials.add((
          request.uri.path,
          request.headers.value('authorization'),
        ));
        if (request.uri.path == '/dav/video.mkv') {
          request.response.statusCode = 301;
          request.response.headers.set('Location', '/redirect');
        } else if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'Location',
            'http://127.0.0.1:${cdn.port}/signed?token=private-token',
          );
        } else {
          await _video(request);
          return;
        }
        await request.response.close();
      });
      cdn.listen((request) async {
        credentials.add((
          request.uri.path,
          request.headers.value('authorization'),
        ));
        request.response.statusCode = 307;
        request.response.headers.set(
          'Location',
          'http://127.0.0.1:${origin.port}/final',
        );
        await request.response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${origin.port}/dav/',
        webdav: true,
        user: 'user',
        password: 'password',
      );
      try {
        expect((await source.stat('video.mkv')).size, 1024);
        expect(
          await source.read('video.mkv', 17, 19).expand((b) => b).toList(),
          [17, 18, 19],
        );
        expect(credentials, [
          for (var request = 0; request < 2; request++) ...[
            ('/dav/video.mkv', _authorization),
            ('/redirect', _authorization),
            ('/signed', null),
            ('/final', null),
          ],
        ]);
      } finally {
        await source.close();
        await origin.close(force: true);
        await cdn.close(force: true);
      }
    },
  );

  for (final location in [
    null,
    '',
    'http://[invalid',
    'file:///private-password',
    'ftp://example.invalid/private-token',
    'http://user:private-password@example.invalid/video',
  ]) {
    test(
      'invalid redirect Location $location is rejected without secrets',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.statusCode = 302;
          if (location != null) {
            request.response.headers.set('Location', location);
          }
          await request.response.close();
        });
        final source = HttpSource('http://127.0.0.1:${server.port}/video');
        try {
          await expectLater(
            source.stat(''),
            throwsA(
              isA<AppFailure>()
                  .having((error) => error.status, 'status', 302)
                  .having((error) => error.message, 'detail', contains('无效'))
                  .having(
                    (error) => error.message,
                    'redacted',
                    isNot(contains('private')),
                  ),
            ),
          );
          expect(requests, 1);
        } finally {
          await source.close();
          await server.close(force: true);
        }
      },
    );
  }

  test('redirect loops stop after five hops', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('Location', '/video?token=private-token');
      await request.response.close();
    });
    final source = HttpSource('http://127.0.0.1:${server.port}/video');
    try {
      await expectLater(
        source.stat(''),
        throwsA(
          isA<AppFailure>()
              .having((error) => error.status, 'status', 302)
              .having((error) => error.message, 'detail', contains('重定向次数过多'))
              .having(
                (error) => error.message,
                'redacted',
                isNot(contains('private')),
              ),
        ),
      );
      expect(requests, 6);
    } finally {
      await source.close();
      await server.close(force: true);
    }
  });

  test('range redirects do not wait for an unfinished redirect body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/video') {
        try {
          request.response.statusCode = 302;
          request.response.headers.set('Location', '/download');
          request.response.bufferOutput = false;
          request.response.write('Unfinished redirect response');
          await request.response.flush();
        } on SocketException {
          // The client cancels this body before following Location.
        }
      } else {
        await _video(request);
      }
    });
    final source = HttpSource('http://127.0.0.1:${server.port}/video');
    try {
      expect(
        await source
            .read('', 20, 22)
            .expand((b) => b)
            .toList()
            .timeout(const Duration(seconds: 2)),
        [20, 21, 22],
      );
    } finally {
      await source.close();
      await server.close(force: true);
    }
  });

  test(
    'closing during redirect lookup prevents a late destination request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final redirectLookup = Completer<void>(), lookup = Completer<String?>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/download');
        await request.response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/video',
        proxyResolver: (uri, {cancel}) async {
          if (uri.path == '/download') {
            redirectLookup.complete();
            return lookup.future;
          }
          return 'DIRECT';
        },
      );
      final pending = expectLater(source.stat(''), throwsA(isA<Cancelled>()));
      try {
        await redirectLookup.future.timeout(const Duration(seconds: 2));
        await source.close();
        lookup.complete('DIRECT');
        await pending;
        expect(requests, 1);
      } finally {
        if (!lookup.isCompleted) lookup.complete('DIRECT');
        await source.close();
        await server.close(force: true);
      }
    },
  );
}
