import 'dart:io';

import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _first = 'automatic-import-excluded:first';
const _second = 'automatic-import-excluded:second';

class _LocationReadStore extends AppStore {
  _LocationReadStore(super.path);
  int locationReads = 0;

  @override
  List<Map<String, dynamic>> get locations {
    locationReads++;
    return super.locations;
  }
}

void main() {
  test('known exclusion mutations preserve the prepared location index', () {
    final store = _LocationReadStore(':memory:');
    addTearDown(store.dispose);
    store.setLocal('location:known', {
      'id': 'known',
      'source': 'dav',
      'path': 'video.mkv',
    });
    expect(store.locationFor('dav', 'video.mkv')?['id'], 'known');
    final reads = store.locationReads;
    final mediaRevision = store.recordsRevision('media');
    final locationRevision = store.locationRevision;
    for (final mutate in <void Function()>[
      () => store.setLocal(_first, true),
      () => store.setLocal(_first, false),
      () => store.removeLocal(_first),
      () => store.setLocal(_first, true),
    ]) {
      mutate();
      expect(store.locationFor('dav', 'video.mkv')?['id'], 'known');
      expect(store.locationReads, reads);
      expect(store.recordsRevision('media'), mediaRevision);
      expect(store.locationRevision, locationRevision);
    }
  });

  test('exclusion accounting does not hide external writes or rollback', () {
    final directory = Directory.systemTemp.createTempSync('exclusion-index-');
    final store = _LocationReadStore('${directory.path}/app.db');
    final worker = AppStore.openExisting(store.path);
    addTearDown(() {
      worker.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    });
    store.setLocal('location:known', {
      'id': 'known',
      'source': 'dav',
      'path': 'original.mkv',
    });
    expect(store.locationFor('dav', 'original.mkv')?['id'], 'known');
    for (final (connection, before, after, key) in [
      (store, 'original.mkv', 'direct.mkv', _first),
      (worker, 'direct.mkv', 'remote.mkv', _second),
    ]) {
      final reads = store.locationReads;
      connection.db.execute('UPDATE local SET value=? WHERE key=?', [
        '{"id":"known","source":"dav","path":"$after"}',
        'location:known',
      ]);
      // Account only for our exclusion statement, leaving the earlier direct
      // write or another connection's commit visible to cache invalidation.
      store.setLocal(key, true);
      expect(store.locationFor('dav', before), isNull);
      expect(store.locationFor('dav', after)?['id'], 'known');
      expect(store.locationReads, reads + 1);
    }
    final sequence = store.importExclusionSequence;
    final reads = store.locationReads;
    expect(
      () => store.transaction(() {
        store.removeLocal(_first);
        store.removeLocal('location:known');
        expect(store.locationFor('dav', 'remote.mkv'), isNull);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(store.locationFor('dav', 'remote.mkv')?['id'], 'known');
    expect(store.locationReads, reads + 1);
    expect(store.importExclusionSequence, sequence);
    expect(store.local(_first), isTrue);
  });

  test('exclusion sequence survives clearing every removal', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    expect(store.importExclusionSequence, 0);
    expect(store.importExclusionRevision(_first), isNull);

    store.setLocal(_first, true);
    final first = store.importExclusionRevision(_first)!;
    expect(first, greaterThan(0));
    expect(store.importExclusionSequence, first);
    expect(store.local(_first), isTrue);
    store.setLocal(_first, true);
    store.setLocal('settings', {'volume': 80});
    expect(store.importExclusionSequence, first);

    store.setLocal(_first, false);
    final updated = store.importExclusionRevision(_first)!;
    expect(updated, greaterThan(first));
    expect(store.local(_first), isFalse);
    store.removeLocal(_first);
    expect(store.importExclusionRevision(_first), isNull);
    expect(store.importExclusionSequence, updated);

    store.setLocal(_first, true);
    expect(store.importExclusionRevision(_first), greaterThan(updated));
    expect(store.local(_first), isTrue);
  });

  test('version four exclusions migrate once and survive reopening', () {
    final directory = Directory.systemTemp.createTempSync('exclusion-upgrade-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/app.db';
    final legacy = sqlite3.open(path);
    legacy.execute(
      'CREATE TABLE local(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
    );
    for (final key in [_first, _second, 'automatic-import-excluded-other']) {
      legacy.execute('INSERT INTO local(key,value) VALUES(?,?)', [key, 'true']);
    }
    legacy.execute('PRAGMA user_version=4');
    legacy.dispose();

    final migrated = AppStore(path);
    final first = migrated.importExclusionRevision(_first)!;
    final second = migrated.importExclusionRevision(_second)!;
    final sequence = migrated.importExclusionSequence;
    expect(first, isNot(second));
    expect(first, greaterThan(0));
    expect(second, greaterThan(0));
    expect(
      migrated.importExclusionRevision('automatic-import-excluded-other'),
      isNull,
    );
    expect(migrated.local(_first), isTrue);
    migrated.dispose();

    final reopened = AppStore(path);
    try {
      expect(reopened.importExclusionRevision(_first), first);
      expect(reopened.importExclusionRevision(_second), second);
      expect(reopened.importExclusionSequence, sequence);
      reopened.removeLocal(_first);
      reopened.removeLocal(_second);
    } finally {
      reopened.dispose();
    }
    final empty = AppStore(path);
    try {
      expect(empty.importExclusionSequence, sequence);
      empty.setLocal(_first, true);
      expect(empty.importExclusionRevision(_first), greaterThan(sequence));
    } finally {
      empty.dispose();
    }
  });

  test('direct SQL and renamed keys publish revisions across connections', () {
    final directory = Directory.systemTemp.createTempSync('exclusion-sql-');
    final store = AppStore('${directory.path}/app.db');
    final worker = AppStore.openExisting(store.path);
    addTearDown(() {
      worker.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    });
    worker.db.execute('INSERT INTO local(key,value) VALUES(?,?)', [
      _first,
      'true',
    ]);
    var revision = store.importExclusionRevision(_first)!;
    expect(store.local(_first), isTrue);
    worker.db.execute('UPDATE local SET value=? WHERE key=?', ['true', _first]);
    expect(store.importExclusionRevision(_first), greaterThan(revision));
    revision = store.importExclusionSequence;
    worker.db.execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)', [
      _first,
      'true',
    ]);
    expect(store.importExclusionRevision(_first), greaterThan(revision));
    revision = store.importExclusionSequence;

    worker.db.execute('UPDATE local SET key=? WHERE key=?', [
      'ordinary',
      _first,
    ]);
    expect(store.importExclusionRevision(_first), isNull);
    expect(store.importExclusionRevision('ordinary'), isNull);
    expect(store.importExclusionSequence, revision);
    worker.db.execute('UPDATE local SET key=? WHERE key=?', [
      _second,
      'ordinary',
    ]);
    expect(store.importExclusionRevision(_second), greaterThan(revision));
    revision = store.importExclusionSequence;
    worker.db.execute('UPDATE local SET key=? WHERE key=?', [_first, _second]);
    expect(store.importExclusionRevision(_second), isNull);
    expect(store.importExclusionRevision(_first), greaterThan(revision));
    revision = store.importExclusionSequence;
    worker.db.execute('DELETE FROM local WHERE key=?', [_first]);
    expect(store.importExclusionRevision(_first), isNull);
    expect(store.importExclusionSequence, revision);
    worker.setLocal(_second, true);
    expect(store.importExclusionRevision(_second), greaterThan(revision));
  });

  test('rolled-back removals do not change the durable admission boundary', () {
    final directory = Directory.systemTemp.createTempSync(
      'exclusion-rollback-',
    );
    final store = AppStore('${directory.path}/app.db');
    final worker = AppStore.openExisting(store.path);
    addTearDown(() {
      worker.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    });
    store.setLocal(_first, true);
    final boundary = store.importExclusionSequence;
    final first = store.importExclusionRevision(_first);
    expect(
      () => worker.transaction(() {
        worker.removeLocal(_first);
        worker.setLocal(_second, true);
        expect(worker.importExclusionSequence, greaterThan(boundary));
        expect(worker.importExclusionRevision(_first), isNull);
        expect(store.importExclusionSequence, boundary);
        expect(store.importExclusionRevision(_first), first);
        expect(store.importExclusionRevision(_second), isNull);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    for (final connection in [store, worker]) {
      expect(connection.importExclusionSequence, boundary);
      expect(connection.importExclusionRevision(_first), first);
      expect(connection.importExclusionRevision(_second), isNull);
      expect(connection.local(_first), isTrue);
      expect(connection.local(_second), isNull);
    }
    worker.setLocal(_second, true);
    expect(store.importExclusionRevision(_second), greaterThan(boundary));
  });
}
