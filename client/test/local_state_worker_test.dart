import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/local_state_worker.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
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

  Map<String, dynamic> previewInput() {
    store.save('media', 'video', {'title': 'video.mp4', 'size': 100});
    store.setLocal('location:video', {
      'id': 'video',
      'source': 'nas',
      'path': '/video.mp4',
      'size': 100,
      'previewRevision': 'v1',
    });
    return {
      'id': 'video',
      'source': 'nas',
      'sourcePath': '/video.mp4',
      'size': 100,
      'revision': 'v1',
      'position': null,
      'previewPath': '/cache/new.jpg',
      'formatVersion': MediaPreview.formatVersion,
      'duration': 30.0,
      'width': 1920,
      'height': 1080,
      'capturedPosition': 3.6,
    };
  }

  test(
    'preview commit waits behind a writer lock without blocking the caller',
    () async {
      final input = previewInput();
      store.setLocal('preview:video', {'path': '/cache/old.jpg'});
      await worker.saveMetadataTasks([]);
      final blocker = AppStore.openExisting(store.path);
      blocker.db.execute('BEGIN IMMEDIATE');
      var locked = true, committed = false, timerFired = false;
      try {
        final saving = worker.persistMediaPreview(input, cancel: CancelToken())
          ..then((_) => committed = true);
        final timer = Timer(
          const Duration(milliseconds: 40),
          () => timerFired = true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        timer.cancel();
        expect(timerFired, true);
        expect(committed, false);
        expect(store.local('preview:video')['path'], '/cache/old.jpg');
        expect(store.local('mediaMetadata:video'), isNull);
        blocker.db.execute('COMMIT');
        locked = false;
        final saved = await saving;
        expect(saved?.id, 'video');
        expect(saved?.previousPath, '/cache/old.jpg');
        expect(store.local('preview:video')['path'], '/cache/new.jpg');
        expect(
          store.local('preview:video')['fingerprint'],
          const MediaPreviewRequest(
            'video',
            'nas',
            '/video.mp4',
            100,
            revision: 'v1',
          ).fingerprint,
        );
        expect(store.local('mediaMetadata:video')['width'], 1920);
        expect(store.local('mediaMetadata:video')['duration'], 30.0);
      } finally {
        if (locked) blocker.db.execute('ROLLBACK');
        blocker.dispose();
      }
    },
  );

  test(
    'cancelled preview commit exits while the writer remains locked',
    () async {
      final input = previewInput();
      await worker.saveMetadataTasks([]);
      final blocker = AppStore.openExisting(store.path);
      blocker.db.execute('BEGIN IMMEDIATE');
      try {
        final cancel = CancelToken();
        final saving = worker.persistMediaPreview(input, cancel: cancel);
        final checked = expectLater(saving, throwsA(isA<Cancelled>()));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        cancel.cancel();
        await checked.timeout(const Duration(seconds: 2));
        expect(store.local('preview:video'), isNull);
        expect(store.local('mediaMetadata:video'), isNull);
      } finally {
        blocker.db.execute('ROLLBACK');
        blocker.dispose();
      }
    },
  );

  for (final changed in [
    'source',
    'path',
    'size',
    'previewRevision',
    'position',
    'deleted',
  ]) {
    test(
      'preview worker rejects a changed $changed before committing',
      () async {
        final input = previewInput();
        if (changed == 'position') {
          store.save('progress', 'video:100', {'position': 10});
        } else if (changed == 'deleted') {
          store.save('media', 'video', {'title': 'video.mp4'}, deleted: true);
        } else {
          store.setLocal('location:video', {
            ...store.local('location:video') as Map,
            changed: changed == 'size' ? 200 : 'changed',
          });
        }
        expect(
          await worker.persistMediaPreview(input, cancel: CancelToken()),
          isNull,
        );
        expect(store.local('preview:video'), isNull);
        expect(store.local('mediaMetadata:video'), isNull);
      },
    );
  }

  test(
    'preview and technical metadata roll back together on a failed write',
    () async {
      final input = previewInput();
      store.setLocal('preview:video', {'path': '/cache/old.jpg'});
      store.db.execute('''
      CREATE TRIGGER reject_preview_metadata BEFORE INSERT ON local
      WHEN NEW.key='mediaMetadata:video'
      BEGIN SELECT RAISE(ABORT, 'blocked preview metadata'); END
    ''');
      await expectLater(
        worker.persistMediaPreview(input, cancel: CancelToken()),
        throwsA(isA<AppFailure>()),
      );
      expect(store.local('preview:video'), {'path': '/cache/old.jpg'});
      expect(store.local('mediaMetadata:video'), isNull);
      store.db.execute('DROP TRIGGER reject_preview_metadata');
      expect(
        await worker.persistMediaPreview(input, cancel: CancelToken()),
        isNotNull,
      );
    },
  );

  test(
    'personal playback registration retains identity and independent progress',
    () async {
      const entry = SourceEntry(
        name: 'Trip 01.mp4',
        path: '/Trip/Trip 01.mp4',
        size: 321,
        modified: 1,
      );
      final record = await worker.preparePersonalMediaForPlayback('nas', entry);
      expect(record.data['personalMedia'], isTrue);
      expect(record.data['localOnly'], isTrue);
      expect(record.data['episode'], isEmpty);
      store.save('progress', '${record.id}:321', {'position': 19});
      final again = await worker.preparePersonalMediaForPlayback('nas', entry);
      expect(again.id, record.id);
      expect(store.get('progress', '${record.id}:321')!.data['position'], 19);
      expect(await worker.unmatchedMetadataCandidates(), isEmpty);
    },
  );

  test('personal playback preserves an existing manually identified film in the library', () async {
    store.save('media', 'film', {
      'title': 'My film',
      'fileName': 'Trip.mp4',
      'bangumiId': '42',
      'series': 'Manual identity',
    });
    store.setLocal('location:film', {
      'id': 'film',
      'source': 'nas',
      'path': '/Trip.mp4',
      'size': 100,
    });
    store.setLocal('manualMetadata:film', true);
    store.save('progress', 'film:100', {'position': 27});
    final before = store.get('media', 'film')!;
    final revision = store.recordsRevision('media');
    final sessionRecord = await worker.preparePersonalMediaForPlayback(
      'nas',
      const SourceEntry(name: 'Trip.mp4', path: '/Trip.mp4', size: 100),
    );
    expect(sessionRecord.id, 'film');
    expect(sessionRecord.data['personalMedia'], isTrue);
    final stored = store.get('media', 'film')!;
    expect(stored.data, before.data);
    expect(stored.revision, before.revision);
    expect(store.recordsRevision('media'), revision);
    expect(store.local('manualMetadata:film'), isTrue);
    expect(store.get('progress', 'film:100')!.data['position'], 27);
    final reader = LibrarySnapshotReader(store);
    try {
      expect(
        (await reader.read(
          query: '',
          revision: (
            store.recordsRevision('media'),
            store.recordsRevision('progress'),
            store.locationRevision,
          ),
        )).media.map((record) => record.id),
        ['film'],
      );
    } finally {
      reader.dispose();
    }
  });

  test(
    'cancelled personal registration behind a writer lock never commits',
    () async {
      await worker.saveMetadataTasks([]);
      final blocker = AppStore.openExisting(store.path);
      blocker.db.execute('BEGIN IMMEDIATE');
      var locked = true;
      final cancel = CancelToken();
      final pending = worker.preparePersonalMediaForPlayback(
        'nas',
        const SourceEntry(name: 'Trip.mp4', path: '/Trip.mp4'),
        cancel: cancel,
      );
      final rejected = expectLater(pending, throwsA(isA<Cancelled>()));
      try {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        cancel.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        blocker.db.execute('COMMIT');
        locked = false;
        await rejected;
        expect(store.locationFor('nas', '/Trip.mp4'), isNull);
        expect(store.records('media'), isEmpty);
      } finally {
        if (locked) blocker.db.execute('ROLLBACK');
        blocker.dispose();
      }
    },
  );

  test('technical labels include only selected live records and cancellation keeps the worker usable', () async {
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
  });

  test('checkpoint lock contention leaves the caller responsive and preserves order', () async {
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
  });

  test('browse writes are atomic and a failed transaction does not poison the queue', () async {
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
  });

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

  test('migration replaces broad local counters and tracks direct SQL and rollback', () async {
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
    expect(store.db.select('PRAGMA user_version').single.values.single, 6);
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
    external.db.execute("UPDATE local SET value='1' WHERE key='browse:video'");
    expect(store.localPrefixRevision('browse:'), greaterThan(savedBrowse));
    final updatedBrowse = store.localPrefixRevision('browse:');
    external.db.execute("DELETE FROM local WHERE key='browse:video'");
    expect(store.localPrefixRevision('browse:'), greaterThan(updatedBrowse));
    expect(store.recordsRevision('media'), media);
    expect(store.localKeyRevision('settings'), settings);
  });
}
