import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/record_keys.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'playback-worker-test-token-with-24-characters';

void main() {
  // Keep the real loopback transport: a widget binding replaces HttpClient.
  test(
    'playback worker uploads only video state and leaves downloads pending',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      device.progress(60);
      device.store.save('watched', 'episode', {'watched': true});
      device.store.setLocal('syncCursor:${server.origin}', 7);
      for (final kind in ['vault', 'match']) {
        device.store.db.execute(
          'INSERT INTO records(kind,id,dirty,data) VALUES(?,?,1,?)',
          [kind, 'unread-payload', 'intentionally not JSON'],
        );
        device.store.db.execute(
          'INSERT INTO conflicts(kind,id,remote) VALUES(?,?,?)',
          [kind, 'unread-conflict', 'intentionally not JSON'],
        );
      }

      await device.sync();

      expect(server.requests.map((request) => request.method), ['PUT', 'PUT']);
      expect(server.uploads.map((record) => record['kind']), [
        'progress',
        'watched',
      ]);
      expect(device.store.local('syncCursor:${server.origin}'), 7);
      expect(device.store.local('lastSync'), isA<String>());
      expect(device.store.get('progress', 'video:100')!.dirty, isFalse);
      expect(device.store.get('watched', 'episode')!.dirty, isFalse);
      expect(
        device.store.db
            .select('SELECT count(*) AS n FROM conflicts')
            .single['n'],
        2,
      );
      expect(
        device.store.db
            .select('SELECT count(*) AS n FROM records WHERE dirty=1')
            .single['n'],
        2,
      );
    },
  );

  test(
    'worker respects private media ownership for progress and watched state',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server, withProfile: true);
      final watched = <String, String>{};
      final ids = [
        'remote',
        'remembered-remote',
        'local',
        'private',
        'transient',
        'remembered-local',
      ];
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        device.store.save('media', id, {
          'tmdbId': index + 1,
          'metadataType': 'tv',
          'season': 1,
          'episode': 1,
          if (id == 'private') 'localOnly': true,
          if (id == 'transient') 'transient': true,
        });
        if (!id.startsWith('remembered-')) {
          device.store.setLocal('location:$id', {
            'source': id == 'local' ? 'local' : 'nas',
            'path': '$id.mkv',
          });
        }
        watched[id] = mediaWatchedKey(device.store.get('media', id)!);
        device.store.save('progress', '$id:100', {'position': 50});
        device.store.save('watched', watched[id]!, {'watched': true});
      }
      device.store.setLocal('syncProfile:remoteMedia', ['remembered-remote']);
      device.store.setLocal('syncProfile:localMedia', ['remembered-local']);

      await device.sync();

      expect(
        server.uploads
            .map((record) => '${record['kind']}:${record['id']}')
            .toSet(),
        {
          'progress:remote:100',
          'progress:remembered-remote:100',
          'watched:${watched['remote']}',
          'watched:${watched['remembered-remote']}',
        },
      );
      for (final id in ids.skip(2)) {
        expect(device.store.get('progress', '$id:100')!.dirty, isTrue);
        expect(device.store.get('watched', watched[id]!)!.dirty, isTrue);
      }
      expect(device.store.local('syncCursor:${server.origin}'), isNull);
    },
  );

  test(
    'delayed acknowledgement preserves a newer backward seek from another worker',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.beforeAck = (_) async {
        server.beforeAck = null;
        entered.complete();
        await release.future;
      };
      device.progress(600);
      final first = device.sync();
      await entered.future.timeout(const Duration(seconds: 5));
      await device.store.savePlaybackProgress('video:100', {
        'position': 90,
        'duration': 1000,
        'updatedAt': '2026-10-23T12:00:02Z',
      });
      release.complete();
      await first;

      final retained = device.store.get('progress', 'video:100')!;
      expect(retained.data['position'], 90);
      expect(retained.dirty, isTrue);
      expect(retained.version, 1);
      await device.sync();
      expect(
        server.uploads.map((record) => (record['data'] as Map)['position']),
        [600, 90],
      );
      expect(device.store.get('progress', 'video:100')!.dirty, isFalse);
      expect(device.store.get('progress', 'video:100')!.version, 2);
    },
  );

  test(
    'cancellation interrupts the worker request without acknowledging progress',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.beforeAck = (_) async {
        entered.complete();
        await release.future;
      };
      device.progress(60);
      final cancel = CancelToken();
      final syncing = device.sync(cancel: cancel);
      await entered.future.timeout(const Duration(seconds: 5));
      final cancelled = expectLater(
        syncing.timeout(const Duration(seconds: 2)),
        throwsA(isA<Cancelled>()),
      );
      cancel.cancel();
      await cancelled;

      expect(device.store.get('progress', 'video:100')!.dirty, isTrue);
      expect(device.store.get('progress', 'video:100')!.version, 0);
      expect(device.store.local('lastSync'), isNull);
      release.complete();
    },
  );

  test(
    'SQLite acknowledgement waits leave the main isolate timer responsive',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      device.progress(60);
      var locked = false, timerTicks = 0;
      Timer? unlock;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (locked) timerTicks++;
      });
      addTearDown(() {
        heartbeat.cancel();
        unlock?.cancel();
        if (locked) device.store.db.execute('ROLLBACK');
      });
      server.beforeAck = (_) async {
        device.store.db.execute('BEGIN IMMEDIATE');
        locked = true;
        unlock = Timer(const Duration(milliseconds: 180), () {
          device.store.db.execute('COMMIT');
          locked = false;
        });
      };

      final elapsed = Stopwatch()..start();
      try {
        await device.sync().timeout(const Duration(seconds: 4));
      } catch (error) {
        fail(
          '$error; elapsed=${elapsed.elapsedMilliseconds} ms, '
          'timerTicks=$timerTicks, locked=$locked',
        );
      }

      expect(locked, isFalse);
      expect(timerTicks, greaterThanOrEqualTo(3));
      expect(device.store.get('progress', 'video:100')!.dirty, isFalse);
    },
  );

  test('cancellation stops a pending SQLite acknowledgement retry', () async {
    final server = await _Server.start();
    final device = await _Device.open(server);
    final cancel = CancelToken();
    device.progress(60);
    var locked = false;
    Timer? cancellation;
    addTearDown(() {
      cancellation?.cancel();
      if (locked) device.store.db.execute('ROLLBACK');
    });
    server.beforeAck = (_) async {
      device.store.db.execute('BEGIN IMMEDIATE');
      locked = true;
      cancellation = Timer(const Duration(milliseconds: 80), cancel.cancel);
    };

    await expectLater(
      device.sync(cancel: cancel).timeout(const Duration(seconds: 2)),
      throwsA(isA<Cancelled>()),
    );

    expect(locked, isTrue);
    device.store.db.execute('COMMIT');
    locked = false;
    expect(device.store.get('progress', 'video:100')!.dirty, isTrue);
    expect(device.store.get('progress', 'video:100')!.version, 0);
    expect(device.store.local('lastSync'), isNull);
    expect(server.uploads, hasLength(1));
  });
}

class _Device {
  final AppStore store;
  final _Server server;
  late final SyncClient client;

  _Device(this.store, this.server, bool withProfile) {
    client = SyncClient(
      store,
      profile: withProfile
          ? SyncProfile(
              store,
              const FlutterSecureStorage(),
              watchedKey: mediaWatchedKey,
            )
          : null,
    );
  }

  static Future<_Device> open(
    _Server server, {
    bool withProfile = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp('playback-sync-');
    final store = AppStore('${directory.path}/app.db');
    addTearDown(() async {
      store.dispose();
      await directory.delete(recursive: true);
    });
    return _Device(store, server, withProfile);
  }

  void progress(int position) => store.save('progress', 'video:100', {
    'position': position,
    'duration': 1000,
    'updatedAt': '2026-10-23T12:00:00Z',
  });

  Future<void> sync({CancelToken? cancel}) => client.synchronize(
    server.origin,
    _token,
    cancel: cancel,
    playbackOnly: true,
  );
}

class _Server {
  final HttpServer server;
  final requests = <HttpRequest>[];
  final uploads = <Map<String, dynamic>>[];
  Future<void> Function(Map<String, dynamic>)? beforeAck;

  _Server(this.server);

  String get origin => 'http://127.0.0.1:${server.port}';

  static Future<_Server> start() async {
    final server = _Server(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.server.listen((request) => unawaited(server.handle(request)));
    addTearDown(() => server.server.close(force: true));
    return server;
  }

  Future<void> handle(HttpRequest request) async {
    requests.add(request);
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'PUT' && request.uri.path == '/v1/records') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      uploads.add(body);
      await beforeAck?.call(body);
      request.response.write(
        jsonEncode({...body, 'version': (body['version'] as int) + 1}),
      );
    } else {
      request.response.write(
        jsonEncode({'changes': [], 'cursor': 99, 'hasMore': false}),
      );
    }
    try {
      await request.response.close();
    } on HttpException {
      // The cancellation test intentionally disconnects before the response.
    }
  }
}
