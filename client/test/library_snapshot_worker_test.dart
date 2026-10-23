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
    'one recognized episode promotes its unambiguous siblings to a complete shortcut',
    () async {
      for (var episode = 1; episode <= 3; episode++) {
        store.save('media', 'episode-$episode', {
          'title': 'Original S01E0$episode.mkv',
          'fileName': 'Original S01E0$episode.mkv',
          'series': episode == 2 ? '正式作品' : 'Original',
          'season': '1',
          'episode': '$episode',
          'size': 10,
          if (episode == 2) ...{
            'bangumiId': '7',
            'metadataTitle': '正式作品',
            'poster': 'https://example.test/series.jpg',
          },
        });
        store.save('progress', 'episode-$episode:10', {
          'position': 5,
          'updatedAt': '2026-10-2$episode',
        });
      }
      store.save('media', 'standalone', {'title': 'Private recording.mp4'});
      final snapshot = await model.loadLibrarySnapshot();
      final first = snapshot.byId['episode-1']!;
      expect(snapshot.posters.single.key, 'bangumi:7:1');
      expect(snapshot.posters.single.value, hasLength(3));
      expect(snapshot.seriesFor(first), same(snapshot.posters.single.value));
      expect(snapshot.representativeFor(first).id, 'episode-2');
      expect(snapshot.recent.map((record) => record.id), ['episode-3']);
      expect(snapshot.files.single.value.single.id, 'standalone');
      expect(() => snapshot.seriesKeys.clear(), throwsUnsupportedError);
      expect(() => snapshot.representatives.clear(), throwsUnsupportedError);
      for (final query in ['S01E02', '正式作品']) {
        final filtered = await model.loadLibrarySnapshot(query: query);
        expect(filtered.posters.single.value, hasLength(3));
        expect(filtered.files, isEmpty);
      }
      expect(store.fullReads, 0);

      // A second explicit identification makes the filename ambiguous. Keep
      // both verified choices and the parsed siblings separate after refresh.
      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      final third = external.get('media', 'episode-3')!;
      external.save('media', third.id, {...third.data, 'bangumiId': '8'});
      final conflicted = await model.loadLibrarySnapshot();
      expect(conflicted.series, hasLength(4));
      expect(conflicted.seriesFor(first).single.id, 'episode-1');
      expect(
        conflicted.seriesKeyFor(conflicted.byId['episode-2']!),
        'bangumi:7:1',
      );
      expect(
        conflicted.seriesKeyFor(conflicted.byId['episode-3']!),
        'bangumi:8:1',
      );
    },
  );

  test(
    'canonical episode versions are prepared off-thread and track local availability',
    () async {
      store.save('media', 'recognized', {
        'title': 'Original S01E01.mkv',
        'series': '正式作品',
        'season': '1',
        'episode': '1',
        'bangumiId': '7',
        'metadataTitle': '正式作品',
      });
      for (final (id, episode) in [('alternate', '1'), ('next', '2')]) {
        store.save('media', id, {
          'title': 'Original S01E0$episode.mp4',
          'series': 'Original',
          'season': '1',
          'episode': episode,
        });
      }
      store.setLocal('location:alternate', {
        'source': 'local',
        'path': '/series/Original S01E01.mp4',
      });
      final snapshot = await model.loadLibrarySnapshot();
      final first = snapshot.byId['recognized']!;
      final alternate = snapshot.byId['alternate']!;
      expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(snapshot.episodeKeyFor(first), snapshot.episodeKeyFor(alternate));
      expect(snapshot.versionsFor(first), hasLength(2));
      expect(
        snapshot.versionsFor(first),
        same(snapshot.versionsFor(alternate)),
      );
      expect(snapshot.episodesFor(first).map((record) => record.id), [
        'alternate',
        'next',
      ]);
      expect(alternate.data['bangumiId'], isNull);
      expect(() => snapshot.episodeKeys.clear(), throwsUnsupportedError);
      expect(() => snapshot.versionsFor(first).clear(), throwsUnsupportedError);
      expect(() => snapshot.episodesFor(first).clear(), throwsUnsupportedError);
      expect(store.fullReads, 0);

      store.setLocal('location:recognized', {
        'source': 'local',
        'path': '/series/Original S01E01.mkv',
      });
      final updated = await model.loadLibrarySnapshot();
      expect(updated.episodesFor(first).map((record) => record.id), [
        'recognized',
        'next',
      ]);
      expect(snapshot.episodesFor(first).first.id, 'alternate');
      expect(store.fullReads, 0);
    },
  );

  test(
    'filename aliases respect the recorded season and exclude movies',
    () async {
      for (final season in ['1', '2']) {
        store.save('media', 'season-$season', {
          'fileName': 'Original - 01.mkv',
          'title': 'Original - 01.mkv',
          'series': 'Original',
          'season': season,
          'episode': '1',
          if (season == '2') 'bangumiId': '7',
        });
      }
      store.save('media', 'movie', {
        'title': 'Original - 01.mkv',
        'series': 'Original',
        'season': '1',
        'episode': '1',
        'tmdbId': '9',
        'metadataType': 'movie',
      });
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.series, hasLength(3));
      expect(
        snapshot.seriesKeyFor(snapshot.byId['season-1']!),
        'parsed:original:1',
      );
      expect(snapshot.seriesKeyFor(snapshot.byId['season-2']!), 'bangumi:7:2');
      final corrected = store.get('media', 'season-2')!;
      store.save('media', corrected.id, {
        ...corrected.data,
        'fileName': 'Original S01E01.mkv',
      });
      final refreshed = await model.loadLibrarySnapshot();
      expect(refreshed.series, hasLength(3));
      expect(
        refreshed.seriesKeyFor(refreshed.byId['season-1']!),
        'parsed:original:1',
      );
    },
  );

  test(
    'a corrected parsed title does not rejoin its original filename series',
    () async {
      store.save('media', 'recognized', {
        'fileName': 'Original S01E01.mkv',
        'series': '正式作品',
        'season': '1',
        'episode': '1',
        'bangumiId': '7',
      });
      store.save('media', 'corrected', {
        'fileName': 'Original S01E02.mkv',
        'series': 'Different',
        'season': '1',
        'episode': '2',
      });
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.series, hasLength(2));
      expect(
        snapshot.seriesKeyFor(snapshot.byId['corrected']!),
        'parsed:different:1',
      );
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
