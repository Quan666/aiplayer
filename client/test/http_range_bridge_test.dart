import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'HTTP worker preserves authenticated ranges, HEAD and token checks',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      final authorization =
          'Basic ${base64Encode(utf8.encode('user:password'))}';
      server.listen((request) async {
        methods.add(request.method);
        expect(request.uri.pathSegments, ['dav', '中文 视频.mkv']);
        expect(request.headers.value('authorization'), authorization);
        request.response.headers.set('Accept-Ranges', 'bytes');
        if (request.method == 'HEAD') {
          request.response.contentLength = 1024;
        } else {
          final range = ByteRange.parse(request.headers.value('range'), 1024)!;
          request.response.statusCode = 206;
          request.response.contentLength = range.length;
          request.response.headers.set(
            'Content-Range',
            'bytes ${range.start}-${range.end}/1024',
          );
          request.response.add([
            for (var index = range.start; index <= range.end; index++)
              index % 256,
          ]);
        }
        await request.response.close();
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
        final entry = await source.stat('中文 视频.mkv');
        bridge = await RangeBridge.open(source, entry.path, entry: entry);
        // The playback worker owns its client independently of directory and
        // subtitle browsing on the caller's source.
        await source.close();
        expect(methods, ['HEAD']);
        for (final range in [
          ('bytes=10-19', 10, 19),
          ('bytes=-3', 1021, 1023),
          ('bytes=1000-', 1000, 1023),
        ]) {
          final request = await client.getUrl(bridge.uri);
          request.headers.set('Range', range.$1);
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(response.contentLength, range.$3 - range.$2 + 1);
          expect(
            response.headers.value('Content-Range'),
            'bytes ${range.$2}-${range.$3}/1024',
          );
          expect(await response.expand((bytes) => bytes).toList(), [
            for (var index = range.$2; index <= range.$3; index++) index % 256,
          ]);
        }
        final head = await (await client.openUrl('HEAD', bridge.uri)).close();
        expect(head.statusCode, 200);
        expect(head.contentLength, 1024);
        expect(await head.toList(), isEmpty);
        final upstreamCount = methods.length;
        final invalidRange = await client.getUrl(bridge.uri);
        invalidRange.headers.set('Range', 'bytes=2048-');
        final unsatisfied = await invalidRange.close();
        expect(unsatisfied.statusCode, 416);
        await unsatisfied.drain<void>();
        final denied = await (await client.getUrl(
          bridge.uri.replace(path: '/invalid/video'),
        )).close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
        final post = await (await client.postUrl(bridge.uri)).close();
        expect(post.statusCode, 405);
        await post.drain<void>();
        expect(methods.length, upstreamCount);
        await Future.wait([bridge.close(), bridge.close()]);
        await expectLater(
          client.getUrl(bridge.uri),
          throwsA(isA<SocketException>()),
        );
      } finally {
        client.close(force: true);
        await bridge?.close();
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'HTTP worker preserves source failures without exposing credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 401;
        await request.response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/private-video?token=private-token',
        user: 'user',
        password: 'private-password',
      );
      try {
        await expectLater(
          RangeBridge.open(source, ''),
          throwsA(
            isA<AppFailure>()
                .having((error) => error.status, 'status', 401)
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private')),
                ),
          ),
        );
      } finally {
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'closing the HTTP worker cancels stalled playback without waiting for upstream',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamReading = Completer<void>();
      server.listen((request) async {
        try {
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.contentLength = 1024;
          if (request.method == 'HEAD') {
            await request.response.close();
            return;
          }
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-1023/1024');
          request.response.add([1, 2, 3]);
          await request.response.flush();
          upstreamReading.complete();
        } on SocketException {
          // The bridge is expected to abandon this incomplete stream.
        }
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/video.mkv');
      final client = HttpClient();
      final bridge = await RangeBridge.open(source, '');
      try {
        final downloading = () async {
          try {
            final response = await (await client.getUrl(bridge.uri)).close();
            await response.drain<void>();
          } on HttpException {
            // Closing a bridge can interrupt headers or a partial response.
          } on SocketException {
            // A pending connection is also cancelled by shutdown.
          }
        }();
        await upstreamReading.future.timeout(const Duration(seconds: 3));
        await bridge.close().timeout(const Duration(seconds: 3));
        await downloading.timeout(const Duration(seconds: 3));
      } finally {
        client.close(force: true);
        await bridge.close();
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'cancelling HTTP bridge startup aborts a stalled HEAD worker immediately',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>(), disconnected = Completer<void>();
      Socket? upstream;
      server.listen((request) async {
        expect(request.method, 'HEAD');
        upstream = await request.response.detachSocket(writeHeaders: false);
        upstream!.listen(
          (_) {},
          onDone: disconnected.complete,
          onError: (Object _) {},
        );
        connected.complete();
        // Deliberately leave the connection open without response headers.
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/video.mkv');
      final cancel = CancelToken();
      try {
        final opening = RangeBridge.open(source, '', cancel: cancel);
        final cancelled = expectLater(opening, throwsA(isA<Cancelled>()));
        await connected.future.timeout(const Duration(seconds: 3));
        cancel.cancel();
        await cancelled.timeout(const Duration(seconds: 3));
        await disconnected.future.timeout(const Duration(seconds: 3));
      } finally {
        cancel.cancel();
        upstream?.destroy();
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'HTTP video forwarding continues while the UI isolate is blocked',
    () async {
      final messages = ReceivePort();
      final stream = StreamIterator<dynamic>(messages);
      final fixture = await Isolate.spawn(_trafficFixture, messages.sendPort);
      HttpSource? source;
      RangeBridge? bridge;
      try {
        await stream.moveNext();
        final (int port, SendPort commands) = stream.current as (int, SendPort);
        source = HttpSource('http://127.0.0.1:$port/video.mkv');
        bridge = await RangeBridge.open(source, '');
        commands.send(bridge.uri.toString());
        await stream.moveNext();
        expect(stream.current, 'reading');
        // Both the upstream fixture and consumer are separate from the main
        // isolate. A bridge on this isolate cannot forward their remaining bytes.
        final blocked = Stopwatch()..start();
        while (blocked.elapsedMilliseconds < 900) {}
        final unblockedAt = DateTime.now().millisecondsSinceEpoch;
        await stream.moveNext();
        final (int completedAt, int count) = stream.current as (int, int);
        expect(count, 32768);
        expect(completedAt, lessThan(unblockedAt - 100));
      } finally {
        await bridge?.close();
        await source?.close();
        fixture.kill(priority: Isolate.immediate);
        await stream.cancel();
        messages.close();
      }
    },
  );
}

Future<void> _trafficFixture(SendPort reply) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.set('Accept-Ranges', 'bytes');
    request.response.contentLength = 32768;
    if (request.method != 'HEAD') {
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes 0-32767/32768');
      for (var index = 0; index < 8; index++) {
        request.response.add(Uint8List(4096));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
    await request.response.close();
  });
  final commands = ReceivePort();
  reply.send((server.port, commands.sendPort));
  final uri = Uri.parse(await commands.first as String);
  final client = HttpClient();
  final response = await (await client.getUrl(uri)).close();
  reply.send('reading');
  final count = await response.fold<int>(
    0,
    (total, bytes) => total + bytes.length,
  );
  reply.send((DateTime.now().millisecondsSinceEpoch, count));
  client.close(force: true);
  commands.close();
  await server.close(force: true);
}
