import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/text_document.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

// A real nested isolate models SMB's independently owned native worker. Its
// read/close gates reproduce a native operation that cannot be killed safely.
Future<SourceAdapter> _connectChild(
  Map<String, dynamic> config,
  String _,
) async {
  final events = config['events'] as SendPort;
  final id = config['id'] as String;
  if (config['holdOpening'] == true) {
    final ready = ReceivePort();
    events.send((id, 'opening', ready.sendPort));
    await ready.first;
    ready.close();
  }
  return _ChildSource.open(config);
}

class _ChildSource extends SourceAdapter {
  final SendPort commands;
  final ReceivePort exit;
  final Future<dynamic> exited;
  final int byteSize;
  Future<void>? closing;
  _ChildSource(this.commands, this.exit, this.exited, this.byteSize);

  static Future<_ChildSource> open(Map<String, dynamic> config) async {
    final ready = ReceivePort(), exit = ReceivePort();
    final exited = exit.first;
    await Isolate.spawn(_childMain, (
      ready.sendPort,
      config,
    ), onExit: exit.sendPort);
    final commands = await ready.first as SendPort;
    ready.close();
    return _ChildSource(
      commands,
      exit,
      exited,
      config['size'] as int? ?? 128 * 1024,
    );
  }

  Future<dynamic> call(String operation) async {
    final response = ReceivePort();
    commands.send((operation, response.sendPort));
    try {
      final value = await response.first;
      if (value == 'read-error') throw const AppFailure('SMB 读取失败。');
      return value;
    } finally {
      response.close();
    }
  }

  @override
  Future<List<SourceEntry>> list(String path) async => [];

  @override
  Future<SourceEntry> stat(String path) async {
    await call('stat');
    return SourceEntry(name: path, path: path, size: byteSize);
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    var offset = start;
    while (offset <= end) {
      final bytes = await call('read') as Uint8List;
      yield bytes;
      offset += bytes.length;
    }
  }

  @override
  Future<void> close() => closing ??= () async {
    await call('close');
    await exited;
    exit.close();
  }();
}

void _childMain((SendPort, Map<String, dynamic>) arguments) {
  final (ready, config) = arguments;
  final events = config['events'] as SendPort;
  final id = config['id'] as String;
  final commands = ReceivePort();
  var holdRead = config['holdRead'] == true;
  var holdClose = config['holdClose'] == true;
  SendPort? pendingRead, pendingClose;
  void finishClose() {
    if (pendingClose == null || pendingRead != null || holdClose) return;
    pendingClose!.send(true);
    events.send((id, 'closed', null));
    commands.close();
  }

  ready.send(commands.sendPort);
  events.send((id, 'child', commands.sendPort));
  commands.listen((dynamic message) {
    if (message == 'release-read') {
      holdRead = false;
      pendingRead?.send(Uint8List.fromList(List.filled(64 * 1024, 65)));
      pendingRead = null;
      finishClose();
    } else if (message == 'release-close') {
      holdClose = false;
      finishClose();
    } else {
      final (operation, response) = message as (String, SendPort);
      events.send((id, operation, null));
      switch (operation) {
        case 'stat':
          response.send(true);
        case 'read':
          if (config['failRead'] == true) {
            response.send('read-error');
          } else if (holdRead) {
            pendingRead = response;
          } else if (config['readDelayMs'] case final int delay) {
            pendingRead = response;
            Timer(Duration(milliseconds: delay), () {
              pendingRead?.send(Uint8List.fromList(List.filled(64 * 1024, 65)));
              pendingRead = null;
              finishClose();
            });
          } else {
            response.send(Uint8List.fromList(List.filled(64 * 1024, 65)));
          }
        case 'close':
          pendingClose = response;
          finishClose();
      }
    }
  });
}

Future<void> _until(bool Function() ready) async {
  for (var count = 0; count < 500 && !ready(); count++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('unsupported'));

  test(
    'an SMB failure retires its parent before a retry can create another child',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final service = TextDocumentService(
        source: {'kind': 'smb', 'id': 'failed', 'events': events.sendPort},
        documentsPath: '',
        maxTextBytes: 1,
        testConnector: _connectChild,
      );
      try {
        await expectLater(
          service.load(const SourceEntry(name: 'a.txt', path: 'a.txt')),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(
          service.load(const SourceEntry(name: 'a.txt', path: 'a.txt')),
          throwsA(isA<Cancelled>()),
        );
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        expect(messages.where((m) => m.$2 == 'child'), hasLength(1));
        expect(messages.where((m) => m.$2 == 'closed'), hasLength(1));
      } finally {
        service.dispose();
        await subscription.cancel();
        events.close();
      }
    },
  );

  test(
    'SMB read error is delivered while native close is still waiting',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final service = TextDocumentService(
        source: {
          'kind': 'smb',
          'id': 'failed-read',
          'events': events.sendPort,
          'holdClose': true,
          'failRead': true,
        },
        documentsPath: '',
        testConnector: _connectChild,
      );
      try {
        await expectLater(
          service
              .load(const SourceEntry(name: 'a.txt', path: 'a.txt'))
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<AppFailure>()),
        );
        await _until(() => messages.any((m) => m.$2 == 'close'));
        expect(TextDocumentService.activeSmbWorkers, 1);
        expect(messages.where((m) => m.$2 == 'closed'), isEmpty);
        await expectLater(
          service.load(const SourceEntry(name: 'a.txt', path: 'a.txt')),
          throwsA(isA<Cancelled>()),
        );
      } finally {
        service.dispose();
        for (final message in messages.where((m) => m.$2 == 'child')) {
          (message.$3 as SendPort).send('release-close');
        }
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        await subscription.cancel();
        events.close();
      }
    },
  );

  test(
    'SMB queue timeout removes its waiter without releasing a live worker',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final services = <TextDocumentService>[];
      TextDocumentService make(String id, {bool holdClose = false}) {
        final service = TextDocumentService(
          source: {
            'kind': 'smb',
            'id': id,
            'events': events.sendPort,
            'holdClose': holdClose,
          },
          documentsPath: '',
          testConnector: _connectChild,
          smbSlotWaitTimeout: const Duration(milliseconds: 80),
        );
        services.add(service);
        return service;
      }

      const entry = SourceEntry(name: 'a.txt', path: 'a.txt');
      try {
        final first = make('one', holdClose: true),
            second = make('two', holdClose: true);
        await Future.wait([first.load(entry), second.load(entry)]);
        first.dispose();
        second.dispose();
        await _until(() => messages.where((m) => m.$2 == 'close').length == 2);
        await expectLater(
          make('expired').load(entry).timeout(const Duration(seconds: 2)),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'message',
              contains('等待超时'),
            ),
          ),
        );
        expect(TextDocumentService.waitingSmbWorkers, 0);
        expect(TextDocumentService.activeSmbWorkers, 2);
        expect(messages.where((m) => m.$1 == 'expired'), isEmpty);
        (messages.firstWhere((m) => m.$1 == 'one' && m.$2 == 'child').$3
                as SendPort)
            .send('release-close');
        await _until(() => TextDocumentService.activeSmbWorkers == 1);
        await make('retry').load(entry);
        expect(messages.where((m) => m.$1 == 'expired'), isEmpty);
      } finally {
        for (final service in services) {
          service.dispose();
        }
        for (final message in messages.where((m) => m.$2 == 'child')) {
          (message.$3 as SendPort).send('release-close');
        }
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        await subscription.cancel();
        events.close();
      }
    },
  );

  test('SMB external download reports actual transferred bytes and stops after cancel', () async {
    final root = await Directory.systemTemp.createTemp(
      'external-smb-progress-',
    );
    final events = ReceivePort();
    final messages = <(String, String, Object?)>[];
    final subscription = events.listen(
      (m) => messages.add(m as (String, String, Object?)),
    );
    final progress = <(int, int)>[];
    final service = TextDocumentService(
      source: {'kind': 'smb', 'id': 'complete', 'events': events.sendPort},
      documentsPath: root.path,
      testConnector: _connectChild,
    );
    final cancelled = TextDocumentService(
      source: {
        'kind': 'smb',
        'id': 'cancelled',
        'events': events.sendPort,
        'holdRead': true,
      },
      documentsPath: root.path,
      testConnector: _connectChild,
    );
    const entry = SourceEntry(name: 'data.unknown', path: 'data.unknown');
    try {
      final path = await service.prepareExternal(
        entry,
        cacheDirectory: root.path,
        onProgress: (received, total) => progress.add((received, total)),
      );
      expect(progress.first, (0, 128 * 1024));
      expect(progress, contains((64 * 1024, 128 * 1024)));
      expect(progress.last, (128 * 1024, 128 * 1024));
      expect(await File(path).length(), progress.last.$1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
      }
      service.dispose();
      final stoppedProgress = <(int, int)>[];
      final pending = cancelled.prepareExternal(
        entry,
        cacheDirectory: root.path,
        onProgress: (received, total) => stoppedProgress.add((received, total)),
      );
      final result = expectLater(pending, throwsA(isA<Cancelled>()));
      await _until(
        () => messages.any((m) => m.$1 == 'cancelled' && m.$2 == 'read'),
      );
      cancelled.dispose();
      final count = stoppedProgress.length;
      await result;
      (messages.firstWhere((m) => m.$1 == 'cancelled' && m.$2 == 'child').$3
              as SendPort)
          .send('release-read');
      await _until(() => TextDocumentService.activeSmbWorkers == 0);
      expect(stoppedProgress.length, count);
      expect(count, greaterThanOrEqualTo(1));
    } finally {
      service.dispose();
      cancelled.dispose();
      for (final message in messages.where((m) => m.$2 == 'child')) {
        (message.$3 as SendPort).send('release-read');
        (message.$3 as SendPort).send('release-close');
      }
      await _until(() => TextDocumentService.activeSmbWorkers == 0);
      await subscription.cancel();
      events.close();
      await root.delete(recursive: true);
    }
  });

  test('parent deadline reports a blocked native read before async stream cancellation finishes', () async {
    final events = ReceivePort();
    final messages = <(String, String, Object?)>[];
    final subscription = events.listen(
      (m) => messages.add(m as (String, String, Object?)),
    );
    final service = TextDocumentService(
      source: {
        'kind': 'smb',
        'id': 'stalled',
        'events': events.sendPort,
        'holdRead': true,
      },
      documentsPath: '',
      testConnector: _connectChild,
      requestIdleTimeout: const Duration(milliseconds: 150),
    );
    try {
      await expectLater(
        service
            .load(const SourceEntry(name: 'a.txt', path: 'a.txt'))
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('读取超时'),
          ),
        ),
      );
      await _until(() => messages.any((m) => m.$2 == 'close'));
      expect(TextDocumentService.activeSmbWorkers, 1);
      expect(messages.where((m) => m.$2 == 'closed'), isEmpty);
      expect(messages.where((m) => m.$2 == 'read'), hasLength(1));
      (messages.firstWhere((m) => m.$2 == 'child').$3 as SendPort).send(
        'release-read',
      );
      await _until(() => TextDocumentService.activeSmbWorkers == 0);
      await expectLater(
        service.load(const SourceEntry(name: 'a.txt', path: 'a.txt')),
        throwsA(isA<Cancelled>()),
      );
      expect(messages.where((m) => m.$2 == 'read'), hasLength(1));
    } finally {
      service.dispose();
      for (final message in messages.where((m) => m.$2 == 'child')) {
        (message.$3 as SendPort).send('release-read');
        (message.$3 as SendPort).send('release-close');
      }
      await _until(() => TextDocumentService.activeSmbWorkers == 0);
      await subscription.cancel();
      events.close();
    }
  });

  for (final external in [false, true]) {
    test(
      '${external ? "external progress" : "text read activity"} refreshes the idle deadline without polling',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'smb-deadline-progress-',
        );
        final events = ReceivePort();
        final messages = <(String, String, Object?)>[];
        final subscription = events.listen(
          (m) => messages.add(m as (String, String, Object?)),
        );
        final service = TextDocumentService(
          source: {
            'kind': 'smb',
            'id': 'progressing',
            'events': events.sendPort,
            'size': 384 * 1024,
            'readDelayMs': 120,
          },
          documentsPath: root.path,
          testConnector: _connectChild,
          requestIdleTimeout: const Duration(milliseconds: 500),
        );
        final progress = <(int, int)>[];
        const entry = SourceEntry(name: 'data.bin', path: 'data.bin');
        try {
          final elapsed = Stopwatch()..start();
          if (external) {
            final path = await service.prepareExternal(
              entry,
              cacheDirectory: root.path,
              onProgress: (received, total) => progress.add((received, total)),
            );
            expect(await File(path).length(), 384 * 1024);
            expect(progress.last, (384 * 1024, 384 * 1024));
            expect(progress.length, lessThan(8));
          } else {
            await service.load(entry);
          }
          expect(elapsed.elapsedMilliseconds, greaterThan(500));
          // A completed request must not leave an idle timer that retires its
          // reusable worker while the user is simply reading the document.
          await Future<void>.delayed(const Duration(milliseconds: 550));
          await service.search('nothing');
        } finally {
          service.dispose();
          await _until(() => TextDocumentService.activeSmbWorkers == 0);
          await subscription.cancel();
          events.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'disposed request ignores late activity and never rearms its deadline',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final service = TextDocumentService(
        source: {
          'kind': 'smb',
          'id': 'disposed',
          'events': events.sendPort,
          'holdRead': true,
        },
        documentsPath: '',
        testConnector: _connectChild,
        requestIdleTimeout: const Duration(milliseconds: 150),
      );
      final pending = service.load(
        const SourceEntry(name: 'a.txt', path: 'a.txt'),
      );
      final result = expectLater(pending, throwsA(isA<Cancelled>()));
      try {
        await _until(() => messages.any((m) => m.$2 == 'read'));
        service.dispose();
        await result;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(TextDocumentService.activeSmbWorkers, 1);
        (messages.firstWhere((m) => m.$2 == 'child').$3 as SendPort).send(
          'release-read',
        );
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await expectLater(
          service.load(const SourceEntry(name: 'a.txt', path: 'a.txt')),
          throwsA(isA<Cancelled>()),
        );
        expect(messages.where((m) => m.$2 == 'read'), hasLength(1));
        expect(messages.where((m) => m.$2 == 'close'), hasLength(1));
      } finally {
        service.dispose();
        for (final message in messages.where((m) => m.$2 == 'child')) {
          (message.$3 as SendPort).send('release-read');
        }
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        await subscription.cancel();
        events.close();
      }
    },
  );

  test('stop closes an SMB connection that finishes opening late', () async {
    final events = ReceivePort();
    final messages = <(String, String, Object?)>[];
    final subscription = events.listen(
      (m) => messages.add(m as (String, String, Object?)),
    );
    final service = TextDocumentService(
      source: {
        'kind': 'smb',
        'id': 'late',
        'events': events.sendPort,
        'holdOpening': true,
      },
      documentsPath: '',
      testConnector: _connectChild,
    );
    final load = service.load(const SourceEntry(name: 'a.txt', path: 'a.txt'));
    final cancelled = expectLater(load, throwsA(isA<Cancelled>()));
    try {
      await _until(() => messages.any((m) => m.$2 == 'opening'));
      service.dispose();
      await cancelled;
      expect(TextDocumentService.activeSmbWorkers, 1);
      (messages.firstWhere((m) => m.$2 == 'opening').$3 as SendPort).send(
        'connect',
      );
      await _until(() => messages.any((m) => m.$2 == 'closed'));
      await _until(() => TextDocumentService.activeSmbWorkers == 0);
      expect(messages.where((m) => m.$2 == 'stat' || m.$2 == 'read'), isEmpty);
    } finally {
      service.dispose();
      await subscription.cancel();
      events.close();
    }
  });

  test(
    'stop lets one native SMB read finish and closes its child without refill',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final service = TextDocumentService(
        source: {
          'kind': 'smb',
          'id': 'read',
          'events': events.sendPort,
          'holdRead': true,
        },
        documentsPath: '',
        testConnector: _connectChild,
      );
      final load = service.load(
        const SourceEntry(name: 'a.txt', path: 'a.txt'),
      );
      final cancelled = expectLater(load, throwsA(isA<Cancelled>()));
      try {
        await _until(() => messages.any((m) => m.$2 == 'read'));
        service.dispose();
        await cancelled;
        await _until(() => messages.any((m) => m.$2 == 'close'));
        expect(TextDocumentService.activeSmbWorkers, 1);
        (messages.firstWhere((m) => m.$2 == 'child').$3 as SendPort).send(
          'release-read',
        );
        await _until(() => messages.any((m) => m.$2 == 'closed'));
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
        expect(messages.where((m) => m.$2 == 'read'), hasLength(1));
      } finally {
        service.dispose();
        await subscription.cancel();
        events.close();
      }
    },
  );

  test(
    'closing SMB workers retain two slots and cancelled waiters do not start',
    () async {
      final events = ReceivePort();
      final messages = <(String, String, Object?)>[];
      final subscription = events.listen(
        (m) => messages.add(m as (String, String, Object?)),
      );
      final services = <TextDocumentService>[];
      TextDocumentService make(String id, {bool holdClose = false}) {
        final service = TextDocumentService(
          source: {
            'kind': 'smb',
            'id': id,
            'events': events.sendPort,
            'holdClose': holdClose,
          },
          documentsPath: '',
          testConnector: _connectChild,
        );
        services.add(service);
        return service;
      }

      const entry = SourceEntry(name: 'a.txt', path: 'a.txt');
      try {
        final first = make('first', holdClose: true),
            second = make('second', holdClose: true);
        await Future.wait([first.load(entry), second.load(entry)]);
        first.dispose();
        second.dispose();
        await _until(() => messages.where((m) => m.$2 == 'close').length == 2);
        expect(TextDocumentService.activeSmbWorkers, 2);
        final third = make('cancelled');
        final cancelled = expectLater(
          third.load(entry),
          throwsA(isA<Cancelled>()),
        );
        await _until(() => TextDocumentService.waitingSmbWorkers == 1);
        third.dispose();
        await cancelled;
        expect(TextDocumentService.waitingSmbWorkers, 0);
        final fourth = make('resumed');
        final resumed = fourth.load(entry);
        await _until(() => TextDocumentService.waitingSmbWorkers == 1);
        (messages.firstWhere((m) => m.$1 == 'first' && m.$2 == 'child').$3
                as SendPort)
            .send('release-close');
        await resumed;
        expect(TextDocumentService.activeSmbWorkers, 2);
        expect(messages.where((m) => m.$1 == 'cancelled'), isEmpty);
        fourth.dispose();
        (messages.firstWhere((m) => m.$1 == 'second' && m.$2 == 'child').$3
                as SendPort)
            .send('release-close');
        await _until(() => TextDocumentService.activeSmbWorkers == 0);
      } finally {
        for (final service in services) {
          service.dispose();
        }
        for (final message in messages.where((m) => m.$2 == 'child')) {
          (message.$3 as SendPort).send('release-close');
        }
        await subscription.cancel();
        events.close();
      }
    },
  );
}
