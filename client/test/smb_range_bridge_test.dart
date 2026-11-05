import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/configuration.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

// Uses scripts/smb_fixture.sh and the built libaiplayer_smb.so. Ordinary test
// runs skip this explicitly; no fake adapter replaces authentication or reads.
final _fixture = Platform.environment['AIPLAYER_SMB_FIXTURE'] == 'true';
Map<String, dynamic> _configuration(String share) => {
  'kind': 'smb',
  'host': '127.0.0.1',
  'port': 1445,
  'share': share,
  'user': Platform.environment['USER'] ?? 'root',
  'smbSecurity': 'sign',
};
const _password = 'aiplayer-fixture-password';

void main() {
  for (final share in ['video', '']) {
    test('SMB worker owns authenticated ranges and 64-bit seeks, share=$share', () async {
      final source = await connectSource(
        _configuration(share),
        password: _password,
      );
      final prefix = share.isEmpty ? 'video/' : '';
      final client = HttpClient();
      RangeBridge? bridge;
      RangeBridge? large;
      try {
        bridge = await RangeBridge.open(source, '$prefix中文视频.mkv');
        large = await RangeBridge.open(source, '$prefix大文件.mkv');
        // The bridge must have its own connection, independent of UI browsing.
        await source.close();
        expect(bridge.entry.size, 2 * 1024 * 1024);
        final request = await client.getUrl(bridge.uri);
        request.headers.set('Range', 'bytes=257-265');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          response.headers.value('Content-Range'),
          'bytes 257-265/2097152',
        );
        expect(await response.expand((bytes) => bytes).toList(), [
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
        ]);
        final head = await (await client.headUrl(bridge.uri)).close();
        expect(head.contentLength, 2 * 1024 * 1024);
        expect(
          await head.fold<int>(0, (total, bytes) => total + bytes.length),
          0,
        );
        final denied = await (await client.getUrl(
          bridge.uri.replace(path: '/invalid/video'),
        )).close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
        final offset = 5 * 1024 * 1024 * 1024 + 7;
        final seek = await client.getUrl(large.uri);
        seek.headers.set('Range', 'bytes=$offset-${offset + 8}');
        expect(await (await seek.close()).expand((bytes) => bytes).toList(), [
          7,
          8,
          9,
          10,
          11,
          12,
          13,
          14,
          15,
        ]);
      } finally {
        client.close(force: true);
        await bridge?.close();
        await large?.close();
        await source.close();
      }
    }, skip: !_fixture);
  }

  test('SMB forwarding continues while the caller isolate cannot run', () async {
    final source = await connectSource(
      _configuration('video'),
      password: _password,
    );
    final bridge = await RangeBridge.open(source, '中文视频.mkv');
    final messages = ReceivePort();
    final stream = StreamIterator<dynamic>(messages);
    Isolate? consumer;
    try {
      consumer = await Isolate.spawn(_readWhileBlocked, (
        messages.sendPort,
        bridge.uri.toString(),
      ));
      await stream.moveNext();
      expect(stream.current, 'ready');
      // Deliberate test-only block proves socket forwarding does not depend on
      // the UI isolate; this is not a frame-rate or phone playback benchmark.
      final blocked = Stopwatch()..start();
      while (blocked.elapsedMilliseconds < 1200) {}
      final resumedAt = DateTime.now().millisecondsSinceEpoch;
      await stream.moveNext();
      final (int completedAt, int bytes) = stream.current as (int, int);
      expect(bytes, 2 * 1024 * 1024);
      expect(completedAt, lessThan(resumedAt - 100));
    } finally {
      consumer?.kill(priority: Isolate.immediate);
      await stream.cancel();
      messages.close();
      await bridge.close();
      await source.close();
    }
  }, skip: !_fixture);

  test(
    'SMB bridge startup cancellation does not wait for authentication',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>();
      final sockets = <Socket>[];
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {
          if (!connected.isCompleted) connected.complete();
        });
      });
      final source = await connectSource({
        ..._configuration(''),
        'port': listener.port,
      }, password: _password);
      final cancel = CancelToken();
      try {
        final work = RangeBridge.open(source, 'video/中文视频.mkv', cancel: cancel);
        final stopped = expectLater(work, throwsA(isA<Cancelled>()));
        await connected.future.timeout(const Duration(seconds: 5));
        cancel.cancel();
        await stopped.timeout(const Duration(seconds: 2));
      } finally {
        cancel.cancel();
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await listener.close();
        await source.close();
      }
    },
    skip: !_fixture,
  );

  test(
    'SMB cancelled native startups retain a bounded cleanup budget',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>();
      final sockets = <Socket>[];
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {});
        if (sockets.length == 2) connected.complete();
      });
      final sources = [
        for (var i = 0; i < 3; i++)
          await connectSource({
            ..._configuration(''),
            'port': listener.port,
          }, password: _password),
      ];
      final tokens = [for (var i = 0; i < 3; i++) CancelToken()];
      final work = <Future<void>>[];
      try {
        for (var i = 0; i < 2; i++) {
          work.add(
            expectLater(
              RangeBridge.open(sources[i], 'video/file.mkv', cancel: tokens[i]),
              throwsA(isA<Cancelled>()),
            ),
          );
        }
        await connected.future.timeout(const Duration(seconds: 5));
        work.add(
          expectLater(
            RangeBridge.open(sources[2], 'video/file.mkv', cancel: tokens[2]),
            throwsA(isA<Cancelled>()),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sockets, hasLength(2));
        for (final token in tokens) {
          token.cancel();
        }
        await Future.wait(work).timeout(const Duration(seconds: 2));
        expect(sockets, hasLength(2));
      } finally {
        for (final token in tokens) {
          token.cancel();
        }
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await listener.close();
        for (final source in sources) {
          await source.close();
        }
      }
    },
    skip: !_fixture,
  );
}

Future<void> _readWhileBlocked((SendPort, String) input) async {
  final (reply, address) = input;
  final client = HttpClient();
  try {
    reply.send('ready');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final response = await (await client.getUrl(Uri.parse(address))).close();
    final count = await response.fold<int>(
      0,
      (total, bytes) => total + bytes.length,
    );
    reply.send((DateTime.now().millisecondsSinceEpoch, count));
  } finally {
    client.close(force: true);
  }
}
