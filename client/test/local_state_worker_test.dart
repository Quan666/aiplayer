import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/local_state_worker.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;
  late LocalStateWorker worker;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aiplayer-local-state-');
    store = await AppStore.open('${directory.path}/test.db');
    worker = LocalStateWorker(store.path);
  });

  tearDown(() async {
    await worker.close();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'technical labels include only selected live records and cancellation keeps the worker usable',
    () async {
      store.save('media', 'selected', {
        'title': 'Show 1080p.mkv',
        'fileName': 'Show 1080p.mkv',
        'size': 4096,
      });
      store.save('media', 'deleted', {'title': 'deleted.mkv'}, deleted: true);
      store.save('media', 'unselected', {'title': 'Other.mp4'});
      const MediaTechnicalInfo(
        container: 'matroska',
        codec: 'H.264',
        width: 1920,
        height: 1080,
      ).save(store, store.get('media', 'selected')!);

      final labels = await worker.readMediaTechnicalLabels([
        'selected',
        'selected',
        'deleted',
        'missing',
      ]);
      expect(labels.keys, ['selected']);
      expect(labels['selected'], 'MKV · H.264 · 1920 × 1080 · 4.0 KiB');
      expect(() => labels.clear(), throwsUnsupportedError);

      final cancel = CancelToken();
      final pending = worker.readMediaTechnicalLabels(
        List.generate(10000, (index) => 'missing-$index'),
        cancel: cancel,
      );
      final rejected = expectLater(pending, throwsA(isA<Cancelled>()));
      cancel.cancel();
      await rejected;
      expect(
        (await worker.readMediaTechnicalLabels(['selected']))['selected'],
        labels['selected'],
      );
    },
  );

  test(
    'checkpoint lock contention leaves the caller responsive and preserves order',
    () async {
      await worker.saveMetadataTasks([]);
      final lock = AppStore.openExisting(store.path);
      lock.db.execute('BEGIN IMMEDIATE');
      var locked = true;
      addTearDown(() {
        if (locked) lock.db.execute('ROLLBACK');
        lock.dispose();
      });
      var finished = false;
      final first = worker
          .saveMetadataTasks([
            {
              'id': 'first',
              'records': [
                {'id': 'video', 'revision': 1},
              ],
            },
          ])
          .then((_) => finished = true);
      final latest = worker.saveMetadataTasks([]);
      var heartbeat = false;
      await Future<void>.delayed(const Duration(milliseconds: 40), () {
        heartbeat = true;
      });
      expect(heartbeat, isTrue);
      expect(finished, isFalse);
      expect(store.local('metadata:pending-tasks'), isEmpty);
      lock.db.execute('COMMIT');
      locked = false;
      await first;
      await latest;
      expect(store.local('metadata:pending-tasks'), isEmpty);
    },
  );

  test(
    'browse writes are atomic and a failed transaction does not poison the queue',
    () async {
      store.db.execute('''
      CREATE TRIGGER reject_browse_index BEFORE INSERT ON local
      WHEN NEW.key='browse:index'
      BEGIN SELECT RAISE(ABORT, 'blocked index'); END
    ''');
      await expectLater(
        worker.registerBrowse('video', 'nas', 'movie.mkv', 12),
        throwsA(isA<AppFailure>()),
      );
      expect(store.local('browse:video'), isNull);
      expect(store.local('syncModified:browse:video'), isNull);
      store.db.execute('DROP TRIGGER reject_browse_index');
      await worker.registerBrowse('video', 'nas', 'movie.mkv', 12);
      expect(store.local('browse:video'), {
        'source': 'nas',
        'path': 'movie.mkv',
        'size': 12,
      });
      expect(store.local('browse:index'), ['video']);
      final revision = store.localKeyRevision('browse:video');
      await worker.registerBrowse('video', 'nas', 'movie.mkv', 12);
      expect(store.localKeyRevision('browse:video'), revision);
    },
  );

  test(
    'cancelled browse work exits while another connection still holds the lock',
    () async {
      await worker.saveMetadataTasks([]);
      final lock = AppStore.openExisting(store.path);
      lock.db.execute('BEGIN IMMEDIATE');
      addTearDown(() {
        lock.db.execute('ROLLBACK');
        lock.dispose();
      });
      final cancel = CancelToken();
      final work = worker.registerBrowse(
        'cancelled',
        'nas',
        'movie.mkv',
        1,
        cancel: cancel,
      );
      final checked = expectLater(work, throwsA(isA<Cancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cancel.cancel();
      await checked.timeout(const Duration(seconds: 2));
      expect(store.local('browse:cancelled'), isNull);
      expect(store.local('browse:index'), isNull);
    },
  );

  test(
    'close drains accepted checkpoints and cancels queued browse work',
    () async {
      await worker.saveMetadataTasks([]);
      final lock = AppStore.openExisting(store.path);
      lock.db.execute('BEGIN IMMEDIATE');
      var locked = true;
      addTearDown(() {
        if (locked) lock.db.execute('ROLLBACK');
        lock.dispose();
      });
      final checkpoint = worker.saveMetadataTasks([
        {'id': 'resume-me'},
      ]);
      final browse = expectLater(
        worker.registerBrowse('closed', 'nas', 'movie.mkv', 1),
        throwsA(isA<Cancelled>()),
      );
      final closing = worker.close();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      lock.db.execute('COMMIT');
      locked = false;
      await Future.wait([checkpoint, browse, closing]);
      expect(store.local('metadata:pending-tasks'), [
        {'id': 'resume-me'},
      ]);
      expect(store.local('browse:closed'), isNull);
      await expectLater(
        worker.saveMetadataTasks([]),
        throwsA(isA<Cancelled>()),
      );
    },
  );

  test('close before startup still persists accepted checkpoints', () async {
    final save = worker.saveMetadataTasks([
      {'id': 'startup'},
    ]);
    final close = worker.close();
    await Future.wait([save, close]);
    expect(store.local('metadata:pending-tasks'), [
      {'id': 'startup'},
    ]);
  });

  test(
    'startup failures reach accepted calls and close still finishes',
    () async {
      final unavailable = LocalStateWorker('${directory.path}/missing/test.db');
      try {
        await expectLater(
          unavailable.saveMetadataTasks([]),
          throwsA(
            isA<AppFailure>().having(
              (error) => error is Cancelled,
              'is cancellation',
              isFalse,
            ),
          ),
        );
      } finally {
        await unavailable.close();
      }
    },
  );

  test(
    'browse registration skips a media binding committed by another connection',
    () async {
      store.save('media', 'imported', {'title': 'Movie'});
      store.setLocal('location:imported', {
        'id': 'imported',
        'source': 'nas',
        'path': 'movie.mkv',
        'size': 1,
      });
      await worker.registerBrowse('browse-imported', 'nas', 'movie.mkv', 1);
      expect(store.local('browse:browse-imported'), isNull);
      expect(store.local('browse:index'), isNull);
    },
  );

  test('worker local state invalidates only its own snapshots', () async {
    final media = store.recordsRevision('media');
    final settings = store.localKeyRevision('settings');
    final locations = store.locationRevision;
    final checkpoint = store.localKeyRevision('metadata:pending-tasks');
    final metadataPrefix = store.localPrefixRevision('metadata:');
    final browse = store.localPrefixRevision('browse:');
    final browseKey = store.localKeyRevision('browse:video');
    await worker.saveMetadataTasks([
      {'id': 'pending'},
    ]);
    expect(
      store.localKeyRevision('metadata:pending-tasks'),
      greaterThan(checkpoint),
    );
    expect(store.localPrefixRevision('metadata:'), greaterThan(metadataPrefix));
    expect(store.localPrefixRevision('browse:'), browse);
    expect(store.recordsRevision('media'), media);
    expect(store.localKeyRevision('settings'), settings);
    expect(store.locationRevision, locations);
    final savedCheckpoint = store.localKeyRevision('metadata:pending-tasks');
    await worker.registerBrowse('video', 'nas', 'movie.mkv', 1);
    expect(store.localPrefixRevision('browse:'), greaterThan(browse));
    expect(store.localKeyRevision('browse:video'), greaterThan(browseKey));
    expect(store.localKeyRevision('metadata:pending-tasks'), savedCheckpoint);
    expect(store.recordsRevision('media'), media);
    expect(store.localKeyRevision('settings'), settings);
    expect(store.locationRevision, locations);
  });

  test(
    'migration replaces broad local counters and tracks direct SQL and rollback',
    () async {
      await worker.close();
      for (final event in ['insert', 'update', 'delete']) {
        store.db.execute('DROP TRIGGER store_change_local_$event');
        store.db.execute('''
        CREATE TRIGGER store_change_local_$event AFTER $event ON local BEGIN
        INSERT INTO store_change_counters(scope,value) VALUES('other',1)
        ON CONFLICT(scope) DO UPDATE SET value=value+1; END
      ''');
      }
      store.db.execute('PRAGMA user_version=3');
      store.dispose();
      store = await AppStore.open('${directory.path}/test.db');
      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      expect(store.db.select('PRAGMA user_version').single.values.single, 5);
      final media = store.recordsRevision('media');
      final settings = store.localKeyRevision('settings');
      final checkpoint = store.localKeyRevision('metadata:pending-tasks');
      final browse = store.localPrefixRevision('browse:');
      external.db.execute(
        "INSERT INTO local VALUES('metadata:pending-tasks', '[]')",
      );
      expect(
        store.localKeyRevision('metadata:pending-tasks'),
        greaterThan(checkpoint),
      );
      external.db.execute("INSERT INTO local VALUES('browse:video', '{}')");
      expect(store.localPrefixRevision('browse:'), greaterThan(browse));
      expect(store.recordsRevision('media'), media);
      expect(store.localKeyRevision('settings'), settings);
      final savedBrowse = store.localPrefixRevision('browse:');
      external.db.execute('BEGIN IMMEDIATE');
      external.db.execute("DELETE FROM local WHERE key='browse:video'");
      external.db.execute('ROLLBACK');
      expect(store.localPrefixRevision('browse:'), savedBrowse);
      external.db.execute(
        "UPDATE local SET value='1' WHERE key='browse:video'",
      );
      expect(store.localPrefixRevision('browse:'), greaterThan(savedBrowse));
      final updatedBrowse = store.localPrefixRevision('browse:');
      external.db.execute("DELETE FROM local WHERE key='browse:video'");
      expect(store.localPrefixRevision('browse:'), greaterThan(updatedBrowse));
      expect(store.recordsRevision('media'), media);
      expect(store.localKeyRevision('settings'), settings);
    },
  );
}
