import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer_smb/aiplayer_smb.dart';
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

class _PreviewReadStore extends AppStore {
  int fullPreviewReads = 0;
  _PreviewReadStore(super.path);
  @override
  dynamic local(String key) {
    if (key.startsWith('directory-preview:')) fullPreviewReads++;
    return super.local(key);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    if (prefix == 'directory-preview:') fullPreviewReads++;
    return super.localEntries(prefix);
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

class _SmbDirectoryFixture implements SmbConnection {
  final listed = <String>[];
  bool closed = false;
  @override
  int get dialect => 0x0311;
  @override
  Future<List<Map<String, dynamic>>> shares() async => [
    {'name': 'video', 'hidden': false},
  ];
  @override
  Future<List<Map<String, dynamic>>> list(String path) async {
    listed.add(path);
    final directory = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/$'), '');
    final names = directory.isEmpty
        ? ['Show/']
        : directory == 'Show'
        ? ['Show S01E01.mkv', 'Show S01E02.mkv', 'readme.txt']
        : <String>[];
    return [
      for (final name in names)
        {
          'name': name.replaceFirst(RegExp(r'/$'), ''),
          'directory': name.endsWith('/'),
          'size': 42,
          'modified': 0,
          'hidden': false,
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> stat(String path) async =>
      throw UnimplementedError();
  @override
  Future<Uint8List> read(String path, int offset, int length) async =>
      throw UnimplementedError();
  @override
  Future<void> close() async => closed = true;
}

String _webDavListing(String directory, List<String> children) {
  final result = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  for (final path in [
    directory,
    ...children.map((name) => '$directory$name'),
  ]) {
    result.write(
      '<d:response><d:href>${Uri(path: path)}</d:href>'
      '<d:propstat><d:prop><d:resourcetype>'
      '${path.endsWith('/') ? '<d:collection/>' : ''}'
      '</d:resourcetype><d:getcontentlength>42</d:getcontentlength>'
      '</d:prop></d:propstat></d:response>',
    );
  }
  return '$result</d:multistatus>';
}

class _Catalog extends LibraryCatalog {
  final queries = <String>[];
  final unmatched = <String>{};
  void Function()? onResolve;
  bool failNames = false;
  _Catalog(
    super.store, {
    super.prepareDirectory,
    super.persistDirectory,
    super.readDirectory,
  });
  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    queries.add(title);
    cancel?.check();
    onResolve?.call();
    if (unmatched.contains(title)) return null;
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

class _FolderAi extends MediaAiRecognition {
  final Map<String, AiMediaIdentity> identities;
  final calls = <List<String>>[];
  Future<void> Function()? beforeResponse;
  _FolderAi(super.store, this.identities);

  @override
  Future<Map<String, AiMediaIdentity>> analyzeFolderFilenames(
    List<String> fileNames, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    calls.add(List.of(fileNames));
    await beforeResponse?.call();
    cancel.check();
    return {for (final name in fileNames) name: ?identities[name]};
  }

  @override
  Future<Map<String, dynamic>?> confirm(
    AiMediaIdentity identity,
    List<Map<String, dynamic>> candidates, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    cancel.check();
    return candidates.firstOrNull;
  }
}

class _AiCatalog extends _Catalog {
  final searches = <String>[];
  _AiCatalog(super.store);

  @override
  Future<List<Map<String, dynamic>>> search(
    String name, {
    String? source,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    searches.add(name);
    return [
      _subject(name, id: name == 'Second work' ? '8' : '7', provider: 'tmdb'),
    ];
  }

  @override
  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    cancel?.check();
    return subject;
  }
}

void main() {
  test(
    'folder analysis uses the reusable worker and shares its complete cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'folder-ai-worker-',
      );
      final store = AppStore('${directory.path}/library.db');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <List<String>>[];
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = body['messages'] as List;
        final content =
            jsonDecode((messages.last as Map)['content'] as String) as Map;
        final items = (content['items'] as List).cast<Map>();
        requests.add([for (final item in items) item['fileName'] as String]);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'items': [
                      for (final item in items)
                        {
                          'id': item['id'],
                          'identity': {
                            'name': 'Worker Show',
                            'titles': {'zh': '', 'en': '', 'ja': ''},
                            'aliases': [],
                            'kind': 'tv',
                            'season': 1,
                            'episode': item['fileName'] == 'part-a.mkv' ? 1 : 2,
                            'year': null,
                            'confidence': .99,
                          },
                        },
                    ],
                  }),
                },
              },
            ],
          }),
        );
        await request.response.close();
      });
      final worker = DirectoryMetadataWorker(store.path);
      final config = SubtitleAiConfig(
        origin: 'http://127.0.0.1:${server.port}/v1',
        model: 'worker-test',
        token: 'worker-only-test-token',
      );
      try {
        final first = await worker.analyzeFolderFilenames(
          ['part-b.mkv', 'part-a.mkv'],
          config,
          cancel: CancelToken(),
        );
        final second = await worker.analyzeFolderFilenames(
          ['part-a.mkv', 'part-b.mkv'],
          config,
          cancel: CancelToken(),
        );
        expect(requests, [
          ['part-a.mkv', 'part-b.mkv'],
        ]);
        expect(first['part-a.mkv']?.episode, '1');
        expect(second['part-b.mkv']?.episode, '2');
        final cached = store.localEntries('media-ai-folder-v1:');
        expect(cached, hasLength(1));
        expect(jsonEncode(cached), isNot(contains(config.token)));
      } finally {
        await worker.close();
        await server.close(force: true);
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cold directory previews retain all offline episodes without UI payload reads',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'cold-directory-preview-',
      );
      final store = _PreviewReadStore('${directory.path}/library.db');
      final worker = DirectoryMetadataWorker(store.path);
      _Catalog catalog() => _Catalog(
        store,
        prepareDirectory: (source, path, context, entries, cancel) => worker
            .prepareInspection(source, path, context, entries, cancel: cancel),
        persistDirectory: (source, path, preview, cancel) =>
            worker.persistPreview(source, path, preview, cancel: cancel),
        readDirectory: (source, path, cancel) =>
            worker.readPreview(source, path, cancel: cancel),
      );
      try {
        await catalog().inspect(
          'nas',
          'root/Show',
          _collection(count: 1500).videos,
        );
        final restored = catalog();
        final artwork = restored.directoryPreview('nas', 'root/Show');
        expect(artwork?.complete, isFalse);
        expect(artwork?.collection?.videos, isEmpty);
        expect(artwork?.collection?.episodeCount, 1500);
        final complete = await restored.loadDirectoryPreview(
          'nas',
          'root/Show',
        );
        expect(complete?.complete, isTrue);
        expect(complete?.collection?.videos, hasLength(1500));
        expect(complete?.collection?.episodeCount, 1500);
        expect(complete?.collection?.episodeTitles['2'], 'Departure');
        expect(store.fullPreviewReads, 0);

        await worker.persistPreview(
          'nas',
          'root/Show',
          DirectoryPreview(
            collection: _collection(count: 1400),
            context: complete!.context,
            fingerprint: 'new-listing',
            updatedAt: complete.updatedAt + 1,
            modified: complete.modified,
          ),
        );
        final changed = restored.directoryPreview('nas', 'root/Show');
        expect(changed?.complete, isFalse);
        expect(changed?.collection?.episodeCount, 1400);
        expect(
          (await restored.loadDirectoryPreview(
            'nas',
            'root/Show',
          ))?.collection?.videos,
          hasLength(1400),
        );
        expect(store.fullPreviewReads, 0);

        final started = Completer<void>();
        final delayed = Completer<DirectoryPreview?>();
        final cancelled = _Catalog(
          store,
          readDirectory: (_, _, _) {
            started.complete();
            return delayed.future;
          },
        );
        final token = CancelToken();
        final loading = cancelled.loadDirectoryPreview(
          'nas',
          'root/Show',
          cancel: token,
        );
        await started.future;
        token.cancel();
        delayed.complete(complete);
        await expectLater(loading, throwsA(isA<Cancelled>()));
        expect(
          cancelled.directoryPreview('nas', 'root/Show')?.complete,
          isFalse,
        );

        final secondStarted = Completer<void>();
        final secondDelayed = Completer<DirectoryPreview?>();
        final invalidated = _Catalog(
          store,
          readDirectory: (_, _, _) {
            secondStarted.complete();
            return secondDelayed.future;
          },
        );
        final obsolete = invalidated.loadDirectoryPreview('nas', 'root/Show');
        await secondStarted.future;
        invalidated.invalidateDirectoryPreviews('nas');
        secondDelayed.complete(complete);
        expect(await obsolete, isNull);
        expect(invalidated.directoryPreview('nas', 'root/Show'), isNull);
        expect(store.fullPreviewReads, 0);

        // Old installations have only the full payload, without an artwork
        // envelope. They still recover offline and respect a later refresh.
        await worker.persistPreview(
          'nas',
          'root/Show',
          DirectoryPreview(
            collection: complete.collection,
            context: complete.context,
            fingerprint: complete.fingerprint,
            updatedAt: complete.updatedAt,
            modified: complete.modified,
            sourceEpoch: 1,
          ),
        );
        store.db.execute(
          "DELETE FROM local WHERE key LIKE 'directory-preview-envelope:%'",
        );
        final legacy = catalog();
        expect(legacy.directoryPreview('nas', 'root/Show'), isNull);
        expect(
          (await legacy.loadDirectoryPreview(
            'nas',
            'root/Show',
          ))?.collection?.videos,
          hasLength(1500),
        );
        legacy.invalidateDirectoryPreviews('nas');
        expect(await legacy.loadDirectoryPreview('nas', 'root/Show'), isNull);
        expect(store.fullPreviewReads, 0);
      } finally {
        await worker.close();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'a standalone anchor cannot adopt an unrelated neighboring series',
    () async {
      final store = AppStore(':memory:');
      try {
        store.save('media', 'holiday', {
          'title': 'Holiday.mkv',
          'fileName': 'Holiday.mkv',
          'series': 'Holiday',
          'episode': '',
        });
        store.setLocal('location:holiday', {
          'id': 'holiday',
          'source': 'nas',
          'path': 'root/Show/Holiday.mkv',
        });
        final result = await synchronizeDirectoryListing(
          store,
          'nas',
          'root/Show',
          [
            ..._collection().videos,
            const SourceEntry(
              name: 'Holiday.mkv',
              path: 'root/Show/Holiday.mkv',
            ),
          ],
          hideHidden: true,
          anchorId: 'holiday',
        );
        expect(result, isNull);
        expect(store.all('media'), hasLength(1));
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'unplayed listings complete the unique series and reject ambiguous folders',
    () async {
      final store = _BatchStore();
      try {
        final group = _collection(count: 1100);
        final ambiguous =
            await synchronizeDirectoryListing(store, 'nas', 'root/Show', [
              ...group.videos,
              const SourceEntry(
                name: 'Other S01E01.mkv',
                path: 'root/Show/other.mkv',
              ),
            ], hideHidden: true);
        expect(ambiguous, isNull);
        expect(store.count, 0);
        final completed =
            await synchronizeDirectoryListing(store, 'nas', 'root/Show', [
              ...group.videos,
              const SourceEntry(
                name: 'trailer.mkv',
                path: 'root/Show/trailer.mkv',
              ),
            ], hideHidden: true);
        expect(completed?.mediaIds, hasLength(1100));
        expect(completed?.collection.videos, hasLength(1100));
        expect(store.count, 1100);
        expect(store.insertedPerCommit, hasLength(9));
        expect(store.insertedPerCommit.every((count) => count <= 128), isTrue);
        expect(store.records('progress'), isEmpty);
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'large directory inspection reuses the worker off the UI isolate',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'directory-inspection-',
      );
      final store = AppStore('${directory.path}/library.db');
      final worker = DirectoryMetadataWorker(store.path);
      try {
        final entries = _collection(count: 1500).videos;
        var responsive = false;
        final work = worker.prepareInspection(
          'nas',
          'root/Show',
          'context',
          entries,
        );
        Timer.run(() => responsive = true);
        final first = await work;
        expect(responsive, isTrue);
        expect(first.collection?.videos, hasLength(1500));
        expect(first.preparationIsolate, isNot(Isolate.current.hashCode));
        final second = await worker.prepareInspection(
          'nas',
          'root/Show',
          'context',
          entries,
        );
        expect(second.preparationIsolate, first.preparationIsolate);
        expect(second.fingerprint, first.fingerprint);
        final changed = await worker.prepareInspection(
          'nas',
          'root/Show',
          'changed',
          entries,
        );
        expect(changed.fingerprint, isNot(first.fingerprint));
        final preview = DirectoryPreview(
          collection: first.collection,
          context: 'context',
          fingerprint: first.fingerprint,
          updatedAt: 1,
          modified: 0,
        );
        await worker.persistPreview('nas', 'root/Show', preview);
        expect(
          (store.localEntries('directory-preview:').values.single
              as Map)['collection']['videos'],
          hasLength(1500),
        );
        await worker.persistPreview('other', 'root/Show', preview);
        final catalog = LibraryCatalog(store);
        catalog.invalidateDirectoryPreviews('nas');
        await worker.persistPreview('nas', 'root/Show', preview);
        expect(
          store.localEntries('directory-preview:').values.single['sourceId'],
          'other',
          reason:
              'source refresh rejects its stale write and keeps other sources',
        );
        catalog.invalidateMetadataCaches();
        await worker.persistPreview('nas', 'root/Show', preview);
        expect(
          store.localEntries('directory-preview:'),
          isEmpty,
          reason:
              'an obsolete queued preview must not refill an invalidated cache',
        );
        final cancel = CancelToken()..cancel();
        await expectLater(
          worker.prepareInspection(
            'nas',
            'root/Show',
            'context',
            entries,
            cancel: cancel,
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
    'folder AI receives every visible filename once before deduplicated work lookups',
    () async {
      final store = AppStore(':memory:');
      final files = [
        for (var i = 1; i <= 25; i++)
          SourceEntry(
            name: 'mixed-release-$i.mkv',
            path: 'root/mixed-release-$i.mkv',
          ),
      ];
      final identities = {
        for (var i = 1; i <= 25; i++)
          'mixed-release-$i.mkv': AiMediaIdentity(
            fileName: 'mixed-release-$i.mkv',
            name: i <= 20 ? 'First work' : 'Second work',
            kind: 'tv',
            season: '1',
            episode: '${i <= 20 ? i : i - 20}',
            confidence: .99,
          ),
        'child.mkv': const AiMediaIdentity(
          fileName: 'child.mkv',
          name: 'Child work',
          kind: 'movie',
          confidence: .99,
        ),
      };
      final ai = _FolderAi(store, identities);
      final catalog = _AiCatalog(store);
      final progress = <DirectoryRecognitionProgress>[];
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
          aiConfig: SubtitleAiConfig(model: 'folder-test'),
          ai: ai,
          catalog: catalog,
          adapter: _Folders({
            'root': [
              ...files,
              const SourceEntry(name: '.hidden.mkv', path: 'root/.hidden.mkv'),
              const SourceEntry(name: 'readme.txt', path: 'root/readme.txt'),
              const SourceEntry(
                name: 'Nested',
                path: 'root/Nested',
                directory: true,
              ),
            ],
            'root/Nested': [
              const SourceEntry(
                name: 'child.mkv',
                path: 'root/Nested/child.mkv',
              ),
            ],
          }),
          onProgress: progress.add,
        );
        expect(ai.calls, [
          files.map((entry) => entry.name).toList(),
          ['child.mkv'],
        ]);
        expect(
          catalog.queries,
          isEmpty,
          reason: 'AI identities must not be replaced by regex lookup',
        );
        expect(catalog.searches, ['First work', 'Second work', 'Child work']);
        expect(result.videos, 26);
        expect(result.matched, 26);
        final records = store.all('media');
        expect(records, hasLength(26));
        for (final record in records) {
          final parsed = identities[record.data['fileName']]!;
          expect(record.data['series'], parsed.name);
          expect(record.data['episode'], parsed.episode);
        }
        final delivered = progress
            .expand((value) => value.aiResults.values)
            .toList();
        expect(delivered, hasLength(26));
        expect(
          delivered.map((match) => match.identity.fileName).toSet(),
          identities.keys.toSet(),
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'folder AI cancellation prevents writes and late analyses preserve edits',
    () async {
      for (final cancelDuringAnalysis in [false, true]) {
        final store = AppStore(':memory:');
        final group = _collection(count: 2);
        final cancel = CancelToken();
        final ids = synchronizeDirectoryCollection(
          store,
          'nas',
          group,
          importMissing: true,
        ).mediaIds;
        final ai =
            _FolderAi(store, {
                for (final entry in group.videos)
                  entry.name: AiMediaIdentity(
                    fileName: entry.name,
                    name: 'Second work',
                    kind: 'tv',
                    season: '1',
                    episode: '9',
                    confidence: .99,
                  ),
              })
              ..beforeResponse = () async {
                if (cancelDuringAnalysis) {
                  cancel.cancel();
                } else {
                  store.save('media', ids.first, {
                    ...store.get('media', ids.first)!.data,
                    'metadataTitle': 'Newer edit',
                  });
                }
              };
        try {
          final work = recognizeDirectoryTree(
            store,
            'nas',
            'root',
            source: {},
            password: '',
            tmdbCredential: '',
            hideHidden: true,
            strategy: 'off',
            cancel: cancel,
            aiConfig: SubtitleAiConfig(model: 'folder-test'),
            ai: ai,
            catalog: _AiCatalog(store),
            adapter: _Folders({'root': group.videos}),
          );
          if (cancelDuringAnalysis) {
            await expectLater(work, throwsA(isA<Cancelled>()));
            expect(
              store
                  .all('media')
                  .every((record) => record.data['bangumiId'] == '7'),
              isTrue,
            );
          } else {
            await work;
            expect(
              store.get('media', ids.first)!.data['metadataTitle'],
              'Newer edit',
            );
            expect(store.get('media', ids.last)!.data['tmdbId'], '8');
            expect(store.get('media', ids.last)!.data['episode'], '9');
          }
          expect(ai.calls, hasLength(1));
        } finally {
          store.dispose();
        }
      }
    },
  );

  test(
    'uncertain or missing folder AI identities stay available for manual matching',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(count: 3);
      final ai = _FolderAi(store, {
        for (var i = 0; i < 2; i++)
          group.videos[i].name: AiMediaIdentity(
            fileName: group.videos[i].name,
            name: 'First work',
            kind: 'tv',
            season: '1',
            episode: '${i + 1}',
            confidence: i == 0 ? .99 : .4,
          ),
      });
      final catalog = _AiCatalog(store);
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
          aiConfig: SubtitleAiConfig(model: 'folder-test'),
          ai: ai,
          catalog: catalog,
          adapter: _Folders({'root': group.videos}),
        );
        expect(result.videos, 3);
        expect(result.matched, 1);
        expect(store.all('media'), hasLength(3));
        expect(catalog.searches, ['First work']);
        expect(catalog.queries, isEmpty);
        expect(
          store.all('media').where((record) => record.data['tmdbId'] == null),
          hasLength(2),
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'folder AI failure imports review records without falling back to automatic catalogue matching',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(count: 3);
      final catalog = _AiCatalog(store);
      final ai = _FolderAi(store, {})
        ..beforeResponse = () async => throw const AppFailure('AI unavailable');
      try {
        final result = await recognizeDirectoryTree(
          store,
          'nas',
          'root',
          source: {},
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'conservative',
          cancel: CancelToken(),
          aiConfig: SubtitleAiConfig(model: 'folder-test'),
          ai: ai,
          catalog: catalog,
          adapter: _Folders({'root': group.videos}),
        );
        expect(result.videos, 3);
        expect(result.matched, 0);
        expect(result.failed, 1);
        expect(result.error, 'AI unavailable');
        expect(store.all('media'), hasLength(3));
        expect(catalog.searches, isEmpty);
        expect(catalog.queries, isEmpty);
        expect(
          store
              .all('media')
              .every(
                (record) =>
                    record.data['tmdbId'] == null &&
                    record.data['bangumiId'] == null,
              ),
          isTrue,
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
    'explicit recognition replaces old automatic metadata and stale episode titles',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(subject: _subject('Wrong show', id: '88'));
      try {
        final imported = synchronizeDirectoryCollection(
          store,
          'nas',
          group,
          importMissing: true,
        );
        expect(
          store.get('media', imported.mediaIds.first)!.data['bangumiId'],
          '88',
        );
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
          adapter: _Folders({'root': group.videos}),
          catalog: _Catalog(store)..failNames = true,
        );
        expect(progress.matched, 2);
        for (final id in imported.mediaIds) {
          final record = store.get('media', id)!;
          expect(record.data['bangumiId'], '7');
          expect(record.data['metadataTitle'], 'Show');
          expect(record.data['episodeTitle'], isNull);
          expect(store.local('episodeTitle:$id'), isNull);
        }
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'explicit recognition preserves revisions changed or deleted during lookup',
    () async {
      final store = AppStore(':memory:');
      final group = _collection(count: 3, subject: _subject('Old', id: '88'));
      try {
        final ids = synchronizeDirectoryCollection(
          store,
          'nas',
          group,
          importMissing: true,
        ).mediaIds;
        final catalog = _Catalog(store)
          ..onResolve = () {
            store.save('media', ids[1], {
              ...store.get('media', ids[1])!.data,
              'bangumiId': '99',
              'metadataTitle': 'A newer edit',
            });
            store.save(
              'media',
              ids[2],
              store.get('media', ids[2])!.data,
              deleted: true,
            );
          };
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
        expect(store.get('media', ids[0])!.data['bangumiId'], '7');
        expect(store.get('media', ids[1])!.data['bangumiId'], '99');
        expect(
          store.get('media', ids[1])!.data['metadataTitle'],
          'A newer edit',
        );
        expect(store.get('media', ids[2])!.deleted, isTrue);
        expect(store.all('media'), hasLength(2));
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'recursive recognition delivers bounded matched and unmatched record snapshots',
    () async {
      final store = AppStore(':memory:');
      final catalog = _Catalog(store)..unmatched.add('Unknown');
      final batches = <DirectoryRecognitionProgress>[];
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
          adapter: _Folders({
            'root': [
              ..._collection(title: 'Known', count: 130).videos,
              ..._collection(title: 'Unknown', count: 3).videos,
            ],
          }),
          catalog: catalog,
          onProgress: (progress) {
            if (progress.records.isNotEmpty) batches.add(progress);
          },
        );
        final records = batches.expand((batch) => batch.records).toList();
        final matchedIds = batches.expand((batch) => batch.matchedIds).toSet();
        expect(result.videos, 133);
        expect(result.matched, 130);
        expect(result.records, isEmpty);
        expect(batches.every((batch) => batch.records.length <= 128), isTrue);
        expect(records.map((record) => record.id).toSet(), hasLength(133));
        expect(matchedIds, hasLength(130));
        expect(
          records
              .where((record) => !matchedIds.contains(record.id))
              .map((record) => record.data['series']),
          everyElement('Unknown'),
        );
        for (final record in records) {
          expect(record.revision, store.get('media', record.id)!.revision);
        }
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
            const SourceEntry(name: 'Show', path: 'Show', directory: true),
          ],
          'Show': [
            const SourceEntry(name: 'Show S01E01.mkv', path: 'Show/1.mkv'),
            const SourceEntry(name: 'Show S01E02.mkv', path: 'Show/2.mkv'),
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
          expect(adapter.listed, ['', 'Show']);
          expect(store.all('media'), hasLength(2));
        } finally {
          store.dispose();
        }
      }
    },
  );

  for (final (label, basePath, root, folders, title, season) in [
    (
      'configured source root with nested folders',
      '/dav/',
      '',
      <String, List<String>>{
        '/dav/': ['Show/'],
        '/dav/Show/': ['Show S01E01.mkv', 'Show S01E02.mkv'],
      },
      'Show',
      '1',
    ),
    (
      'numeric episodes at the configured season root',
      '/我的剧集/S02/',
      '',
      <String, List<String>>{
        '/我的剧集/S02/': ['01.mkv', '02.mkv'],
      },
      '我的剧集',
      '2',
    ),
    (
      'numeric episodes inside a season folder',
      '/Show/',
      '',
      <String, List<String>>{
        '/Show/': ['S02/'],
        '/Show/S02/': ['01.mkv', '02.mkv'],
      },
      'Show',
      '2',
    ),
    (
      'selected source-relative folder',
      '/dav/',
      'Show/',
      <String, List<String>>{
        '/dav/Show/': ['Show S01E01.mkv', 'Show S01E02.mkv'],
      },
      'Show',
      '1',
    ),
  ]) {
    test('real WebDAV recursive recognition: $label', () async {
      final store = AppStore(':memory:');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        final path = Uri.decodeComponent(request.uri.path);
        requests.add(path);
        final children = folders[path];
        request.response.statusCode = children == null ? 404 : 207;
        if (children != null) {
          request.response.write(_webDavListing(path, children));
        }
        await request.response.close();
      });
      final source = <String, dynamic>{
        'kind': 'webdav',
        'url': Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          path: basePath,
        ).toString(),
      };
      try {
        final catalog = _Catalog(store);
        final result = await recognizeDirectoryTree(
          store,
          'nas',
          root,
          source: source,
          password: '',
          tmdbCredential: '',
          hideHidden: true,
          strategy: 'off',
          cancel: CancelToken(),
          catalog: catalog,
        );
        expect(result.videos, 2);
        expect(result.matched, 2);
        expect(result.failed, 0);
        expect(result.folders, folders.length);
        expect(requests.toSet(), folders.keys.toSet());
        expect(catalog.queries, [title]);
        final records = store.all('media');
        expect(records, hasLength(2));
        expect(records.map((record) => record.data['series']).toSet(), {title});
        expect(records.map((record) => record.data['season']).toSet(), {
          season,
        });
        expect(records.map((record) => record.data['episode']).toSet(), {
          '1',
          '2',
        });
        expect(records.map((record) => record.data['episodeTitle']).toSet(), {
          'Arrival',
          'Departure',
        });
        expect(
          records.every(
            (record) =>
                !(store.local('location:${record.id}')['path'] as String)
                    .startsWith('/'),
          ),
          isTrue,
          reason:
              'HTTP URL paths must never replace source-relative locations.',
        );
      } finally {
        await server.close(force: true);
        store.dispose();
      }
    });
  }

  test('excluded videos still count as discovered videos', () async {
    final store = AppStore(':memory:');
    final group = _collection();
    try {
      for (final entry in group.videos) {
        final key = sha256.convert(
          utf8.encode(jsonEncode(['nas', entry.path])),
        );
        store.setLocal('automatic-import-excluded:$key', true);
      }
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
        catalog: _Catalog(store),
      );
      expect(result.videos, 2);
      expect(result.matched, 0);
      expect(store.all('media'), isEmpty);
    } finally {
      store.dispose();
    }
  });

  for (final serverRoot in [false, true]) {
    for (final selectedFolder in [false, true]) {
      test(
        'SMB ${serverRoot ? 'server' : 'share'} adapter recognizes ${selectedFolder ? 'selected folder' : 'root'} paths',
        () async {
          final store = AppStore(':memory:');
          final connections = <_SmbDirectoryFixture>[];
          _SmbDirectoryFixture connect() {
            final connection = _SmbDirectoryFixture();
            connections.add(connection);
            return connection;
          }

          final SourceAdapter adapter = serverRoot
              ? SmbServerSource((_) async => connect())
              : SmbSource(connect());
          final root = selectedFolder
              ? '${serverRoot ? 'video/' : ''}Show/'
              : '';
          try {
            final result = await recognizeDirectoryTree(
              store,
              'nas',
              root,
              source: {'kind': 'smb'},
              password: '',
              tmdbCredential: '',
              hideHidden: true,
              strategy: 'off',
              cancel: CancelToken(),
              adapter: adapter,
              catalog: _Catalog(store),
            );
            expect(result.videos, 2);
            expect(result.matched, 2);
            expect(result.failed, 0);
            expect(
              result.folders,
              selectedFolder
                  ? 1
                  : serverRoot
                  ? 3
                  : 2,
            );
            expect(store.all('media'), hasLength(2));
            expect(
              connections.every((connection) => connection.closed),
              isTrue,
            );
          } finally {
            store.dispose();
          }
        },
      );
    }
  }

  for (final selectedFolder in [false, true]) {
    test(
      'local adapter recognizes ${selectedFolder ? 'selected folder' : 'absolute root'} without playing',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'recognition-local-',
        );
        final show = await Directory('${directory.path}/Show').create();
        final hidden = await Directory('${directory.path}/.hidden').create();
        await File('${show.path}/Show S01E01.mkv').writeAsBytes(const []);
        await File('${show.path}/Show S01E02.mkv').writeAsBytes(const []);
        await File('${show.path}/readme.txt').writeAsString('notes');
        await File('${hidden.path}/Hidden S01E01.mkv').writeAsBytes(const []);
        final store = AppStore(':memory:');
        try {
          final result = await recognizeDirectoryTree(
            store,
            'local',
            selectedFolder ? show.path : directory.path,
            source: {'kind': 'local'},
            password: '',
            tmdbCredential: '',
            hideHidden: true,
            strategy: 'off',
            cancel: CancelToken(),
            catalog: _Catalog(store),
          );
          expect(result.videos, 2);
          expect(result.matched, 2);
          expect(result.failed, 0);
          expect(result.folders, selectedFolder ? 1 : 2);
          expect(store.all('media'), hasLength(2));
          expect(store.records('progress'), isEmpty);
          expect(
            store
                .all('media')
                .every((record) => record.data['localOnly'] == true),
            isTrue,
          );
        } finally {
          store.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

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
