import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'danmu_test.dart' show FakeTransport;

void main() {
  testWidgets('native device details label edits already waiting to upload', (
    tester,
  ) async {
    final db = AppStore(':memory:');
    addTearDown(db.dispose);
    db.save('media', 'video', {
      'title': 'Movie',
    }, modifiedAt: '2026-10-22T12:00:00Z');
    const channel = MethodChannel('app.aiplayer/device_info');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'name': '客厅平板',
        'platform': 'Android',
        'model': 'Google Pixel Tablet',
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.runAsync(() => SyncClient(db).readDeviceInfo());
    expect(db.deviceName, '客厅平板 · Google Pixel Tablet · Android');
    expect(db.pending.single.deviceName, db.deviceName);
    expect(db.pending.single.modifiedAt, '2026-10-22T12:00:00Z');
  });

  test(
    'favorite edit clocks do not change when a different folder is edited',
    () {
      final db = AppStore(':memory:');
      addTearDown(db.dispose);
      final first = {'sourceId': 'nas', 'path': 'Shows', 'name': 'Shows'};
      db.setLocal('sourceFavorites', [first]);
      db.markLocalModified(
        'favorite:nas\u0000Shows',
        at: '2026-10-22T12:00:00Z',
      );
      db.setLocal('sourceFavorites', [
        first,
        {'sourceId': 'nas', 'path': 'Movies', 'name': 'Movies'},
      ]);
      expect(
        db.localModified('favorite:nas\u0000Shows'),
        '2026-10-22T12:00:00Z',
      );
      expect(db.localModified('favorite:nas\u0000Movies'), isNotNull);
    },
  );

  test('existing conflicts are resolved together using edit clocks', () async {
    final db = AppStore(':memory:');
    addTearDown(db.dispose);
    for (var index = 0; index < 40; index++) {
      db.save(
        'media',
        'item-$index',
        {'title': 'local'},
        modifiedAt: index.isEven
            ? '2026-10-22T12:00:03Z'
            : '2026-10-22T12:00:01Z',
      );
      db.conflict(
        SyncRecord(
          kind: 'media',
          id: 'item-$index',
          version: 4,
          modifiedAt: '2026-10-22T12:00:02Z',
          deviceName: 'Living room Mac · macOS',
          data: const {'title': 'remote'},
        ),
      );
    }
    final transport = FakeTransport(
      (uri, method, body, cancel) async => method == 'PUT'
          ? {...body!, 'version': 5}
          : {'changes': [], 'cursor': 0, 'hasMore': false},
    );
    await SyncClient(db, transport: transport).synchronize(
      'https://sync.example.com',
      'token-with-at-least-24-characters',
    );
    expect(db.conflicts, isEmpty);
    expect(db.pending, isEmpty);
    for (var index = 0; index < 40; index++) {
      final record = db.get('media', 'item-$index')!;
      expect(record.data['title'], index.isEven ? 'local' : 'remote');
      if (index.isOdd) expect(record.deviceName, 'Living room Mac · macOS');
    }
  });

  test('equal edit clocks converge with deletion and device tie breakers', () {
    SyncRecord record(String device, {bool deleted = false}) => SyncRecord(
      kind: 'media',
      id: 'video',
      data: const {},
      deviceId: device,
      modifiedAt: '2026-10-22T12:00:00Z',
      deleted: deleted,
    );
    expect(newerLocalRecord(record('b'), record('a')), isTrue);
    expect(newerLocalRecord(record('a'), record('b')), isFalse);
    expect(newerLocalRecord(record('a', deleted: true), record('b')), isTrue);
    expect(newerLocalRecord(record('b'), record('a', deleted: true)), isFalse);
  });

  test(
    'location lookup follows updates, duplicate associations and rollback',
    () {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      store.setLocal('location:one', {
        'id': 'one',
        'source': 'nas',
        'path': 'a',
      });
      expect(store.locationFor('nas', 'a')?['id'], 'one');
      store.setLocal('location:two', {
        'id': 'two',
        'source': 'nas',
        'path': 'a',
      });
      expect(store.locationFor('nas', 'a')?['id'], 'two');
      store.removeLocal('location:two');
      expect(store.locationFor('nas', 'a')?['id'], 'one');
      store.setLocal('location:one', {
        'id': 'one',
        'source': 'nas',
        'path': 'b',
      });
      expect(store.locationFor('nas', 'a'), isNull);
      expect(store.locationFor('nas', 'b')?['id'], 'one');
      expect(
        () => store.transaction(() {
          store.removeLocal('location:one');
          expect(store.locationFor('nas', 'b'), isNull);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(store.locationFor('nas', 'b')?['id'], 'one');
    },
  );

  test(
    'successful cache persists, empty replies retry, and local data stays private',
    () {
      final db = AppStore(':memory:'), now = DateTime.utc(2026, 1, 1);
      db.cache('k', [1], now: now);
      expect(db.cached('k', now: now.add(const Duration(hours: 11))), [1]);
      expect(db.cached('k', now: now.add(const Duration(days: 3650))), [1]);
      db.cache('empty', []);
      expect(db.cached('empty'), isNull);
      db.setLocal('location:1', {'path': '/private/movie.mkv'});
      db.save('media', '1', {'title': 'movie'});
      expect(
        db.pending.single.toJson().toString(),
        isNot(contains('/private')),
      );
      db.save('media', '1', {}, deleted: true);
      expect(db.all('media'), isEmpty);
      expect(db.pending.single.deleted, true);
      db.dispose();
    },
  );
  test('ack does not discard an edit made while upload is in flight', () {
    final db = AppStore(':memory:');
    db.save('progress', 'v', {'position': 10});
    final sent = db.pending.single;
    db.save('progress', 'v', {'position': 20});
    db.acknowledge(
      sent,
      const SyncRecord(
        id: 'v',
        kind: 'progress',
        data: {'position': 10},
        version: 1,
      ),
    );
    expect(db.pending.single.version, 1);
    expect(db.pending.single.data['position'], 20);
    db.dispose();
  });
  test('conflict keeps local record until explicit resolution', () {
    final db = AppStore(':memory:');
    db.save('progress', 'v', {'position': 10});
    const remote = SyncRecord(
      id: 'v',
      kind: 'progress',
      data: {'position': 20},
      version: 2,
    );
    db.applyRemote(remote);
    expect(db.get('progress', 'v')!.data['position'], 10);
    expect(db.pending, isEmpty);
    expect(db.conflicts.length, 1);
    db.resolve(remote, keepLocal: true);
    expect(db.pending.single.version, 2);
    expect(db.pending.single.data['position'], 10);
    db.conflict(remote);
    db.resolve(remote, keepLocal: false);
    expect(db.get('progress', 'v')!.data['position'], 20);
    expect(db.pending, isEmpty);
    db.dispose();
  });
  test(
    'sync uploads only shared records and follows incremental cursor',
    () async {
      final db = AppStore(':memory:');
      db.setLocal('location:1', {'password': 'private'});
      db.save('media', '1', {'title': 'movie'});
      var pages = 0;
      final transport = FakeTransport((uri, method, body, cancel) async {
        if (method == 'PUT') {
          expect(body.toString(), isNot(contains('private')));
          return {...body!, 'version': 1};
        }
        pages++;
        return {
          'changes': [
            {
              'id': '1',
              'kind': 'media',
              'version': 1,
              'deleted': false,
              'data': {'title': 'movie'},
            },
          ],
          'cursor': 1,
          'hasMore': false,
        };
      });
      await SyncClient(db, transport: transport).synchronize(
        'https://sync.example.com',
        'token-with-at-least-24-characters',
      );
      expect(db.pending, isEmpty);
      expect(db.local('syncCursor:https://sync.example.com'), 1);
      expect(pages, 1);
      db.dispose();
    },
  );
}
