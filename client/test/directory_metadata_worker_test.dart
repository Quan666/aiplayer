import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class _BatchStore extends AppStore {
  _BatchStore() : super(':memory:');
  final insertedPerCommit = <int>[];
  void Function()? afterCommit;
  int get count =>
      db
              .select(
                "SELECT count(*) n FROM records WHERE kind='media' AND deleted=0",
              )
              .single['n']
          as int;
  @override
  void transaction(void Function() action) {
    final before = count;
    super.transaction(action);
    insertedPerCommit.add(count - before);
    afterCommit?.call();
  }
}

Map<String, dynamic> _subject(
  String title, {
  String id = '7',
  String provider = 'bangumi',
  String type = 'tv',
}) => {'id': id, 'name': title, 'provider': provider, 'mediaType': type};

DirectoryCollection _collection({
  String title = 'Show',
  int count = 2,
  Map<String, dynamic>? subject,
}) {
  final entries = [
    for (var i = 1; i <= count; i++)
      SourceEntry(
        name: '$title S01E$i.mkv',
        path: 'root/$title/$i.mkv',
        size: i,
      ),
  ];
  return DirectoryCollection(
    title: title,
    season: '1',
    videos: entries,
    identities: {
      for (var i = 0; i < entries.length; i++)
        entries[i].path: ReleaseName(title, '1', '${i + 1}'),
    },
    subject: subject ?? _subject(title),
    episodeTitles: {for (var i = 1; i <= count; i++) '$i': 'Chapter $i'},
  );
}

class _Folders extends SourceAdapter {
  final Map<String, List<SourceEntry>> entries;
  final listed = <String>[];
  int closes = 0;
  _Folders(this.entries);
  @override
  Future<List<SourceEntry>> list(String path) async {
    listed.add(path);
    return entries[path] ?? [];
  }

  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    closes++;
  }
}

class _Catalog extends LibraryCatalog {
  final queries = <String>[];
  bool failNames = false;
  _Catalog(super.store);
  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    queries.add(title);
    cancel?.check();
    return _subject(title);
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (failNames) throw const AppFailure('episode names unavailable');
    return {'1': 'Arrival', '2': 'Departure'};
  }
}

void main() {
  test(
    'mixed listings commit at most 128 entries and cancellation preserves completed batches',
    () async {
      final store = _BatchStore();
      try {
        final group = _collection(count: 1100);
        final first = synchronizeDirectoryCollection(
          store,
          'nas',
          DirectoryCollection(
            title: group.title,
            season: group.season,
            videos: [group.videos.first],
            identities: group.identities,
            subject: group.subject,
          ),
        ).mediaIds.single;
        final entries = [
          ...group.videos,
          const SourceEntry(name: 'trailer.mkv', path: 'root/Show/trailer.mkv'),
        ];
        store.insertedPerCommit.clear();
        final cancel = CancelToken();
        store.afterCommit = cancel.cancel;
        await expectLater(
          synchronizeDirectoryListing(
            store,
            'nas',
            'root/Show',
            entries,
            hideHidden: true,
            anchorId: first,
            cancel: cancel,
          ),
          throwsA(isA<Cancelled>()),
        );
        expect(store.count, 128);
        expect(store.insertedPerCommit, [127]);
        store.afterCommit = null;
        store.insertedPerCommit.clear();
        final completed = await synchronizeDirectoryListing(
          store,
          'nas',
          'root/Show',
          entries,
          hideHidden: true,
          anchorId: first,
          cancel: CancelToken(),
        );
        expect(completed!.mediaIds, hasLength(1100));
        expect(store.count, 1100);
        expect(store.insertedPerCommit, hasLength(9));
        expect(store.insertedPerCommit.every((count) => count <= 128), isTrue);
        expect(
          store.all('media').every((item) => item.data['bangumiId'] == '7'),
          isTrue,
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'episode-name refresh persists on worker and rejects changed identities',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'episode-names-worker-',
      );
      final store = AppStore('${directory.path}/library.db');
      final worker = DirectoryMetadataWorker(store.path);
      try {
        final collection = _collection(count: 300);
        final imported = await worker.synchronize(
          'nas',
          collection,
          importMissing: true,
        );
        final records = store.all('media');
        final anchor = records.first;
        final names = {
          for (var i = 1; i <= 300; i++) '$i': 'Updated chapter $i',
        };
        var responsive = false;
        final work = worker.persistEpisodeNames(
          anchor,
          collection.subject!,
          names,
          mediaIds: imported.mediaIds.toSet(),
        );
        Timer.run(() => responsive = true);
        expect(await work, isTrue);
        expect(responsive, isTrue);
        for (final record in store.all('media')) {
          final expected = names['${record.data['episode']}'];
          expect(record.data['episodeTitle'], expected);
          expect(store.local('episodeTitle:${record.id}'), expected);
        }
        expect(
          await worker.persistEpisodeNames(
            anchor,
            collection.subject!,
            names,
            mediaIds: imported.mediaIds.toSet(),
          ),
          isFalse,
        );
        final changed = store.get('media', anchor.id)!;
        store.save('media', changed.id, {...changed.data, 'bangumiId': '88'});
        final oldTitle = changed.data['episodeTitle'];
        expect(
          await worker.persistEpisodeNames(
            anchor,
            collection.subject!,
            {'${anchor.data['episode']}': 'Wrong title'},
            mediaIds: {anchor.id},
          ),
          isFalse,
        );
        expect(store.get('media', anchor.id)!.data['episodeTitle'], oldTitle);
        final cancelled = CancelToken()..cancel();
        await expectLater(
          worker.persistEpisodeNames(
            anchor,
            collection.subject!,
            names,
            cancel: cancelled,
          ),
          throwsA(isA<Cancelled>()),
        );
      } finally {
        await worker.close();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'worker imports all episodes and portable titles without dirtying unchanged records',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'directory-worker-',
      );
      final store = AppStore('${directory.path}/library.db');
      final worker = DirectoryMetadataWorker(store.path);
      try {
        final value = _collection();
        final result = await worker.synchronize(
          'nas',
          value,
          importMissing: true,
        );
        expect(result.changed, true);
        expect(result.mediaIds, hasLength(2));
        expect(store.all('media').map((r) => r.data['episodeTitle']).toSet(), {
          'Chapter 1',
          'Chapter 2',
        });
        expect(store.local('syncProfile:remoteMedia'), hasLength(2));
        final revisions = {
          for (final record in store.all('media')) record.id: record.revision,
        };
        final again = await worker.synchronize(
          'nas',
          value,
          importMissing: true,
        );
        expect(again.changed, false);
        expect({
          for (final record in store.all('media')) record.id: record.revision,
        }, revisions);
        final cancel = CancelToken()..cancel();
        await expectLater(
          worker.synchronize(
            'nas',
            _collection(title: 'Other'),
            importMissing: true,
            cancel: cancel,
          ),
          throwsA(isA<Cancelled>()),
        );
        expect(store.all('media'), hasLength(2));
      } finally {
        await worker.close();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'manual donor from full group applies across transaction boundaries',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(count: 260);
      final first = DirectoryCollection(
        title: group.title,
        season: group.season,
        videos: [group.videos.first],
        identities: group.identities,
        subject: _subject('Manual', id: '88'),
        episodeTitles: {'1': 'Manual arrival'},
      );
      final result = synchronizeDirectoryCollection(
        store,
        'nas',
        first,
        importMissing: true,
      );
      store.setLocal('manualMetadata:${result.mediaIds.single}', true);
      final adapter = _Folders({
        'root': [
          const SourceEntry(name: 'Show', path: 'root/Show', directory: true),
        ],
        'root/Show': group.videos,
      });
      try {
        final catalog = _Catalog(store);
        await recognizeDirectoryTree(
          store,
          'nas',
          'root',
          source: {},
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'off',
          cancel: CancelToken(),
          adapter: adapter,
          catalog: catalog,
        );
        expect(catalog.queries, ['Show']);
        expect(store.all('media'), hasLength(260));
        expect(
          store.all('media').every((r) => r.data['bangumiId'] == '88'),
          true,
        );
        expect(
          store
              .all('media')
              .where((r) => r.data['episode'] == '2')
              .single
              .data['episodeTitle'],
          isNull,
          reason: 'a different subject must not donate chapter titles',
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'recursive recognition handles nested series, deduplicates folders and respects hidden entries',
    () async {
      final store = AppStore(':memory:');
      final alpha = _collection(title: 'Alpha');
      final beta = _collection(title: 'Beta');
      final adapter = _Folders({
        'root': [
          const SourceEntry(name: 'Alpha', path: 'root/Alpha', directory: true),
          const SourceEntry(
            name: 'Alpha alias',
            path: 'root/Alpha/',
            directory: true,
          ),
          const SourceEntry(
            name: 'Nested',
            path: 'root/Nested',
            directory: true,
          ),
          const SourceEntry(
            name: '.hidden',
            path: 'root/.hidden',
            directory: true,
          ),
          const SourceEntry(name: 'escape', path: '../escape', directory: true),
        ],
        'root/Alpha': alpha.videos,
        'root/Nested': [
          const SourceEntry(
            name: 'Beta',
            path: 'root/Nested/Beta',
            directory: true,
          ),
        ],
        'root/Nested/Beta': [
          for (final entry in beta.videos)
            SourceEntry(
              name: entry.name,
              path: entry.path.replaceFirst('root/Beta', 'root/Nested/Beta'),
            ),
        ],
      });
      try {
        final catalog = _Catalog(store);
        final progress = await recognizeDirectoryTree(
          store,
          'nas',
          'root',
          source: {},
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'off',
          cancel: CancelToken(),
          adapter: adapter,
          catalog: catalog,
        );
        expect(progress.videos, 4);
        expect(progress.matched, 4);
        expect(catalog.queries.toSet(), {'Alpha', 'Beta'});
        expect(adapter.listed.where((p) => p.contains('Alpha')), hasLength(1));
        expect(
          adapter.listed.any(
            (p) => p.contains('hidden') || p.contains('escape'),
          ),
          false,
        );
        expect(store.all('media').map((r) => r.data['episodeTitle']).toSet(), {
          'Arrival',
          'Departure',
        });
        expect(adapter.closes, 1);
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'cancellation stops after one committed batch and closes the source',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(count: 260);
      final adapter = _Folders({'root': group.videos});
      final cancel = CancelToken();
      try {
        await expectLater(
          recognizeDirectoryTree(
            store,
            'nas',
            'root',
            source: {},
            password: '',
            tmdbCredential: '',
            hideHidden: true,
            strategy: 'conservative',
            cancel: cancel,
            adapter: adapter,
            catalog: _Catalog(store),
            onProgress: (progress) {
              if (progress.videos >= 128) cancel.cancel();
            },
          ),
          throwsA(isA<Cancelled>()),
        );
        expect(store.all('media'), hasLength(128));
        expect(adapter.closes, greaterThanOrEqualTo(1));
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'a failed episode endpoint preserves series metadata and can be retried',
    () async {
      final store = AppStore(':memory:');
      final catalog = _Catalog(store)..failNames = true;
      final group = _collection();
      try {
        final result = await recognizeDirectoryTree(
          store,
          'nas',
          'root',
          source: {},
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'off',
          cancel: CancelToken(),
          adapter: _Folders({'root': group.videos}),
          catalog: catalog,
        );
        expect(result.matched, 2);
        expect(result.failed, 1);
        expect(
          store.all('media').every((r) => r.data['bangumiId'] == '7'),
          true,
        );
        catalog.failNames = false;
        await recognizeDirectoryTree(
          store,
          'nas',
          'root',
          source: {},
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'off',
          cancel: CancelToken(),
          adapter: _Folders({'root': group.videos}),
          catalog: catalog,
        );
        expect(store.all('media').map((r) => r.data['episodeTitle']).toSet(), {
          'Arrival',
          'Departure',
        });
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'empty SMB root rejects parent paths and WebDAV root accepts only its configured subtree',
    () async {
      for (final webdav in [false, true]) {
        final store = AppStore(':memory:');
        final base = webdav ? '/dav/' : '';
        final adapter = _Folders({
          '': [
            const SourceEntry(
              name: 'outside',
              path: '../outside',
              directory: true,
            ),
            const SourceEntry(
              name: 'absolute',
              path: '/outside',
              directory: true,
            ),
            SourceEntry(name: 'Show', path: '${base}Show', directory: true),
          ],
          '${base}Show': [
            SourceEntry(name: 'Show S01E01.mkv', path: '${base}Show/1.mkv'),
            SourceEntry(name: 'Show S01E02.mkv', path: '${base}Show/2.mkv'),
          ],
        });
        try {
          await recognizeDirectoryTree(
            store,
            'nas',
            '',
            source: webdav
                ? {'kind': 'webdav', 'url': 'https://example.test/dav/'}
                : {'kind': 'smb'},
            password: '',
            tmdbCredential: '',
            hideHidden: true,
            strategy: 'off',
            cancel: CancelToken(),
            adapter: adapter,
            catalog: _Catalog(store),
          );
          expect(adapter.listed, ['', '${base}Show']);
          expect(store.all('media'), hasLength(2));
        } finally {
          store.dispose();
        }
      }
    },
  );

  test(
    'exclusions remain excluded and TMDB movie titles cannot leak into a television donor',
    () {
      final store = AppStore(':memory:');
      try {
        final tv = _collection(subject: _subject('Show', provider: 'tmdb'));
        final first = DirectoryCollection(
          title: tv.title,
          season: tv.season,
          videos: [tv.videos.first],
          identities: tv.identities,
          subject: tv.subject,
        );
        final record = synchronizeDirectoryCollection(
          store,
          'nas',
          first,
          importMissing: true,
        ).mediaIds.single;
        store.setLocal('episodeTitle:$record', 'Local arrival');
        final current = store.get('media', record)!;
        store.save('media', record, {...current.data, 'episodeTitle': ''});
        final movie = _collection(
          subject: _subject('Show', provider: 'tmdb', type: 'movie'),
        );
        final result = synchronizeDirectoryCollection(
          store,
          'nas',
          movie,
          importMissing: true,
        );
        expect(result.collection.episodeTitles, {'1': 'Local arrival'});
        expect(
          store.all('media').every((r) => r.data['metadataType'] == 'tv'),
          true,
        );
        expect(
          store
              .all('media')
              .where((r) => r.data['episode'] == '2')
              .single
              .data['episodeTitle'],
          isNull,
        );
        final other = _collection(title: 'Other');
        final key = sha256.convert(
          utf8.encode(jsonEncode(['nas', other.videos.first.path])),
        );
        store.setLocal('automatic-import-excluded:$key', true);
        final excluded = synchronizeDirectoryCollection(
          store,
          'nas',
          other,
          importMissing: true,
        );
        expect(excluded.mediaIds, hasLength(1));
      } finally {
        store.dispose();
      }
    },
  );
}
