import 'dart:async';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _origin = 'https://sync.example.com';
const _token = 'realtime-sync-token-with-at-least-24-characters';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('progress sync never decodes skipped pending vault payloads', () async {
    final server = _Server();
    final device = _Device(server);
    device.store.db.execute(
      'INSERT INTO records(kind,id,dirty,data) VALUES(?,?,1,?)',
      ['vault', 'unread-artwork', 'intentionally not JSON'],
    );
    device.progress(40, '2026-10-22T12:00:00Z');
    await device.sync();
    expect(server.records['progress:video:10']!.data['position'], 40);
    expect(server.records.keys.any((key) => key.startsWith('vault:')), false);
    expect(device.profile.prepares, 0);
  });

  test(
    'binding eligibility reuses sets and observes changed local ownership',
    () {
      final store = _BindingCountingStore();
      addTearDown(store.dispose);
      final profile = SyncProfile(
        store,
        const FlutterSecureStorage(),
        watchedKey: (record) => record.id,
      );
      store.setLocal('syncProfile:remoteMedia', ['remote']);
      const progress = SyncRecord(kind: 'progress', id: 'remote:10', data: {});
      for (var index = 0; index < 100; index++) {
        expect(profile.shouldUpload(progress), true);
        expect(profile.shouldReceive(progress), true);
      }
      expect(store.bindingReads, 2);
      profile.rememberLocalMedia('remote');
      expect(profile.shouldUpload(progress), false);
      expect(profile.shouldReceive(progress), false);
      profile.rememberRemoteMedia('remote');
      expect(profile.shouldUpload(progress), true);
      expect(profile.shouldReceive(progress), true);
      store.setLocal('location:remote', {'source': 'local'});
      expect(profile.shouldUpload(progress), false);
      expect(profile.shouldReceive(progress), false);
    },
  );

  test(
    'lightweight sync protects a remote video just associated with a local file',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.client.synchronize(_origin, _token);
      device.store.setLocal('location:video', {
        'id': 'video',
        'source': 'local',
        'path': '/private/file.mkv',
        'size': 10,
      });
      device.store.save('watched', 'video', {'watched': true});
      device.progress(40, '2026-10-22T12:00:00Z');
      await device.sync();
      expect(server.records['watched:video'], isNull);
      expect(server.records['progress:video:10'], isNull);
    },
  );

  test(
    'long polling runs beside uploads and leaves the cursor to synchronization',
    () async {
      final server = _Server();
      final device = _Device(server);
      final waiting = Completer<void>(), release = Completer<void>();
      server.before = (uri, method) async {
        if (uri.queryParameters['wait'] != null) {
          expect(uri.queryParameters, {'after': '0', 'wait': '20'});
          waiting.complete();
          await release.future;
        }
      };
      final listener = device.client.waitForChanges(_origin, _token);
      await waiting.future;
      device.progress(25, '2026-10-22T12:00:00Z');
      await device.sync();
      final cursor = device.store.local('syncCursor:$_origin');
      expect(cursor, greaterThan(0));
      release.complete();
      expect(await listener, true);
      expect(device.store.local('syncCursor:$_origin'), cursor);
      expect(device.store.get('progress', 'video:10')!.dirty, false);
    },
  );

  test(
    'lightweight first sync uploads a new remote location without staging settings or local media',
    () async {
      final server = _Server();
      final device = _Device(server);
      device.store.setLocal('settings', {'playbackRate': 1.5});
      device.store.save('media', 'local-video', {'title': 'private'});
      device.store.setLocal('location:local-video', {
        'id': 'local-video',
        'source': 'local',
        'path': '/private/video',
      });
      device.progress(40, '2026-10-22T12:00:00Z');
      await device.sync();
      expect(server.records['progress:video:10']!.data['position'], 40);
      expect(server.records.keys.any((key) => key.startsWith('vault:')), false);
      expect(server.records.containsKey('media:local-video'), false);
      expect(device.profile.prepares, 0);
      expect(device.profile.applies, 0);
      await device.client.synchronize(_origin, _token);
      expect(device.profile.prepares, 1);
      expect(server.records.keys.any((key) => key.startsWith('vault:')), true);
    },
  );

  test(
    'queued synchronization uploads an edit made while its predecessor is in flight',
    () async {
      final server = _Server();
      final device = _Device(server);
      final entered = Completer<void>(), release = Completer<void>();
      server.before = (uri, method) async {
        if (method == 'PUT' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      device.progress(20, '2026-10-22T12:00:00Z');
      final first = device.sync();
      await entered.future;
      device.progress(30, '2026-10-22T12:00:02Z');
      final queued = device.sync();
      release.complete();
      await Future.wait([first, queued]);
      expect(server.records['progress:video:10']!.data['position'], 30);
      expect(device.store.get('progress', 'video:10')!.dirty, false);
      expect(server.activePuts, 0);
      expect(server.maxPuts, 1);
    },
  );

  test(
    'latest timestamp wins progress conflicts even when the newest action seeks backwards',
    () async {
      final server = _Server();
      final first = _Device(server), second = _Device(server);
      first.progress(600, '2026-10-22T12:00:00Z');
      await first.sync();
      await second.sync();
      first.progress(800, '2026-10-22T12:00:01Z');
      second.progress(100, '2026-10-22T12:00:02Z');
      await first.sync();
      await second.sync();
      expect(server.records['progress:video:10']!.data['position'], 100);
      first.progress(900, '2026-10-22T12:00:01.500Z');
      await first.sync();
      expect(first.store.get('progress', 'video:10')!.data['position'], 100);
      expect(first.store.conflicts.where((r) => r.kind == 'progress'), isEmpty);
      expect(
        second.store.conflicts.where((r) => r.kind == 'progress'),
        isEmpty,
      );
    },
  );

  test(
    'a local progress edit during download survives and is sent on the next sync',
    () async {
      final server = _Server();
      final first = _Device(server), second = _Device(server);
      first.progress(600, '2026-10-22T12:00:00Z');
      await first.sync();
      await second.sync();
      first.progress(800, '2026-10-22T12:00:01Z');
      await first.sync();
      server.before = (uri, method) async {
        if (method == 'GET') {
          server.before = null;
          second.progress(50, '2026-10-22T12:00:02Z');
        }
      };
      await second.sync();
      expect(second.store.get('progress', 'video:10')!.data['position'], 50);
      expect(
        second.store.conflicts.where((r) => r.kind == 'progress'),
        isEmpty,
      );
      await second.sync();
      expect(server.records['progress:video:10']!.data['position'], 50);
    },
  );

  test(
    'progress without payload timestamps uses its record edit time',
    () async {
      final server = _Server();
      final first = _Device(server), second = _Device(server);
      first.store.save('progress', 'video:10', {'position': 5});
      await first.sync();
      second.store.save('progress', 'video:10', {'position': 7});
      await second.sync();
      expect(
        second.store.conflicts.where((record) => record.kind == 'progress'),
        isEmpty,
      );
    },
  );

  test(
    'shared polling applies newly downloaded vault entries without preparing local settings',
    () async {
      final server = _Server();
      final first = _Device(server), second = _Device(server);
      first.store.setLocal('settings', {'playbackRate': 1.5});
      await first.client.synchronize(_origin, _token);
      await second.sync();
      expect(second.store.local('settings'), {'playbackRate': 1.5});
      expect(second.profile.prepares, 0);
      expect(second.profile.applies, 1);
      await second.sync();
      expect(
        second.profile.applies,
        1,
        reason:
            'unchanged lightweight polls skip encrypted snapshots and artwork',
      );
    },
  );
}

class _BindingCountingStore extends AppStore {
  int bindingReads = 0;
  _BindingCountingStore() : super(':memory:');

  @override
  dynamic local(String key) {
    if (key == 'syncProfile:remoteMedia' || key == 'syncProfile:localMedia') {
      bindingReads++;
    }
    return super.local(key);
  }
}

class _Device {
  final store = AppStore(':memory:');
  late final _Profile profile = _Profile(store);
  late final SyncClient client;
  _Device(_Server server) {
    addTearDown(store.dispose);
    client = SyncClient(store, profile: profile, transport: server);
    store.save('media', 'video', {'title': 'Remote video', 'size': 10});
    store.setLocal('location:video', {
      'id': 'video',
      'source': 'nas',
      'path': 'video.mkv',
      'size': 10,
    });
  }
  void progress(double value, String timestamp) => store.save(
    'progress',
    'video:10',
    {'position': value, 'duration': 1000, 'updatedAt': timestamp},
  );
  Future<void> sync() => client.synchronize(_origin, _token, sharedOnly: true);
}

class _Profile extends SyncProfile {
  int prepares = 0, applies = 0;
  _Profile(AppStore store)
    : super(
        store,
        const FlutterSecureStorage(),
        watchedKey: (record) => record.id,
      );
  @override
  Future<void> prepare({CancelToken? cancel}) async {
    prepares++;
    await super.prepare();
  }

  @override
  Future<void> apply({String? forceId, CancelToken? cancel}) async {
    applies++;
    await super.apply(forceId: forceId);
  }
}

class _Server implements JsonTransport {
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];
  int activePuts = 0, maxPuts = 0;
  Future<void> Function(Uri, String)? before;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    if (method == 'PUT') {
      activePuts++;
      if (activePuts > maxPuts) maxPuts = activePuts;
    }
    try {
      await before?.call(uri, method);
      cancel?.check();
      if (method == 'PUT') {
        final incoming = SyncRecord.fromJson(body!);
        final key = '${incoming.kind}:${incoming.id}';
        final current = records[key];
        if (incoming.version != (current?.version ?? 0)) {
          return {'_status': 409, 'current': current!.toJson()};
        }
        final accepted = SyncRecord(
          id: incoming.id,
          kind: incoming.kind,
          modifiedAt: incoming.modifiedAt,
          deviceId: incoming.deviceId,
          deviceName: incoming.deviceName,
          data: incoming.data,
          version: incoming.version + 1,
          deleted: incoming.deleted,
        );
        records[key] = accepted;
        changes.add(accepted);
        return accepted.toJson();
      }
      final after = int.parse(uri.queryParameters['after']!);
      return {
        'changes': changes.skip(after).map((r) => r.toJson()).toList(),
        'cursor': changes.length,
        'hasMore': false,
      };
    } finally {
      if (method == 'PUT') activePuts--;
    }
  }
}
