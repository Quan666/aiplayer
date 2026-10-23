import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late _CountingStore store;
  late AppModel model;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('library-worker-');
    store = _CountingStore('${directory.path}/app.db');
    model = AppModel(store, directory, backgroundWork: false);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test('disk preparation uses another isolate without UI full reads', () async {
    store.transaction(() {
      for (var i = 0; i < 2000; i++) {
        store.save('media', 'video-$i', {
          'title': 'Video $i',
          'series': 'Show ${i ~/ 10}',
          'episode': '${i % 10}',
          'poster': 'https://example.test/${i ~/ 10}.jpg',
        });
      }
    });
    store.fullReads = 0;
    var responsive = false;
    final work = model.loadLibrarySnapshot();
    Timer.run(() => responsive = true);
    final snapshot = await work;

    expect(responsive, isTrue);
    expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
    expect(snapshot.media, hasLength(2000));
    expect(snapshot.posters, hasLength(200));
    expect(store.fullReads, 0);
    expect(model.media, same(snapshot.media));
    expect(await model.loadLibrarySnapshot(), same(snapshot));
    store.setLocal('syncState', {'cursor': 12});
    store.setLocal('preview:video-0', {'path': '/preview.jpg'});
    expect(await model.loadLibrarySnapshot(), same(snapshot));
    expect(store.fullReads, 0);
    expect(() => snapshot.media.clear(), throwsUnsupportedError);
    expect(() => snapshot.posters.first.value.clear(), throwsUnsupportedError);
    expect(() => snapshot.byId.clear(), throwsUnsupportedError);
    expect(
      () => snapshot.media.first.data['title'] = 'Changed',
      throwsUnsupportedError,
    );
  });

  test(
    'managed, direct SQL and external edits invalidate worker data',
    () async {
      store.save('media', 'video', {'title': 'Original', 'size': 10});
      final first = await model.loadLibrarySnapshot();
      store.save('media', 'video', {'title': 'Managed', 'size': 10});
      expect(
        (await model.loadLibrarySnapshot()).media.single.data['title'],
        'Managed',
      );
      store.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
        '{"title":"SQL","size":10}',
        'media',
        'video',
      ]);
      final sql = await model.loadLibrarySnapshot();
      expect(sql.media.single.data['title'], 'SQL');
      expect(sql, isNot(same(first)));

      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      external.save('progress', 'video:10', {
        'position': 3,
        'updatedAt': '2026-10-23',
      });
      expect((await model.loadLibrarySnapshot()).recent.single.id, 'video');
      external.setLocal('location:video', {'size': 20, 'path': '/video.mp4'});
      final location = await model.loadLibrarySnapshot();
      expect(location.recent, isEmpty);
      expect(location.locations['video']?['path'], '/video.mp4');
      external.save('media', 'video', {}, deleted: true);
      expect((await model.loadLibrarySnapshot()).media, isEmpty);
      expect(store.fullReads, 0);
    },
  );

  test(
    'rollback and a revision changing in flight cannot publish stale data',
    () async {
      store.save('media', 'video', {'title': 'Original'});
      await model.loadLibrarySnapshot();
      late Future<LibrarySnapshot> duringTransaction;
      expect(
        () => store.transaction(() {
          store.save('media', 'video', {'title': 'Temporary'});
          duringTransaction = model.loadLibrarySnapshot();
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect((await duringTransaction).media.single.data['title'], 'Original');
      final inFlight = model.loadLibrarySnapshot(query: 'Final');
      store.save('media', 'video', {'title': 'Final'});
      final latest = await inFlight;
      expect(latest.files.single.value.single.data['title'], 'Final');
      expect(await model.loadLibrarySnapshot(query: 'Final'), same(latest));
    },
  );

  test(
    'history uses local size, stable ordering and series grouping',
    () async {
      void media(
        String id,
        String series,
        String episode, {
        bool poster = false,
      }) {
        store.save('media', id, {
          'title': '$series $episode',
          'series': series,
          'episode': episode,
          'size': 10,
          'poster': poster ? 'https://example.test/$id.jpg' : '',
          'genres': ['Drama'],
        });
      }

      media('alpha-1', 'Alpha', '1');
      media('alpha-2', 'Alpha', '2', poster: true);
      media('beta', 'Beta', '1');
      media('gamma', 'Gamma', '1');
      media('no-progress', 'None', '1');
      store.save('media', 'transient', {
        'title': 'Transient',
        'transient': true,
      });
      store.setLocal('location:alpha-1', {'size': 20});
      for (final id in ['alpha-1:10', 'alpha-2:10', 'beta:10', 'gamma:10']) {
        store.save('progress', id, {'position': 5, 'updatedAt': '2026-10-22'});
      }
      store.save('progress', 'alpha-1:20', {
        'position': 8,
        'updatedAt': '2026-10-23',
      });
      store.save('progress', 'no-progress:10', {
        'position': 0,
        'updatedAt': '2026-10-24',
      });
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.media, hasLength(5));
      expect(snapshot.recent.map((item) => item.id), [
        'alpha-1',
        'beta',
        'gamma',
      ]);
      expect(snapshot.posters.single.value.map((item) => item.id), [
        'alpha-1',
        'alpha-2',
      ]);
      expect(snapshot.files, hasLength(3));
      expect(
        () => (snapshot.media.first.data['genres'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.locations['alpha-1']!['size'] = 30,
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.progress['alpha-1:20']!['position'] = 0,
        throwsUnsupportedError,
      );
      final filtered = await model.loadLibrarySnapshot(query: 'ALPHA');
      expect(filtered.query, 'alpha');
      expect(filtered.posters.single.value, hasLength(2));
      expect(filtered.files, isEmpty);
      expect(filtered.recent.map((item) => item.id), [
        'alpha-1',
        'beta',
        'gamma',
      ]);
      expect(store.fullReads, 0);
    },
  );

  test(
    'concurrent searches keep their own results and cancellation is local',
    () async {
      store.save('media', 'alpha', {'title': 'Alpha'});
      store.save('media', 'beta', {'title': 'Beta'});
      final cancel = CancelToken();
      final canceled = expectLater(
        model.loadLibrarySnapshot(query: 'unused', cancel: cancel),
        throwsA(isA<Cancelled>()),
      );
      final alpha = model.loadLibrarySnapshot(query: 'Alpha');
      final beta = model.loadLibrarySnapshot(query: 'Beta');
      cancel.cancel();
      await canceled;
      final snapshots = await Future.wait([alpha, beta]);
      expect(snapshots[0].files.single.value.single.id, 'alpha');
      expect(snapshots[1].files.single.value.single.id, 'beta');
      expect(
        (await model.loadLibrarySnapshot(
          query: 'Beta',
        )).files.single.value.single.id,
        'beta',
      );
    },
  );

  test(
    'dispose cancels startup and pending reads without publishing',
    () async {
      final canceled = expectLater(
        model.loadLibrarySnapshot(),
        throwsA(isA<Cancelled>()),
      );
      model.dispose();
      await canceled;
      await expectLater(model.loadLibrarySnapshot(), throwsA(isA<Cancelled>()));
      // Restore a live model for the common tearDown and exercise disposal of a
      // worker that has already opened its independent SQLite connection.
      model = AppModel(store, directory, backgroundWork: false);
      await model.loadLibrarySnapshot();
      final pending = expectLater(
        model.loadLibrarySnapshot(query: 'new'),
        throwsA(isA<Cancelled>()),
      );
      model.dispose();
      await pending;
      model = AppModel(store, directory, backgroundWork: false);
    },
  );

  test(
    'a failed worker startup can be retried after storage recovers',
    () async {
      final path = '${directory.path}/recover.db';
      final temporary = AppStore(path)..dispose();
      File(path).deleteSync();
      final reader = LibrarySnapshotReader(temporary);
      addTearDown(reader.dispose);
      await expectLater(
        reader.read(query: '', revision: (0, 0, 0)),
        throwsStateError,
      );
      final restored = AppStore(path);
      addTearDown(restored.dispose);
      restored.save('media', 'restored', {'title': 'Restored'});
      expect(
        (await reader.read(query: '', revision: (1, 0, 0))).media.single.id,
        'restored',
      );
    },
  );
}

class _CountingStore extends AppStore {
  int fullReads = 0;
  _CountingStore(super.path);

  @override
  List<SyncRecord> all(String kind) {
    fullReads++;
    return super.all(kind);
  }

  @override
  List<SyncRecord> records(String kind) {
    fullReads++;
    return super.records(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    fullReads++;
    return super.localEntries(prefix);
  }
}
