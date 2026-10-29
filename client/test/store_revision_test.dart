import 'dart:io';

import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'external settings writes invalidate only their key and prefixes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'settings-revision-',
      );
      final first = AppStore('${directory.path}/app.db');
      final worker = AppStore.openExisting(first.path);
      addTearDown(() {
        worker.dispose();
        first.dispose();
        directory.deleteSync(recursive: true);
      });
      first.setLocal('settings', {'volume': 80});
      final media = first.recordsRevision('media');
      final progress = first.recordsRevision('progress');
      final location = first.locationRevision;
      final preview = first.localPrefixRevision('preview:');
      final otherKey = first.localKeyRevision('sources');
      var settings = first.localKeyRevision('settings');
      var prefix = first.localPrefixRevision('setting');
      var allLocal = first.localPrefixRevision('');
      var local = first.localRevision;
      void check() {
        expect(first.localKeyRevision('settings'), greaterThan(settings));
        expect(first.localPrefixRevision('setting'), greaterThan(prefix));
        expect(first.localPrefixRevision(''), greaterThan(allLocal));
        expect(first.localRevision, greaterThan(local));
        expect(first.recordsRevision('media'), media);
        expect(first.recordsRevision('progress'), progress);
        expect(first.locationRevision, location);
        expect(first.localPrefixRevision('preview:'), preview);
        expect(first.localKeyRevision('sources'), otherKey);
        settings = first.localKeyRevision('settings');
        prefix = first.localPrefixRevision('setting');
        allLocal = first.localPrefixRevision('');
        local = first.localRevision;
      }

      worker.setLocal('settings', {'volume': 60});
      check();
      worker.db.execute('UPDATE local SET value=? WHERE key=?', [
        '{"volume":40}',
        'settings',
      ]);
      check();
      worker.db.execute('DELETE FROM local WHERE key=?', ['settings']);
      check();
      await first.patchSettingsInBackground({'librarySortField': 'name'});
      check();
      expect(first.local('settings'), {'librarySortField': 'name'});
    },
  );

  test(
    'renamed settings keys retain conservative cross-scope invalidation',
    () {
      final directory = Directory.systemTemp.createTempSync('settings-rename-');
      final first = AppStore('${directory.path}/app.db');
      final worker = AppStore.openExisting(first.path);
      addTearDown(() {
        worker.dispose();
        first.dispose();
        directory.deleteSync(recursive: true);
      });
      first.setLocal('settings', {'volume': 80});
      for (final keys in [
        ('settings', 'location:video'),
        ('location:video', 'settings'),
      ]) {
        final settings = first.localKeyRevision('settings');
        final location = first.locationRevision;
        worker.db.execute('UPDATE local SET key=? WHERE key=?', [
          keys.$2,
          keys.$1,
        ]);
        expect(first.localKeyRevision('settings'), greaterThan(settings));
        expect(first.locationRevision, greaterThan(location));
        expect(first.local(keys.$1), isNull);
        expect(first.local(keys.$2), {'volume': 80});
      }
    },
  );

  test(
    'settings rollback invalidates local reads but never publishes remotely',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'settings-rollback-',
      );
      final first = AppStore('${directory.path}/app.db');
      final worker = AppStore.openExisting(first.path);
      addTearDown(() {
        worker.dispose();
        first.dispose();
        directory.deleteSync(recursive: true);
      });
      first.setLocal('settings', {'volume': 80});
      final remoteRevision = first.localKeyRevision('settings');
      late int uncommitted;
      expect(
        () => worker.transaction(() {
          worker.setLocal('settings', {'volume': 20});
          uncommitted = worker.localKeyRevision('settings');
          expect(first.local('settings'), {'volume': 80});
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(worker.localKeyRevision('settings'), greaterThan(uncommitted));
      expect(worker.local('settings'), {'volume': 80});
      expect(first.localKeyRevision('settings'), remoteRevision);
    },
  );

  test(
    'version two stores replace local triggers once for settings isolation',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'settings-migration-',
      );
      final path = '${directory.path}/app.db';
      final legacy = AppStore(path);
      legacy.setLocal('settings', {'volume': 70});
      for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
        final row = event == 'DELETE' ? 'OLD' : 'NEW';
        legacy.db.execute(
          'DROP TRIGGER store_change_local_${event.toLowerCase()}',
        );
        legacy.db.execute(
          'CREATE TRIGGER store_change_local_${event.toLowerCase()} AFTER $event ON local BEGIN '
          'INSERT INTO store_change_counters(scope,value) VALUES('
          "CASE WHEN ($row.key='lastSync' OR substr($row.key,1,4)='sync')"
          '${event == 'UPDATE' ? ' AND OLD.key=NEW.key' : ''}'
          " THEN 'sync' ELSE 'other' END,1) "
          'ON CONFLICT(scope) DO UPDATE SET value=value+1; END',
        );
      }
      legacy.db.execute('PRAGMA user_version=2');
      legacy.dispose();
      final migrated = AppStore(path);
      final worker = AppStore.openExisting(path);
      addTearDown(() {
        worker.dispose();
        migrated.dispose();
        directory.deleteSync(recursive: true);
      });
      expect(
        migrated.db.select('PRAGMA user_version').single['user_version'],
        5,
      );
      expect(migrated.local('settings'), {'volume': 70});
      final media = migrated.recordsRevision('media');
      final settings = migrated.localKeyRevision('settings');
      worker.setLocal('settings', {'volume': 25});
      expect(migrated.localKeyRevision('settings'), greaterThan(settings));
      expect(migrated.recordsRevision('media'), media);
      final schema = migrated.db
          .select('PRAGMA schema_version')
          .single['schema_version'];
      final reopened = AppStore(path);
      expect(
        reopened.db.select('PRAGMA schema_version').single['schema_version'],
        schema,
      );
      reopened.dispose();
    },
  );

  test(
    'prefix revisions isolate writes and detect direct SQL and rollback',
    () {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      final preview = store.localPrefixRevision('preview:');
      final names = store.localPrefixRevision('episodeTitle:');
      store.setLocal('preview:video', {'path': '/cover.jpg'});
      final changed = store.localPrefixRevision('preview:');
      expect(changed, greaterThan(preview));
      expect(store.localPrefixRevision('episodeTitle:'), names);
      store.setLocal('settings', {'volume': 50});
      expect(store.localPrefixRevision('preview:'), changed);
      store.setLocal('preview:video', {'path': '/cover.jpg'});
      expect(store.localPrefixRevision('preview:'), changed);
      late int uncommitted;
      expect(
        () => store.transaction(() {
          store.removeLocal('preview:video');
          uncommitted = store.localPrefixRevision('preview:');
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(store.localPrefixRevision('preview:'), greaterThan(uncommitted));
      final rolledBack = store.localPrefixRevision('preview:');
      store.db.execute('DELETE FROM local WHERE key=?', ['preview:video']);
      expect(store.localPrefixRevision('preview:'), greaterThan(rolledBack));
    },
  );

  test(
    'location lookup and prefix revisions see worker writes without polling',
    () {
      final directory = Directory.systemTemp.createTempSync('store-prefix-');
      final first = AppStore('${directory.path}/app.db');
      final worker = AppStore.openExisting(first.path);
      addTearDown(() {
        worker.dispose();
        first.dispose();
        directory.deleteSync(recursive: true);
      });
      expect(first.locationFor('nas', 'video.mkv'), isNull);
      final previews = first.localPrefixRevision('preview:');
      worker.transaction(() {
        worker.setLocal('location:video', {
          'id': 'video',
          'source': 'nas',
          'path': 'video.mkv',
        });
        worker.setLocal('preview:video', {'path': '/cover.jpg'});
      });
      expect(first.locationFor('nas', 'video.mkv')?['id'], 'video');
      expect(first.localPrefixRevision('preview:'), greaterThan(previews));
      final updated = first.localPrefixRevision('preview:');
      final sync = first.localPrefixRevision('sync');
      worker.setLocal('lastSync', '2026-10-23T12:00:00Z');
      expect(first.localPrefixRevision('sync'), greaterThan(sync));
      expect(first.localPrefixRevision('preview:'), updated);
    },
  );

  test('playback pending query excludes vault before JSON decoding', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    store.save('progress', 'video', {'position': 10});
    store.save('vault', 'artwork', {'large': 'payload'});
    // A malformed vault proves the fast path never even decodes that column.
    store.db.execute("UPDATE records SET data='not json' WHERE kind='vault'");
    expect(store.pendingRecords(includeVault: false).single.kind, 'progress');
    expect(() => store.pending, throwsFormatException);
  });

  test('record and location revisions ignore unrelated background writes', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    store.save('media', 'video', {'title': 'Example'});
    final media = store.recordsRevision('media');
    final locations = store.locationRevision;
    final progress = store.recordsRevision('progress');
    store.save('progress', 'video:1', {'position': 10});
    store.setLocal('preview:video', {'path': '/cover.jpg'});
    store.cache('catalog', {'title': 'Example'});
    expect(store.recordsRevision('media'), media);
    expect(store.locationRevision, locations);
    expect(store.recordsRevision('progress'), greaterThan(progress));
    store.setLocal('location:video', {'size': 12});
    final associated = store.locationRevision;
    expect(associated, greaterThan(locations));
    expect(store.recordsRevision('media'), media);
    store.removeLocal('location:video');
    expect(store.locationRevision, greaterThan(associated));
    store.save('media', 'video', {'title': 'Changed'});
    expect(store.recordsRevision('media'), greaterThan(media));
  });

  test('direct SQL, including truncated deletes, invalidates snapshots', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    store.save('media', 'video', {'title': 'Example'});
    final revision = store.recordsRevision('media');
    store.db.execute("UPDATE records SET data='{}' WHERE kind='media'");
    // Managed writes must not hide a preceding direct SQL write.
    store.setLocal('settings', {'volume': 50});
    final changed = store.recordsRevision('media');
    expect(changed, greaterThan(revision));
    store.db.execute('DELETE FROM records');
    expect(store.recordsRevision('media'), greaterThan(changed));
    expect(store.all('media'), isEmpty);
  });

  test('rollback invalidates a snapshot read inside the transaction', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    store.save('media', 'video', {'title': 'Original'});
    late int uncommitted;
    expect(
      () => store.transaction(() {
        store.save('media', 'video', {'title': 'Temporary'});
        uncommitted = store.recordsRevision('media');
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(store.recordsRevision('media'), greaterThan(uncommitted));
    expect(store.get('media', 'video')!.data['title'], 'Original');
    final rolledBack = store.recordsRevision('media');
    store.setLocal('settings', {'volume': 50});
    expect(store.recordsRevision('media'), rolledBack);
  });

  test('another engine commit invalidates media and location snapshots', () {
    final directory = Directory.systemTemp.createTempSync('store-revision-');
    final first = AppStore('${directory.path}/app.db');
    final second = AppStore(first.path);
    addTearDown(() {
      first.dispose();
      second.dispose();
      directory.deleteSync(recursive: true);
    });
    final media = first.recordsRevision('media');
    final locations = first.locationRevision;
    expect(first.locationFor('nas', 'movie.mkv'), isNull);
    second.transaction(() {
      second.save('media', 'video', {'title': 'External'});
      second.setLocal('location:video', {
        'id': 'video',
        'source': 'nas',
        'path': 'movie.mkv',
        'size': 10,
      });
    });
    expect(first.recordsRevision('media'), greaterThan(media));
    expect(first.locationRevision, greaterThan(locations));
    expect(first.get('media', 'video')!.data['title'], 'External');
    expect(first.locationFor('nas', 'movie.mkv')?['id'], 'video');
  });
}
