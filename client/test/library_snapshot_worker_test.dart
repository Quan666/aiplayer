import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/library_sort.dart';
import 'package:aiplayer/data/media_title_translation.dart';
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

  for (final disk in [false, true]) {
    test(
      'progress-only refresh preserves structural indices (disk: $disk)',
      () async {
        final source = _CountingStore(
          disk ? '${directory.path}/progress.db' : ':memory:',
        );
        final writer = disk ? AppStore.openExisting(source.path) : source;
        final reader = LibrarySnapshotReader(source);
        addTearDown(() {
          reader.dispose();
          if (disk) writer.dispose();
          source.dispose();
        });
        for (final entry in [
          ('a-1', 'Alpha', '1'),
          ('a-2', 'Alpha', '2'),
          ('b', 'Beta', '1'),
        ]) {
          writer.save('media', entry.$1, {
            'title': entry.$2,
            'series': entry.$2,
            'episode': entry.$3,
            'size': 10,
          });
          writer.setLocal('location:${entry.$1}', {
            'source': 'nas',
            'path': 'Shows/${entry.$1}.mkv',
            'size': 10,
          });
        }
        Future<LibrarySnapshot> read() => reader.read(
          query: '',
          revision: (
            source.recordsRevision('media'),
            source.recordsRevision('progress'),
            source.locationRevision,
          ),
        );
        void played(String id, String at) =>
            writer.save('progress', '$id:10', {'position': 5, 'updatedAt': at});
        final original = await read();
        final fullReads = source.fullReads;
        played('a-1', '2026-10-20');
        final first = await read();
        expect(source.fullReads - fullReads, disk ? 0 : 1);
        expect(first.recent.single.id, 'a-1');
        final alpha = first.seriesKeyFor(first.byId['a-1']!);
        const folder = 'nas\u0000Shows';
        if (!disk) {
          expect(first.media, same(original.media));
          expect(first.series, same(original.series));
          expect(first.episodes, same(original.episodes));
          expect(first.details, same(original.details));
          expect(first.locations, same(original.locations));
          expect(first.recordsBySource, same(original.recordsBySource));
          expect(
            first.folders[folder]!.entries,
            same(original.folders[folder]!.entries),
          );
          expect(
            first.folders[folder]!.recordsByPath,
            same(original.folders[folder]!.recordsByPath),
          );
        }
        expect(
          first.folders[folder]!.recordsByPath['Shows/a-2.mkv']!.id,
          'a-2',
        );
        expect(
          () => first.folders[folder]!.recordsByPath.clear(),
          throwsUnsupportedError,
        );
        played('a-2', '2026-10-21');
        played('b', '2026-10-22');
        final advanced = await read();
        expect(advanced.recent.map((record) => record.id), ['b', 'a-2']);
        expect(advanced.groups.map((group) => group.value.first.id), [
          'b',
          'a-1',
        ]);
        expect(advanced.latestBySeries[alpha]!.id, 'a-2');
        expect(advanced.folders[folder]!.latestBySeries[alpha]!.id, 'a-2');
        writer.save('progress', 'a-2:10', {}, deleted: true);
        final removed = await read();
        expect(removed.latestBySeries[alpha]!.id, 'a-1');
        expect(removed.folders[folder]!.latestBySeries[alpha]!.id, 'a-1');
        expect(advanced.latestBySeries[alpha]!.id, 'a-2');
        expect(advanced.progress, contains('a-2:10'));
        writer.save('progress', 'b:10', {}, deleted: true);
        writer.save('progress', 'a-1:10', {
          'position': 0,
          'updatedAt': '2026-10-23',
        });
        final cleared = await read();
        expect(cleared.recent, isEmpty);
        expect(cleared.folders[folder]!.latestBySeries, isEmpty);
        expect(cleared.groups.map((group) => group.value.first.id), [
          'a-1',
          'b',
        ]);
        expect(
          () => cleared.folders[folder]!.latestBySeries.clear(),
          throwsUnsupportedError,
        );

        played('a-1', '2026-10-24');
        expect((await read()).recent.single.id, 'a-1');
        writer.setLocal('location:a-1', {
          'source': 'nas',
          'path': 'Other/a-1.mkv',
          'size': 20,
        });
        final relocated = await read();
        expect(relocated.recent, isEmpty);
        expect(relocated.folders, contains('nas\u0000Other'));
        expect(relocated.folders[folder]!.records.map((record) => record.id), [
          'a-2',
          'b',
        ]);
        final media = writer.get('media', 'a-1')!;
        writer.save('media', media.id, {...media.data, 'series': 'Changed'});
        final changed = await read();
        expect(changed.series, hasLength(3));
        expect(changed.seriesKeyFor(changed.byId['a-1']!), isNot(alpha));
      },
    );
  }

  test(
    'local import index follows source and metadata revisions in worker',
    () async {
      for (final id in [
        'local',
        'remote',
        'hidden',
        'subtitle',
        'hidden-subtitle',
        'transient',
      ]) {
        store.save('media', id, {
          'title': '$id.mp4',
          if (id == 'hidden') 'fileName': '.hidden.mp4',
          if (id == 'subtitle') 'fileName': 'Captions.srt',
          if (id == 'hidden-subtitle') 'fileName': '.Captions.srt',
          if (id == 'transient') 'transient': true,
        });
        store.setLocal('location:$id', {
          'source': id == 'remote' ? 'nas' : 'local',
          'path': '/media/$id.mp4',
          'size': 30,
          'modified': 12,
        });
      }
      final first = await model.loadLibrarySnapshot();
      expect(first.localRecords.keys.toSet(), {
        'local',
        'hidden',
        'subtitle',
        'hidden-subtitle',
      });
      expect(first.localEntries.map((entry) => entry.path).toSet(), {
        'local',
        'hidden',
        'subtitle',
        'hidden-subtitle',
      });
      expect(first.localHiddenEntries, 2);
      expect(first.localSubtitleEntries, 2);
      expect(first.localHiddenSubtitleEntries, 1);
      final hidden = first.localEntries.singleWhere(
        (entry) => entry.path == 'hidden',
      );
      expect(hidden.name, '.hidden.mp4');
      expect(hidden.size, 30);
      expect(hidden.modified, 12);
      expect(() => first.localEntries.clear(), throwsUnsupportedError);
      expect(() => first.localRecords.clear(), throwsUnsupportedError);
      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      external.setLocal('location:local', {
        'source': 'nas',
        'path': '/media/local.mp4',
        'size': 40,
      });
      external.save('media', 'hidden', {}, deleted: true);
      external.save('media', 'hidden-subtitle', {}, deleted: true);
      final changed = await model.loadLibrarySnapshot();
      expect(changed.localRecords.keys, ['subtitle']);
      expect(changed.localEntries.single.name, 'Captions.srt');
      expect(changed.localHiddenEntries, 0);
      expect(changed.localSubtitleEntries, 1);
      expect(changed.localHiddenSubtitleEntries, 0);
      expect(changed.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(store.fullReads, 0);
    },
  );

  test('all-video ordering aggregates complete groups in the worker', () async {
    void save(
      String id,
      String title,
      String updated, {
      String? episode,
      int? size,
      bool poster = false,
    }) {
      store.save('media', id, {
        'title': title,
        if (episode != null) ...{'series': title, 'episode': episode},
        'size': ?size,
        if (poster) 'poster': 'https://example.test/poster.jpg',
      }, modifiedAt: updated);
    }

    save('a-1', 'Show 10', '2026-10-20', episode: '1', size: 3);
    save('a-2', 'Show 10', '2026-10-21', episode: '2', size: 4, poster: true);
    save('b', 'Show 2', '2026-10-23', size: 12);
    save('c', 'Movie', '2026-10-22');
    save('d', 'Unknown', '2026-10-22');
    store.db.execute("UPDATE records SET modified_at='' WHERE id='d'");
    store.setLocal('location:a-1', {
      'size': 30,
      'modified': DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
    });
    store.setLocal('location:a-2', {
      'size': 4,
      'modified': DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
    });
    store.setLocal('location:b', {
      'size': 12,
      'modified': DateTime.utc(2026, 10, 23).millisecondsSinceEpoch,
    });
    store.save('progress', 'a-1:3', {'position': 5, 'updatedAt': '2026-10-30'});
    store.save('progress', 'a-2:4', {
      'position': 5,
      'updatedAt': '2026-10-24T08:00:00+08:00',
    });
    store.save('progress', 'b:12', {
      'position': 5,
      'updatedAt': '2026-10-23T23:00:00Z',
    });
    store.save('progress', 'c:0', {'position': 0, 'updatedAt': '2026-10-30'});
    store.fullReads = 0;
    final reader = LibrarySnapshotReader(store);
    addTearDown(reader.dispose);
    Future<LibrarySnapshot> read(String field, {bool descending = true}) =>
        reader.read(
          query: '',
          revision: (
            store.recordsRevision('media'),
            store.recordsRevision('progress'),
            store.locationRevision,
          ),
          sort: LibrarySort(field: field, descending: descending),
        );
    List<String> ids(LibrarySnapshot snapshot) =>
        snapshot.groups.map((group) => group.value.first.id).toList();

    final recent = await read('recent');
    expect(ids(recent), ['a-1', 'b', 'c', 'd']);
    expect(recent.preparationIsolate, isNot(Isolate.current.hashCode));
    expect(recent.groups.first.value.map((record) => record.id), [
      'a-1',
      'a-2',
    ]);
    expect(ids(await read('recent', descending: false)), [
      'b',
      'a-1',
      'c',
      'd',
    ]);
    expect(ids(await read('modified')), ['a-1', 'b', 'c', 'd']);
    expect(ids(await read('modified', descending: false)), [
      'c',
      'b',
      'a-1',
      'd',
    ]);
    expect(ids(await read('updated')), ['b', 'c', 'a-1', 'd']);
    expect(ids(await read('size')), ['a-1', 'b', 'c', 'd']);
    expect(ids(await read('size', descending: false)), ['b', 'a-1', 'c', 'd']);
    final named = await read('name', descending: false);
    expect(ids(named), ['c', 'b', 'a-1', 'd']);
    expect(named.posters.single.key, recent.posters.single.key);
    expect(named.files.map((group) => group.value.first.id), ['c', 'b', 'd']);
    expect(() => named.groups.clear(), throwsUnsupportedError);
    expect(
      named.recent.map((record) => record.id),
      recent.recent.map((record) => record.id),
    );
    expect(store.fullReads, 0);
  });

  test(
    'sorting is deterministic, cached by preference and refreshed in flight',
    () async {
      for (final id in ['c', 'a', 'b']) {
        store.save('media', id, {'title': 'Same', 'size': 12});
      }
      await model.setLibrarySorting(
        const LibrarySort(field: 'name', descending: false),
      );
      final first = await model.loadLibrarySnapshot();
      expect(first.groups.map((group) => group.value.single.id), [
        'a',
        'b',
        'c',
      ]);
      expect(await model.loadLibrarySnapshot(), same(first));
      model.updatePreferences({'volume': 40});
      expect(await model.loadLibrarySnapshot(), same(first));
      store.save('media', 'd', {'title': 'Zebra'});
      final inFlight = model.loadLibrarySnapshot();
      await model.setLibrarySorting(const LibrarySort(field: 'name'));
      await inFlight;
      final changed = await model.loadLibrarySnapshot();
      expect(changed.sort, const LibrarySort(field: 'name'));
      expect(changed.groups.map((group) => group.value.single.id), [
        'd',
        'a',
        'b',
        'c',
      ]);
      expect(await model.loadLibrarySnapshot(), same(changed));
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
      expect(filtered.searchRecent.map((item) => item.id), ['alpha-1']);
      expect(snapshot.searchRecent, same(snapshot.recent));
      expect(store.fullReads, 0);
    },
  );

  test(
    'search finds older history by any episode and resumes the latest in its series',
    () async {
      for (var index = 0; index < 15; index++) {
        store.save('media', 'newer-$index', {
          'title': 'Newer recording $index',
          'size': 10,
        });
        store.save('progress', 'newer-$index:10', {
          'position': 5,
          'updatedAt': DateTime.utc(2026, 10, index + 10).toIso8601String(),
        });
      }
      for (var episode = 1; episode <= 3; episode++) {
        store.save('media', 'older-$episode', {
          'title': 'Original S01E0$episode.mkv',
          'fileName': 'Original S01E0$episode.mkv',
          'series': episode == 2 ? '正式作品' : 'Original',
          'season': '1',
          'episode': '$episode',
          'size': 10,
          if (episode == 1) 'episodeTitle': 'Forgotten episode',
          if (episode == 2) ...{
            'bangumiId': '7',
            'metadataTitle': '正式作品',
            'poster': 'https://example.test/series.jpg',
          },
        });
      }
      for (final episode in [1, 3]) {
        store.save('progress', 'older-$episode:10', {
          'position': episode * 5,
          'updatedAt': DateTime.utc(2026, 10, episode).toIso8601String(),
        });
      }
      final original = await model.loadLibrarySnapshot();
      expect(original.recent, hasLength(16));
      expect(original.recent.last.id, 'older-3');
      for (final query in ['ORIGINAL', '正式作品', 'S01E02', 'Forgotten']) {
        final filtered = await model.loadLibrarySnapshot(query: query);
        expect(filtered.searchRecent.single.id, 'older-3');
        expect(filtered.recent, hasLength(16));
        expect(filtered.posters.single.value, hasLength(3));
        expect(filtered.preparationIsolate, isNot(Isolate.current.hashCode));
        expect(() => filtered.searchRecent.clear(), throwsUnsupportedError);
      }
      final missing = await model.loadLibrarySnapshot(query: 'missing');
      expect(missing.searchRecent, isEmpty);
      expect(missing.groups, isEmpty);
      expect(missing.recent, hasLength(16));

      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      external.save('progress', 'older-1:10', {
        'position': 80,
        'updatedAt': '2026-10-25',
      });
      final advanced = await model.loadLibrarySnapshot(query: 'Forgotten');
      expect(advanced.searchRecent.single.id, 'older-1');
      expect(advanced.progress['older-1:10']!['position'], 80);
      external.save('progress', 'older-1:10', {}, deleted: true);
      final removed = await model.loadLibrarySnapshot(query: 'Forgotten');
      expect(removed.searchRecent.single.id, 'older-3');
      expect(advanced.searchRecent.single.id, 'older-1');
      external.save('progress', 'older-3:10', {}, deleted: true);
      final cleared = await model.loadLibrarySnapshot(query: 'Forgotten');
      expect(cleared.searchRecent, isEmpty);
      expect(cleared.posters.single.value, hasLength(3));
      expect(store.fullReads, 0);
    },
  );

  test(
    'search indexes current visible titles without invalidating unfiltered snapshots',
    () async {
      for (var episode = 1; episode <= 2; episode++) {
        store.save('media', 'episode-$episode', {
          'title': 'Example S01E0$episode.mkv',
          'series': 'Example',
          'season': '1',
          'episode': '$episode',
          'size': 10,
        });
        store.save('progress', 'episode-$episode:10', {
          'position': 5,
          'updatedAt': '2026-10-2$episode',
        });
      }
      final unfiltered = await model.loadLibrarySnapshot();
      store.setLocal('episodeTitle:episode-1', 'Cached pilot');
      store.setLocal('episodeTitle:episode-2', 'Cached finale');
      expect(await model.loadLibrarySnapshot(), same(unfiltered));
      var filtered = await model.loadLibrarySnapshot(query: ' cached pilot ');
      expect(filtered.query, 'cached pilot');
      expect(filtered.searchRecent.single.id, 'episode-2');
      expect(filtered.preparationIsolate, isNot(Isolate.current.hashCode));

      final key = MediaTitleTranslations.stateKeyFor(
        'parsed:example:1',
        MediaTitleTranslations.profileFor({}),
      );
      final translated = {
        'visible': true,
        'titles': {
          'Example': '示例作品',
          'Cached pilot': '初章',
          'Cached finale': '终章',
        },
      };
      store.setLocal(key, translated);
      for (final query in ['示例作品', '初章', '终章', '第 2 集']) {
        filtered = await model.loadLibrarySnapshot(query: query);
        expect(filtered.searchRecent.single.id, 'episode-2');
        expect(filtered.groups.single.value, hasLength(2));
      }
      final sameQuery = await model.loadLibrarySnapshot(query: '示例作品');
      final searchRevision = model.librarySearchRevision;
      store.setLocal('settings', {'volume': 30});
      store.setLocal('syncState', {'cursor': 12});
      expect(model.librarySearchRevision, searchRevision);
      expect(await model.loadLibrarySnapshot(query: '示例作品'), same(sameQuery));
      store.setLocal('settings', {'aiSubtitleTarget': 'English'});
      expect(
        (await model.loadLibrarySnapshot(query: '示例作品')).searchRecent,
        isEmpty,
      );
      store.setLocal('settings', {});
      expect(
        (await model.loadLibrarySnapshot(query: '示例作品')).searchRecent.single.id,
        'episode-2',
      );

      final external = AppStore.openExisting(store.path);
      addTearDown(external.dispose);
      external.setLocal(key, {...translated, 'visible': false});
      expect(
        (await model.loadLibrarySnapshot(query: '示例作品')).searchRecent,
        isEmpty,
      );
      store.db.execute('UPDATE local SET value=? WHERE key=?', [
        jsonEncode(translated),
        key,
      ]);
      expect(
        (await model.loadLibrarySnapshot(query: '示例作品')).searchRecent.single.id,
        'episode-2',
      );
      store.db.execute('BEGIN');
      store.db.execute('UPDATE local SET value=? WHERE key=?', [
        jsonEncode({...translated, 'visible': false}),
        key,
      ]);
      store.db.execute('ROLLBACK');
      expect(
        (await model.loadLibrarySnapshot(query: '示例作品')).searchRecent.single.id,
        'episode-2',
      );
      external.setLocal('episodeTitle:episode-1', 'Revised pilot');
      expect(
        (await model.loadLibrarySnapshot(query: '初章')).searchRecent,
        isEmpty,
      );
      expect(
        (await model.loadLibrarySnapshot(
          query: 'Revised pilot',
        )).searchRecent.single.id,
        'episode-2',
      );
      external.removeLocal('episodeTitle:episode-1');
      expect(
        (await model.loadLibrarySnapshot(query: 'Revised pilot')).searchRecent,
        isEmpty,
      );
      final inFlight = model.loadLibrarySnapshot(query: 'Arriving title');
      store.setLocal('episodeTitle:episode-1', 'Arriving title');
      expect((await inFlight).searchRecent.single.id, 'episode-2');
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
