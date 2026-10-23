import 'dart:async';
import 'dart:isolate';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'package:aiplayer_smb/src/worker_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void _normal(List<dynamic> args) {
  final ready = args[0] as SendPort;
  final requests = ReceivePort();
  ready.send([requests.sendPort, 0x0311]);
  requests.listen((dynamic message) {
    final reply = message[2] as SendPort;
    switch (message[0]) {
      case 'close':
        reply.send(true);
        requests.close();
      case 'exit':
        requests.close();
      case 'stall':
        break;
      default:
        reply.send(message[1]);
    }
  });
}

void _late(List<dynamic> args) {
  final ready = args[0] as SendPort;
  final closed = args[1] as SendPort;
  final requests = ReceivePort();
  requests.listen((dynamic message) {
    if (message[0] == 'close') {
      (message[2] as SendPort).send(true);
      closed.send(true);
      requests.close();
    }
  });
  Timer(const Duration(milliseconds: 400), () {
    ready.send([requests.sendPort, 0x0311]);
  });
}

void _exit(List<dynamic> args) {}
void _error(List<dynamic> args) => throw StateError('private-password');

Matcher _failure(int code) =>
    isA<SmbFailure>().having((failure) => failure.code, 'code', code);

void main() {
  test('native worker replies and closes once', () async {
    final worker = await SmbWorkerChannel.start(_normal, []);
    expect(worker.dialect, 0x0311);
    expect(await worker.call('echo', ['中文.mkv']), ['中文.mkv']);
    await worker.close();
    await worker.close();
    await expectLater(worker.call('echo', []), throwsStateError);
  });

  test(
    'startup timeout closes a late native connection without killing it',
    () async {
      final closed = ReceivePort();
      try {
        await expectLater(
          SmbWorkerChannel.start(_late, [
            closed.sendPort,
          ], timeout: const Duration(milliseconds: 100)),
          throwsA(_failure(-110)),
        );
        expect(await closed.first.timeout(const Duration(seconds: 3)), true);
      } finally {
        closed.close();
      }
    },
  );

  test(
    'worker exit before ready fails promptly instead of waiting forever',
    () async {
      await expectLater(
        SmbWorkerChannel.start(_exit, []).timeout(const Duration(seconds: 2)),
        throwsA(_failure(-9003)),
      );
    },
  );

  test('worker uncaught startup error is redacted', () async {
    await expectLater(
      SmbWorkerChannel.start(_error, []).timeout(const Duration(seconds: 2)),
      throwsA(_failure(-9003)),
    );
    expect(
      const SmbFailure(-9003).message,
      isNot(contains('private-password')),
    );
  });

  test('worker exit during a request fails the pending caller', () async {
    final worker = await SmbWorkerChannel.start(_normal, []);
    await expectLater(
      worker.call('exit', []).timeout(const Duration(seconds: 2)),
      throwsA(_failure(-9003)),
    );
    await worker.close();
  });

  test(
    'request timeout is actionable and still permits native cleanup',
    () async {
      final worker = await SmbWorkerChannel.start(
        _normal,
        [],
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(worker.call('stall', []), throwsA(_failure(-110)));
      await worker.close();
      expect(const SmbFailure(-9002).message, contains('枚举服务'));
      expect(const SmbFailure(0xc00000b5).message, contains('超时'));
    },
  );
}
