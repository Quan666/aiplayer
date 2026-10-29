import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/directory_preview_context.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'single downloaded episode borrows saved remote facts through nested folders',
    () async {
      final f = await _Fixture.create();
      try {
        f.add(
          'remote',
          episode: 13,
          folder: 'Remote',
          identified: true,
          offline: false,
        );
        f.add('local', episode: 16, folder: 'Show/Season 1/Disc 1');
        final snapshot = await f.read();
        final show = f.folder(snapshot, 'Show'),
            season = f.folder(snapshot, 'Season 1'),
            disc = f.folder(snapshot, 'Disc 1');
        for (final folder in [show, season, disc]) {
          expect(folder.seriesKey, 'bangumi:42:1');
          expect(folder.anchor?.id, 'local');
          expect(folder.details?.title, 'Recognized Show');
          expect(folder.details?.poster, 'https://example.test/poster.jpg');
          expect(folder.details?.summary, 'Saved summary');
          expect(folder.details?.availableEpisodes, 1);
          expect(folder.details?.videoCount, 1);
          expect(folder.details?.totalEpisodes, 24);
          expect(folder.episodes.map((item) => item.id), ['local']);
        }
        expect(show.records, isEmpty);
        expect(season.records, isEmpty);
        expect(disc.records.keys, ['local']);
        expect(show.collectionRecords, same(season.collectionRecords));
        expect(season.episodes, same(disc.episodes));
        expect(
          show.collectionRecordsByPath,
          same(disc.collectionRecordsByPath),
        );
        expect(show.collectionEntries.map((entry) => entry.name), [
          'Season 1',
          'Show.S01E16.mkv',
        ]);
        expect(show.collectionRecordsByPath.keys, ['local']);
        expect(snapshot.localDirectories['']!.details, isNull);
        expect(
          snapshot.localDirectories.values
              .singleWhere((item) => item.sourceId == 'nas')
              .details,
          isNull,
        );
        expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
        expect(f.store.fullReads, 0);
        for (final list in [
          show.episodes,
          show.collectionRecords,
          show.collectionEntries,
        ]) {
          expect(() => list.clear(), throwsUnsupportedError);
        }
        expect(
          () => show.collectionRecordsByPath.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => show.anchor!.data['poster'] = 'changed',
          throwsUnsupportedError,
        );
        f.store.removeLocal('sources');
        expect(
          f.folder(await f.read(), 'Show').details?.poster,
          'https://example.test/poster.jpg',
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'selected download root itself receives its saved collection identity',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('one', folder: 'Archive/Show/Season 1', identified: true);
        f.offline['one']!.addAll({
          'downloadRoot': 'Archive/Show',
          'downloadRelativePath': 'Show/Season 1/Show.S01E01.mkv',
        });
        final snapshot = await f.read();
        final root = snapshot.localDirectories['']!.entries.single;
        expect(root.name, 'Show');
        final show = snapshot.localDirectories[root.path]!;
        expect(show.sourceId, isNull);
        expect(show.details?.availableEpisodes, 1);
        expect(show.details?.poster, 'https://example.test/poster.jpg');
        expect(show.episodes.single.id, 'one');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'mixed shows and seasons retain plain parents and pure nested children',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('one', folder: 'Archive/Show/Season 1', identified: true);
        f.add(
          'two',
          folder: 'Archive/Show/Season 2',
          season: 2,
          identified: true,
        );
        f.add(
          'other',
          folder: 'Archive/Other',
          series: 'Other',
          catalogue: '99',
          identified: true,
        );
        final snapshot = await f.read();
        expect(f.folder(snapshot, 'Archive').details, isNull);
        expect(f.folder(snapshot, 'Show').details, isNull);
        expect(f.folder(snapshot, 'Season 1').details?.season, '1');
        expect(f.folder(snapshot, 'Season 2').details?.season, '2');
        expect(f.folder(snapshot, 'Other').seriesKey, 'bangumi:99:1');
        expect(
          snapshot.localDirectories.values.fold<int>(
            0,
            (sum, item) => sum + item.records.length,
          ),
          3,
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'same title with different verified identities is never merged',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('one', identified: true);
        f.add('two', identified: true, catalogue: '99', episode: 2);
        final folder = f.folder(await f.read(), 'Show');
        expect(folder.details, isNull);
        expect(folder.anchor, isNull);
        expect(folder.collectionEntries, isEmpty);
        expect(folder.entries, hasLength(2));
      } finally {
        await f.close();
      }
    },
  );

  test(
    'unidentified folders stay browseable and subtitles preserve recognized episodes',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('unknown', folder: 'Unknown', series: 'Unknown');
        f.add('episode', identified: true);
        f.add('subtitle', name: 'episode.zh.srt', series: '', noEpisode: true);
        final snapshot = await f.read();
        expect(f.folder(snapshot, 'Unknown').details, isNull);
        expect(f.folder(snapshot, 'Unknown').entries.single.path, 'unknown');
        final show = f.folder(snapshot, 'Show');
        expect(show.details?.availableEpisodes, 1);
        expect(show.details?.videoCount, 1);
        expect(show.collectionEntries.map((entry) => entry.path), [
          'subtitle',
          'episode',
        ]);
        expect(show.collectionRecordsByPath.keys, ['subtitle', 'episode']);
        f.add('unrelated', series: '', noEpisode: true);
        expect(f.folder(await f.read(), 'Show').details, isNull);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'episode rows choose local versions and exclude remote-only members',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('low', identified: true, name: 'Show.S01E01.720p.mkv');
        f.add('high', name: 'Show.S01E01.1080p.mkv');
        f.add('two', episode: 2);
        f.add('remote', name: 'Show.S01E01.2160p.mkv', offline: false);
        f.add('remote-only', episode: 3, offline: false);
        final snapshot = await f.read();
        final folder = f.folder(snapshot, 'Show');
        expect(folder.episodes.map((record) => record.id), ['high', 'two']);
        expect(folder.collectionRecords, hasLength(3));
        expect(folder.details?.availableEpisodes, 2);
        expect(folder.details?.videoCount, 3);
        expect(folder.collectionEntries.map((entry) => entry.path), [
          'high',
          'two',
        ]);
        expect(
          folder.collectionRecordsByPath['high'],
          same(snapshot.byId['high']),
        );
        const MediaTechnicalInfo(
          width: 3840,
          height: 2160,
        ).save(f.store, f.store.get('media', 'low')!);
        expect(f.folder(await f.read(), 'Show').episodes.first.id, 'low');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'manual edits, external commits, direct SQL and rollback refresh metadata',
    () async {
      final f = await _Fixture.create();
      final external = AppStore.openExisting(f.store.path);
      try {
        f.add('one', identified: true);
        f.add('two', episode: 2);
        final original = f.folder(await f.read(), 'Show');
        final edited = {
          ...external.get('media', 'one')!.data,
          'metadataTitle': 'Manual correction',
          'poster': 'https://example.test/new.jpg',
        };
        external.save('media', 'one', edited);
        expect(
          f.folder(await f.read(), 'Show').details?.title,
          'Manual correction',
        );
        expect(original.details?.title, 'Recognized Show');
        expect(
          () => f.store.transaction(() {
            f.store.save('media', 'one', {
              ...edited,
              'metadataTitle': 'Rolled back',
            });
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(
          f.folder(await f.read(), 'Show').details?.title,
          'Manual correction',
        );
        external.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
          jsonEncode({
            ...external.get('media', 'two')!.data,
            'bangumiId': '99',
          }),
          'media',
          'two',
        ]);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.save('media', 'two', {}, deleted: true);
        expect(
          f.folder(await f.read(), 'Show').details?.title,
          'Manual correction',
        );
        expect(f.store.fullReads, 0);
      } finally {
        external.dispose();
        await f.close();
      }
    },
  );

  test(
    'offline removal and rebinding prune stale folders while unbound copies survive',
    () async {
      final f = await _Fixture.create();
      final external = AppStore.openExisting(f.store.path);
      try {
        f.add('one', identified: true);
        f.add('two', episode: 2);
        final first = await f.read();
        expect(f.folder(first, 'Show').details?.availableEpisodes, 2);
        f.offline.remove('two');
        f.offlineRevision++;
        expect(f.folder(await f.read(), 'Show').details?.availableEpisodes, 1);
        external.removeLocal('location:one');
        expect(f.folder(await f.read(), 'Show').episodes.single.id, 'one');
        external.setLocal('location:one', {
          'source': 'other',
          'path': '/replacement.mkv',
        });
        final rebound = await f.read();
        expect(rebound.localDirectories.keys, ['']);
        expect(rebound.localDirectoryLatest, isEmpty);
        expect(f.folder(first, 'Show').details?.availableEpisodes, 2);
      } finally {
        external.dispose();
        await f.close();
      }
    },
  );

  test(
    'progress refresh shares hierarchy and resumes only local descendants',
    () async {
      final f = await _Fixture.create(memory: true);
      try {
        f.add('one', identified: true);
        f.add('two', episode: 2);
        f.add('remote', episode: 3, offline: false);
        final first = await f.read();
        final path = f.folder(first, 'Show').path;
        f.store.save('progress', 'one:32', {
          'position': 5,
          'updatedAt': '2026-10-20',
        });
        f.store.save('progress', 'remote:32', {
          'position': 9,
          'updatedAt': '2026-10-29',
        });
        final second = await f.read();
        expect(second.localDirectories, same(first.localDirectories));
        expect(second.localDirectoryLatest[path]?.id, 'one');
        f.store.save('progress', 'two:32', {
          'position': 7,
          'updatedAt': '2026-10-30',
        });
        final third = await f.read();
        expect(third.localDirectories, same(first.localDirectories));
        expect(third.localDirectoryLatest[path]?.id, 'two');
        expect(second.localDirectoryLatest[path]?.id, 'one');
        expect(
          () => third.localDirectoryLatest.clear(),
          throwsUnsupportedError,
        );
        f.store.save('progress', 'two:32', {}, deleted: true);
        expect((await f.read()).localDirectoryLatest[path]?.id, 'one');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'disk cached subject enriches existing local records without writes or remote members',
    () async {
      final f = await _Fixture.create();
      try {
        f.add('local', episode: 16);
        f.add('remote-only', episode: 17, offline: false);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        f.cache(['local', 'remote-only']);
        final revision = f.store.recordsRevision('media');
        final snapshot = await f.read();
        final folder = f.folder(snapshot, 'Show');
        expect(folder.details?.title, 'Cached Show');
        expect(folder.details?.summary, 'Cached summary');
        expect(folder.details?.totalEpisodes, 24);
        expect(folder.details?.availableEpisodes, 1);
        expect(folder.episodes.single.id, 'local');
        expect(folder.anchor!.data['bangumiId'], '42');
        expect(snapshot.byId['local']!.data['bangumiId'], isNull);
        expect(f.store.get('media', 'local')!.data['bangumiId'], isNull);
        expect(f.store.recordsRevision('media'), revision);
        expect(
          snapshot.playbackOptionsFor(folder.episodes.single),
          hasLength(2),
        );
        expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
        expect(f.store.fullReads, 0);
        f.store.save('progress', 'local:32', {
          'position': 4,
          'updatedAt': '2026-10-29',
        });
        final progress = await f.read();
        expect(
          progress.localDirectoryLatest[folder.path]?.data['episodeTitle'],
          'Cached episode 16',
        );
      } finally {
        await f.close();
      }
    },
  );

  for (final merge in [true, false]) {
    test(
      'cached identity ${merge ? "merges" : "splits"} raw groups consistently for rows and source options',
      () async {
        final f = await _Fixture.create();
        try {
          f.add('low', episode: 1, name: 'low.mkv');
          f.add('high', episode: merge ? 2 : 1, name: 'high.mkv');
          const MediaTechnicalInfo(
            width: 1280,
            height: 720,
          ).save(f.store, f.store.get('media', 'low')!);
          const MediaTechnicalInfo(
            width: 1920,
            height: 1080,
          ).save(f.store, f.store.get('media', 'high')!);
          f.cache(
            ['low', 'high'],
            episodes: {'low': '1', 'high': merge ? '1' : '2'},
          );
          final snapshot = await f.read();
          final folder = f.folder(snapshot, 'Show');
          expect(
            folder.episodes.map((item) => item.id),
            merge ? ['high'] : ['low', 'high'],
          );
          final options = snapshot.playbackOptionsFor(snapshot.byId['low']!);
          expect(
            options.map((option) => option.media.id).toSet(),
            merge ? {'low', 'high'} : {'low'},
          );
          expect(options.first.media.id, merge ? 'high' : 'low');
          expect(
            snapshot
                .playbackOptionsFor(snapshot.byId['high']!)
                .map((option) => option.media.id)
                .toSet(),
            merge ? {'low', 'high'} : {'high'},
          );
          expect(snapshot.byId['high']!.data['episode'], merge ? '2' : '1');
          expect(folder.details?.availableEpisodes, merge ? 1 : 2);
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'existing canonical metadata wins over an older conflicting directory cache',
    () async {
      final f = await _Fixture.create();
      try {
        f.add(
          'recognized',
          folder: 'Other directory',
          episode: 13,
          offline: false,
          identified: true,
          catalogue: '99',
        );
        f.add('local', episode: 16);
        f.cache(['local'], title: 'Obsolete cached match');
        final snapshot = await f.read();
        final folder = f.folder(snapshot, 'Show');
        expect(folder.seriesKey, 'bangumi:99:1');
        expect(folder.details?.title, 'Recognized Show');
        expect(folder.details?.poster, 'https://example.test/poster.jpg');
        expect(folder.details?.availableEpisodes, 1);
        expect(folder.episodes.single.id, 'local');
        expect(snapshot.localRecords['local']!.data['bangumiId'], isNull);
        expect(snapshot.localPlaybackOptionsById, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'cached presentation honors manual and verified identity across cache revisions',
    () async {
      final f = await _Fixture.create();
      final external = AppStore.openExisting(f.store.path);
      try {
        f.add('local');
        f.cache(['local']);
        expect(f.folder(await f.read(), 'Show').details?.title, 'Cached Show');
        external.setLocal('manualMetadata:local', true);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.removeLocal('manualMetadata:local');
        expect(f.folder(await f.read(), 'Show').details?.title, 'Cached Show');
        external.save('media', 'local', {
          ...external.get('media', 'local')!.data,
          'bangumiId': '99',
          'metadataTitle': 'Correct identity',
          'poster': 'https://example.test/manual.jpg',
        });
        expect(
          f.folder(await f.read(), 'Show').details?.title,
          'Correct identity',
        );
        f.cache(['local'], title: 'Old wrong cache');
        final folder = f.folder(await f.read(), 'Show');
        expect(folder.seriesKey, 'bangumi:99:1');
        expect(folder.details?.poster, 'https://example.test/manual.jpg');
      } finally {
        external.dispose();
        await f.close();
      }
    },
  );

  test(
    'cache epochs, matching facts, contexts, SQL and rollback invalidate disk donors',
    () async {
      final f = await _Fixture.create();
      final external = AppStore.openExisting(f.store.path);
      try {
        f.add('local');
        f.cache(['local']);
        final first = await f.read();
        expect(f.folder(first, 'Show').details?.title, 'Cached Show');
        final before = f.model.libraryLocalMetadataRevision;
        external.setLocal('settings', {'volume': 50});
        expect(f.model.libraryLocalMetadataRevision, before);
        expect(
          f.folder(await f.read(), 'Show').details?.title,
          f.folder(first, 'Show').details?.title,
        );
        external.setLocal('directoryPreviewEpoch', 1);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.setLocal('directoryPreviewEpoch', 0);
        expect(f.folder(await f.read(), 'Show').details?.title, 'Cached Show');
        external.setLocal('directoryPreviewSourceEpoch:nas', 1);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.setLocal('directoryPreviewSourceEpoch:nas', 0);
        external.setLocal('metadataCredentialsRevision', 'new credentials');
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.removeLocal('metadataCredentialsRevision');
        expect(
          () => f.store.transaction(() {
            f.store.setLocal('directoryPreviewEpoch', 3);
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(f.folder(await f.read(), 'Show').details?.title, 'Cached Show');
        final key = directoryPreviewStorageKey('nas', 'Show');
        final raw = Map<String, dynamic>.from(external.local(key));
        external.db.execute('UPDATE local SET value=? WHERE key=?', [
          jsonEncode({...raw, 'membershipRevision': -1}),
          key,
        ]);
        expect(f.folder(await f.read(), 'Show').details, isNull);
        f.cache(['local']);
        external.setLocal('location:local', {
          ...external.local('location:local') as Map,
          'size': 99,
        });
        expect(f.folder(await f.read(), 'Show').details, isNull);
        external.setLocal('location:local', {
          ...external.local('location:local') as Map,
          'size': 32,
          'modified': 9,
        });
        expect(f.folder(await f.read(), 'Show').details, isNull);
        expect(f.store.fullReads, 0);
      } finally {
        external.dispose();
        await f.close();
      }
    },
  );
}

class _Fixture {
  final Directory directory;
  final _CountingStore store;
  final offline = <String, Map<String, dynamic>>{};
  int offlineRevision = 0;
  late final reader = LibrarySnapshotReader(store);
  late final model = AppModel(store, directory, backgroundWork: false);
  _Fixture(this.directory, this.store);
  static Future<_Fixture> create({bool memory = false}) async {
    final directory = await Directory.systemTemp.createTemp(
      'local-directory-collection-',
    );
    final store = _CountingStore(
      memory ? ':memory:' : '${directory.path}/app.db',
    );
    store.setLocal('sources', [
      {'id': 'nas', 'label': 'NAS', 'kind': 'smb'},
    ]);
    return _Fixture(directory, store);
  }

  void add(
    String id, {
    String folder = 'Show',
    String series = 'Show',
    String catalogue = '42',
    bool identified = false,
    bool offline = true,
    int episode = 1,
    int season = 1,
    String? name,
    bool noEpisode = false,
  }) {
    name ??= '$series.S0${season}E${episode.toString().padLeft(2, '0')}.mkv';
    final path = '$folder/$name';
    store.save('media', id, {
      'title': name,
      'fileName': name,
      'size': 32,
      'series': series,
      'season': '$season',
      if (!noEpisode) 'episode': '$episode',
      if (identified) ...{
        'bangumiId': catalogue,
        'metadataTitle': 'Recognized $series',
        'poster': 'https://example.test/poster.jpg',
        'summary': 'Saved summary',
        'totalEpisodes': 24,
      },
    });
    store.setLocal('location:$id', {'source': 'nas', 'path': path, 'size': 32});
    if (offline) {
      this.offline[id] = {
        'source': 'local',
        'path': '/managed/$id.mkv',
        'size': 32,
        'remoteSource': 'nas',
        'remotePath': path,
        'remoteRevision': '',
      };
      offlineRevision++;
    }
  }

  void cache(
    List<String> ids, {
    String title = 'Cached Show',
    Map<String, String> episodes = const {},
  }) {
    final settings = Map<String, dynamic>.from(store.local('settings') ?? {});
    final records = [for (final id in ids) store.get('media', id)!];
    final videos = [
      for (final record in records)
        SourceEntry(
          name: record.data['fileName'],
          path: store.local('location:${record.id}')['path'],
          size: 32,
        ),
    ];
    persistDirectoryPreview(
      store,
      'nas',
      'Show',
      DirectoryPreview(
        context: directoryPreviewContext(
          source: (store.local('sources') as List).single as Map,
          strategy: settings['metadataStrategy'] ?? 'conservative',
          aiContext: jsonEncode([
            AppPreferences(settings).aiMetadataEnabled,
            settings['aiSubtitleOrigin'],
            settings['aiSubtitleModel'],
            store.local('metadataCredentialsRevision'),
          ]),
        ),
        fingerprint: 'listing',
        updatedAt: 1,
        modified: 0,
        collection: DirectoryCollection(
          title: 'Show',
          season: '1',
          videos: videos,
          identities: {
            for (var i = 0; i < records.length; i++)
              videos[i].path: ReleaseName(
                'Show',
                '1',
                episodes[records[i].id] ?? records[i].data['episode'],
              ),
          },
          episodeTitles: {
            for (final record in records)
              '${record.data['episode']}':
                  'Cached episode ${record.data['episode']}',
          },
          subject: {
            'id': 42,
            'name': title,
            'summary': 'Cached summary',
            'eps': 24,
            'images': {'large': 'https://example.test/cached.jpg'},
          },
        ),
      ),
    );
  }

  LocalDirectorySnapshot folder(LibrarySnapshot snapshot, String name) =>
      snapshot.localDirectories.values.singleWhere((item) => item.name == name);
  Future<LibrarySnapshot> read() => reader.read(
    query: '',
    revision: (
      store.recordsRevision('media'),
      store.recordsRevision('progress'),
      max(
        max(store.locationRevision, store.localKeyRevision('sources')),
        store.localPrefixRevision('technical:'),
      ),
    ),
    localMetadataRevision: model.libraryLocalMetadataRevision,
    offlineRevision: offlineRevision,
    offlineLocations: offline,
  );
  Future<void> close() async {
    reader.dispose();
    model.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  }
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
