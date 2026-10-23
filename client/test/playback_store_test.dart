import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late AppStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('playback-store-');
    store = AppStore('${directory.path}/app.db');
  });

  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'a blocked checkpoint leaves the main event loop free and preserves seek order',
    () async {
      final lock = sqlite3.open(store.path);
      var locked = true;
      lock.execute('BEGIN IMMEDIATE');
      final release = Timer(const Duration(milliseconds: 250), () {
        lock.execute('COMMIT');
        locked = false;
      });
      try {
        final first = store.savePlaybackProgress('video:100', _progress(80));
        final second = store.savePlaybackProgress('video:100', _progress(10));
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(locked, isFalse);
        final saved = store.get('progress', 'video:100')!;
        expect(saved.data['position'], 10);
        expect(saved.revision, 2);
        expect(saved.dirty, isTrue);
      } finally {
        release.cancel();
        if (locked) lock.execute('ROLLBACK');
        lock.dispose();
      }
    },
  );

  test(
    'queued checkpoints capture their input and avoid unchanged writes',
    () async {
      final data = _progress(50);
      final pending = store.savePlaybackProgress('video:100', data);
      data['position'] = 99;
      expect(await pending, isTrue);
      final saved = store.get('progress', 'video:100')!;
      expect(saved.data['position'], 50);
      expect(
        await store.savePlaybackProgress('video:100', {
          ..._progress(50),
          'updatedAt': '2026-10-23T12:01:00Z',
        }),
        isFalse,
      );
      expect(store.get('progress', 'video:100')!.revision, saved.revision);
      expect(
        store.get('progress', 'video:100')!.data['updatedAt'],
        saved.data['updatedAt'],
      );
      expect(
        await store.savePlaybackProgress(
          'video:100',
          _progress(50),
          watchedId: 'episode',
        ),
        isTrue,
      );
      expect(store.get('watched', 'episode')!.data['watched'], isTrue);
      expect(
        await store.savePlaybackProgress(
          'video:100',
          _progress(50),
          watchedId: 'episode',
        ),
        isFalse,
      );
    },
  );

  test(
    'failed writes are reported and do not poison later checkpoints',
    () async {
      store.db.execute('''
      CREATE TRIGGER reject_checkpoint BEFORE INSERT ON records
      WHEN NEW.kind='watched' AND NEW.id='episode'
      BEGIN SELECT RAISE(ABORT,'checkpoint rejected'); END
    ''');
      final failed = expectLater(
        store.savePlaybackProgress(
          'video:100',
          _progress(13),
          watchedId: 'episode',
        ),
        throwsA(isA<SqliteException>()),
      );
      final recovered = store.savePlaybackProgress('video:100', _progress(14));
      await failed;
      expect(await recovered, isTrue);
      final saved = store.get('progress', 'video:100')!;
      expect(saved.data['position'], 14);
      expect(
        saved.revision,
        1,
        reason: 'the failed watched write rolls progress back',
      );
      expect(store.get('watched', 'episode'), isNull);
    },
  );

  test(
    'worker progress and sync bookkeeping keep media snapshots fresh',
    () async {
      store.save('media', 'video', {'title': 'Example'});
      final media = store.recordsRevision('media');
      final location = store.locationRevision;
      final settings = store.localKeyRevision('settings');
      final progress = store.recordsRevision('progress');
      final watched = store.recordsRevision('watched');
      final heartbeat = store.localKeyRevision('lastSync');
      expect(
        await store.savePlaybackProgress(
          'video:100',
          _progress(98),
          watchedId: 'episode',
        ),
        isTrue,
      );
      final worker = AppStore.openExisting(store.path);
      try {
        worker.setLocal('syncOrigin', 'https://sync.example');
        worker.setLocal('lastSync', '2026-10-23T12:00:00Z');
        worker.acknowledge(
          worker.get('progress', 'video:100')!,
          const SyncRecord(
            kind: 'progress',
            id: 'video:100',
            data: {},
            version: 1,
          ),
        );
      } finally {
        worker.dispose();
      }
      expect(store.recordsRevision('media'), media);
      expect(store.locationRevision, location);
      expect(store.localKeyRevision('settings'), settings);
      expect(store.localKeyRevision('lastSync'), greaterThan(heartbeat));
      expect(store.recordsRevision('progress'), greaterThan(progress));
      expect(store.recordsRevision('watched'), greaterThan(watched));
    },
  );

  test(
    'checkpoint completion does not mask concurrent external library changes',
    () async {
      store.save('media', 'video', {'title': 'Original'});
      final media = store.recordsRevision('media');
      final locations = store.locationRevision;
      final settings = store.localKeyRevision('settings');
      final other = AppStore.openExisting(store.path);
      try {
        final pending = store.savePlaybackProgress('video:100', _progress(10));
        other.save('media', 'video', {'title': 'External'});
        other.setLocal('location:video', {
          'id': 'video',
          'source': 'nas',
          'path': '/video',
        });
        other.setLocal('settings', {'volume': 50});
        await pending;
        expect(store.recordsRevision('media'), greaterThan(media));
        expect(store.locationRevision, greaterThan(locations));
        expect(store.localKeyRevision('settings'), greaterThan(settings));
        expect(store.get('media', 'video')!.data['title'], 'External');
      } finally {
        other.dispose();
      }
    },
  );

  test(
    'playback queries filter unrelated records and conflicts before decoding',
    () {
      store.save('progress', 'video:100', _progress(10));
      store.db.execute(
        'INSERT INTO records(kind,id,dirty,data) VALUES(?,?,1,?)',
        ['media', 'unrelated', 'invalid JSON'],
      );
      store.db.execute('INSERT INTO conflicts(kind,id,remote) VALUES(?,?,?)', [
        'vault',
        'artwork',
        'invalid JSON',
      ]);
      expect(store.pendingRecords(playbackOnly: true).single.id, 'video:100');
      expect(store.conflictRecords(playbackOnly: true), isEmpty);
      expect(store.conflictRecords(includeVault: false), isEmpty);
      expect(() => store.pending, throwsFormatException);
      expect(() => store.conflicts, throwsFormatException);
    },
  );

  test('atomic conflict resolution retains a newer backward seek', () async {
    await store.savePlaybackProgress('video:100', _progress(10));
    final worker = AppStore.openExisting(store.path);
    try {
      worker.resolveLatest(
        const SyncRecord(
          kind: 'progress',
          id: 'video:100',
          data: {'position': 90, 'duration': 100},
          modifiedAt: '2026-10-23T11:59:00Z',
          version: 5,
        ),
      );
    } finally {
      worker.dispose();
    }
    final saved = store.get('progress', 'video:100')!;
    expect(saved.data['position'], 10);
    expect(saved.version, 5);
    expect(saved.dirty, isTrue);
  });
}

Map<String, dynamic> _progress(num position) => {
  'position': position,
  'duration': 100,
  'updatedAt': '2026-10-23T12:00:00Z',
};
