import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/remote/remote_control_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(int, String?)> pair(
  HttpClient client,
  Uri url, {
  String? token,
  String? origin,
}) async {
  final request = await client.postUrl(url.resolve('/pair'));
  request.headers.contentType = ContentType.json;
  request.headers.set('Origin', origin ?? url.origin);
  request.write(jsonEncode({'token': token ?? url.fragment}));
  final response = await request.close();
  await response.drain<void>();
  final cookie = response.cookies.firstOrNull;
  return (
    response.statusCode,
    cookie == null ? null : '${cookie.name}=${cookie.value}',
  );
}

Future<WebSocket> connect(Uri url, String cookie, {String? origin}) =>
    WebSocket.connect(
      url.replace(scheme: 'ws', path: '/control', fragment: '').toString(),
      headers: {'Origin': origin ?? url.origin, 'Cookie': cookie},
      compression: CompressionOptions.compressionOff,
    );

Future<Map<String, dynamic>> message(
  StreamIterator<dynamic> messages,
  String type,
) async {
  while (await messages.moveNext().timeout(const Duration(seconds: 3))) {
    final value =
        jsonDecode(messages.current as String) as Map<String, dynamic>;
    if (value['type'] == type) return value;
  }
  throw StateError('Remote closed before $type');
}

void main() {
  test(
    'a delayed pairing body cannot replace an established session',
    () async {
      final client = HttpClient();
      final service = RemoteControlService(
        onCommand: (_) async => const RemoteCommandResult(true),
      );
      Socket? delayed;
      StreamIterator<String>? lines;
      WebSocket? control;
      try {
        await service.start(address: '127.0.0.1', allowLoopback: true);
        final url = service.value.pairingUrl!;
        delayed = await Socket.connect(url.host, url.port);
        lines = StreamIterator(
          delayed
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        const body = '{"token":""}';
        delayed.write(
          'POST /pair HTTP/1.1\r\nHost: ${url.authority}\r\n'
          'Origin: ${url.origin}\r\nContent-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n\r\n{"token":',
        );
        await delayed.flush();
        // Keep the first body incomplete while the worker handles another HTTP
        // exchange, then establish the legitimate session on a separate socket.
        final probe = await (await client.getUrl(url.resolve('/'))).close();
        await probe.drain<void>();
        final established = await pair(client, url);
        expect(established.$1, 200);
        delayed.write('""}');
        await delayed.flush();
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 3)),
          isTrue,
        );
        expect(lines.current, contains('403 Forbidden'));
        control = await connect(url, established.$2!);
      } finally {
        await control?.close();
        await lines?.cancel();
        delayed?.destroy();
        await service.stop();
        service.dispose();
        client.close(force: true);
      }
    },
  );
  test(
    'wrong host and oversized pairing bodies cannot consume a valid pairing',
    () async {
      final client = HttpClient();
      final service = RemoteControlService(
        onCommand: (_) async => const RemoteCommandResult(true),
      );
      try {
        await service.start(address: '127.0.0.1', allowLoopback: true);
        final url = service.value.pairingUrl!;
        final foreign = await client.getUrl(url.resolve('/'));
        foreign.headers.set('Host', 'attacker.invalid');
        final foreignResponse = await foreign.close();
        expect(foreignResponse.statusCode, 403);
        await foreignResponse.drain<void>();
        final large = await client.postUrl(url.resolve('/pair'));
        large.headers.set('Origin', url.origin);
        large.headers.contentType = ContentType.json;
        large.write(jsonEncode({'token': 'x' * 9000}));
        try {
          final largeResponse = await large.close();
          expect(largeResponse.statusCode, 400);
          await largeResponse.drain<void>();
        } on HttpException {
          // Cancelling an over-limit incoming body may close its TCP stream
          // before an error response can be written. Both reject the payload.
        }
        expect((await pair(client, url)).$1, 200);
      } finally {
        await service.stop();
        service.dispose();
        client.close(force: true);
      }
    },
  );
  test(
    'explicit pairing is same-origin, one-use and separate from session cookie',
    () async {
      final client = HttpClient();
      final service = RemoteControlService(
        onCommand: (_) async => const RemoteCommandResult(true),
      );
      try {
        expect(service.value.running, isFalse);
        await service.start(address: '127.0.0.1', allowLoopback: true);
        final url = service.value.pairingUrl!;
        expect(
          service.value.qr,
          hasLength(service.value.qrSize * service.value.qrSize),
        );
        final page = await (await client.getUrl(url.resolve('/'))).close();
        final html = await utf8.decoder.bind(page).join();
        expect(html, contains('输入到当前输入框'));
        expect(html, isNot(contains(url.fragment)));
        expect(page.headers.value('Referrer-Policy'), 'no-referrer');
        expect(
          (await pair(client, url, origin: 'https://example.com')).$1,
          403,
        );
        expect((await pair(client, url, token: 'wrong')).$1, 403);
        final result = await pair(client, url);
        expect(result.$1, 200);
        expect(result.$2, isNot(contains(url.fragment)));
        expect((await pair(client, url)).$1, 409);
        await expectLater(
          connect(url, result.$2!, origin: 'https://example.com'),
          throwsA(isA<WebSocketException>()),
        );
        await expectLater(
          connect(url, 'aiplayer_remote=wrong'),
          throwsA(isA<WebSocketException>()),
        );
      } finally {
        await service.stop();
        service.dispose();
        client.close(force: true);
      }
    },
  );

  test(
    'validated commands and state updates are event driven; replay is rejected',
    () async {
      final client = HttpClient();
      final received = <String>[];
      final service = RemoteControlService(
        onCommand: (command) async {
          expect(command.isCurrent, isTrue);
          received.add(command.action);
          return const RemoteCommandResult(true);
        },
      );
      WebSocket? socket;
      StreamIterator<dynamic>? messages;
      try {
        await service.start(address: '127.0.0.1', allowLoopback: true);
        final url = service.value.pairingUrl!;
        final paired = await pair(client, url);
        socket = await connect(url, paired.$2!);
        messages = StreamIterator(socket);
        expect((await message(messages, 'status'))['editing'], isFalse);
        socket.add(jsonEncode({'id': 1, 'action': 'right'}));
        expect((await message(messages, 'result'))['ok'], isTrue);
        service.publish(
          const RemoteControlStatus(
            playing: true,
            active: true,
            editing: true,
            editSession: 15,
          ),
        );
        final status = await message(messages, 'status');
        expect(status['playing'], isTrue);
        expect(status['editSession'], 15);
        socket.add(
          jsonEncode({
            'id': 2,
            'action': 'text',
            'text': '海边旅行',
            'editSession': 15,
          }),
        );
        expect((await message(messages, 'result'))['ok'], isTrue);
        socket.add(jsonEncode({'id': 2, 'action': 'select'}));
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 3)),
          isFalse,
        );
        expect(received, ['right', 'text']);
      } finally {
        await messages?.cancel();
        await socket?.close();
        await service.stop();
        service.dispose();
        client.close(force: true);
      }
    },
  );

  test('pause closes listener immediately and discards queued/late commands without frames', () async {
    final client = HttpClient();
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0;
    RemoteCommand? active;
    final service = RemoteControlService(
      onCommand: (command) async {
        calls++;
        active = command;
        entered.complete();
        await release.future;
        return RemoteCommandResult(command.isCurrent);
      },
    );
    WebSocket? socket;
    try {
      await service.start(address: '127.0.0.1', allowLoopback: true);
      final url = service.value.pairingUrl!;
      socket = await connect(url, (await pair(client, url)).$2!);
      socket.listen((_) {});
      for (var id = 1; id <= 12; id++) {
        socket.add(jsonEncode({'id': id, 'action': 'right'}));
      }
      await entered.future.timeout(const Duration(seconds: 3));
      final stopping = service.stop();
      expect(service.value.running, isFalse);
      expect(active!.isCurrent, isFalse);
      release.complete();
      await stopping;
      expect(calls, 1);
      await expectLater(() async {
        final request = await client.getUrl(url.resolve('/'));
        final response = await request.close();
        await response.drain<void>();
      }, throwsA(anyOf(isA<SocketException>(), isA<HttpException>())));
    } finally {
      if (!release.isCompleted) release.complete();
      await socket?.close();
      await service.stop();
      service.dispose();
      client.close(force: true);
    }
  });

  test(
    'unpaired expiry shuts the server rather than retaining an idle listener',
    () async {
      final service = RemoteControlService(
        onCommand: (_) async => const RemoteCommandResult(true),
      );
      final client = HttpClient();
      try {
        await service.start(
          address: '127.0.0.1',
          allowLoopback: true,
          pairingLifetime: const Duration(milliseconds: 100),
        );
        final url = service.value.pairingUrl!;
        final stopped = Completer<void>();
        void changed() {
          if (!service.value.running && !stopped.isCompleted) {
            stopped.complete();
          }
        }

        service.addListener(changed);
        changed();
        await stopped.future.timeout(const Duration(seconds: 3));
        expect(service.value.message, contains('过期'));
        await expectLater(
          client.getUrl(url.resolve('/')),
          throwsA(isA<SocketException>()),
        );
        service.removeListener(changed);
      } finally {
        await service.stop();
        service.dispose();
        client.close(force: true);
      }
    },
  );

  test(
    'stop while startup is pending cannot leave a listening worker',
    () async {
      final service = RemoteControlService(
        onCommand: (_) async => const RemoteCommandResult(true),
      );
      final starting = service.start(address: '127.0.0.1', allowLoopback: true);
      await service.stop();
      await starting.timeout(const Duration(seconds: 3));
      expect(service.value.running, isFalse);
      service.dispose();
    },
  );
}
