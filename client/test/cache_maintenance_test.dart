import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/cache_maintenance.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:flutter_test/flutter_test.dart';

class _UiStore extends AppStore {
  bool prohibitMaintenance = false;
  _UiStore(super.path);

  @override
  Map<String, dynamic> localEntries(String prefix) {
    if (prohibitMaintenance) throw StateError('UI must not scan cache rows');
    return super.localEntries(prefix);
  }

  @override
  void transaction(void Function() action) {
    if (prohibitMaintenance) throw StateError('UI must not clear cache rows');
    super.transaction(action);
  }
}

class _JsonTransport implements JsonTransport {
  final started = Completer<void>();
  final reply = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) {
    if (!started.isCompleted) started.complete();
    return reply.future;
  }
}

class _AiTransport implements SubtitleAiTransport {
  final started = Completer<void>();
  final reply = Completer<String>();
  int requests = 0;

  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) {
    requests++;
    if (!started.isCompleted) started.complete();
    return reply.future;
  }

  @override
  Future<List<String>> models(
    SubtitleAiConfig config,
    CancelToken cancel,
  ) async => [];
}

const _identity = {
  'name': 'Example',
  'titles': {'zh': '', 'en': 'Example', 'ja': ''},
  'aliases': <String>[],
  'kind': 'anime',
  'season': 1,
  'episode': 1,
  'year': 2026,
  'confidence': .99,
};

void main() {
  late Directory directory;
  late _UiStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('cache-maintenance-');
    store = _UiStore('${directory.path}/store.db');
  });
  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'disk clear preserves user data and translations without UI scans',
    () async {
      final protected = <String, dynamic>{
        'settings': {'metadataStrategy': 'conservative'},
        'sources': [
          {'id': 'dav', 'url': 'http://example.test/dav/'},
        ],
        'sourceFavorites': [
          {'sourceId': 'dav', 'path': 'series/'},
        ],
        'location:item': {'source': 'dav', 'path': 'series/1.mkv'},
        'browse:item': {'source': 'dav', 'path': 'series/1.mkv'},
        'manualMetadata:item': true,
        'episodeTitle:item': 'Saved title',
        'externalSource:other': {'kind': 'webdav'},
        'automatic-import-excluded:removed': true,
        'directorySort:dav:series': {'field': 'name'},
        'sourceBrowser:dav': {'offset': 42},
        'media-title-display:series': {'visible': true},
        'media-title-translation:title': '译名',
        'summary-translation:summary': '简介',
        'subtitle-ai:track': {
          'values': {'1': '字幕'},
        },
        'syncProfile:baseline': {'value': 'keep'},
      };
      for (final entry in protected.entries) {
        store.setLocal(entry.key, entry.value);
      }
      for (final kind in [
        'media',
        'progress',
        'watched',
        'match',
        'favorite',
      ]) {
        store.save(kind, 'item', {'title': 'Keep', 'position': 123});
      }
      final originalRecords = store.db
          .select('SELECT * FROM records')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final originalMarkers = store.localEntries('syncModified:');
      for (final prefix in [
        'catalog-v1:',
        'subject-v5:',
        'episode-names:',
        'metadataEpisodeNames:',
        'directory-preview:',
        'directory-preview-envelope:',
        'media-ai-filename:',
        'media-ai-confirmation:',
        'preview:',
        'mediaMetadata:',
        'technical:',
      ]) {
        // Invalid JSON proves deletion never decodes the old cache payload.
        store.db.execute('INSERT INTO local(key,value) VALUES(?,?)', [
          '$prefix stale',
          'invalid cached payload',
        ]);
      }
      store.cache('comments', [
        {'text': 'danmaku'},
      ]);
      for (final path in [
        'previews/frame.jpg',
        'media/video.mp4',
        'credentials/source',
        'subtitle-cache/translated.srt',
        'subtitle-fonts/font.ttf',
        'poster-cache-v1/image',
      ]) {
        final file = File('${directory.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('keep unless preview');
      }
      final revision = store.localRevision;
      store.prohibitMaintenance = true;
      await clearStoredCaches(store, directory);
      expect(store.localRevision, greaterThan(revision));
      store.prohibitMaintenance = false;
      for (final entry in protected.entries) {
        expect(store.local(entry.key), entry.value, reason: entry.key);
      }
      expect(
        store.db
            .select('SELECT * FROM records')
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
        originalRecords,
      );
      expect(store.localEntries('syncModified:'), originalMarkers);
      expect(store.localEntries('catalog-v1:'), isEmpty);
      expect(store.localEntries('directory-preview:'), isEmpty);
      expect(store.localEntries('media-ai-'), isEmpty);
      expect(store.db.select('SELECT * FROM cache'), isEmpty);
      expect(store.local('cacheClearEpoch'), 1);
      expect(store.local('directoryPreviewEpoch'), 1);
      expect(Directory('${directory.path}/previews').existsSync(), isFalse);
      for (final path in [
        'media/video.mp4',
        'credentials/source',
        'subtitle-cache/translated.srt',
        'subtitle-fonts/font.ttf',
        'poster-cache-v1/image',
      ]) {
        expect(
          File('${directory.path}/$path').existsSync(),
          isTrue,
          reason: path,
        );
      }
      await clearStoredCaches(store, directory);
      expect(store.local('cacheClearEpoch'), 2);
      expect(store.local('directoryPreviewEpoch'), 2);
    },
  );

  test('old directory worker preview cannot return after clear', () async {
    const preview = DirectoryPreview(
      collection: null,
      context: 'context',
      fingerprint: 'files',
      updatedAt: 1,
      modified: 1,
    );
    persistDirectoryPreview(store, 'dav', 'series', preview);
    expect(readDirectoryPreview(store, 'dav', 'series'), isNotNull);
    await clearStoredCaches(store, directory);
    final workerStore = AppStore.openExisting(store.path);
    try {
      persistDirectoryPreview(workerStore, 'dav', 'series', preview);
    } finally {
      workerStore.dispose();
    }
    expect(readDirectoryPreview(store, 'dav', 'series'), isNull);
  });

  test(
    'preview directory link does not remove its user-owned target',
    () async {
      final owned = Directory('${directory.path}/media')..createSync();
      final file = File('${owned.path}/video.mp4')..writeAsStringSync('video');
      Link('${directory.path}/previews').createSync(owned.path);
      await clearStoredCaches(store, directory);
      expect(file.readAsStringSync(), 'video');
      expect(Link('${directory.path}/previews').existsSync(), isFalse);
    },
  );

  test(
    'memory invalidation does not scan and rejects a late provider reply',
    () async {
      final transport = _JsonTransport();
      final catalog = LibraryCatalog(store, transport: transport);
      store.setLocal('catalog-v1:saved', {'keep': true});
      final pending = catalog.details({'id': 7});
      final rejected = expectLater(pending, throwsA(isA<Cancelled>()));
      await transport.started.future;
      store.prohibitMaintenance = true;
      catalog.invalidateMemoryCaches();
      expect(store.local('catalog-v1:saved'), {'keep': true});
      expect(store.local('directoryPreviewEpoch'), isNull);
      transport.reply.complete({'id': 7, 'name': 'Example'});
      await rejected;
      expect(store.local('catalog-v1:bangumi:details:7'), isNull);
    },
  );

  test(
    'catalogue maintenance blocks new fetches until explicitly resumed',
    () async {
      final transport = _JsonTransport();
      final catalog = LibraryCatalog(store, transport: transport)
        ..cacheMaintenance = true;
      for (final request in [
        catalog.resolve('Example', '1'),
        catalog.episodeNames('7'),
        catalog.inspect('dav', 'series', []),
        catalog.loadDirectoryPreview('dav', 'series'),
        catalog.search('Example'),
        catalog.details({'id': 7}),
      ]) {
        await expectLater(request, throwsA(isA<Cancelled>()));
      }
      expect(transport.started.isCompleted, isFalse);
      catalog.cacheMaintenance = false;
      transport.reply.complete({'id': 7, 'name': 'Example'});
      expect((await catalog.details({'id': 7}))['id'], 7);
    },
  );

  for (final operation in ['tmdb details', 'combined search']) {
    test('invalidation rejects $operation waiting for credentials', () async {
      final transport = _JsonTransport();
      final credentials = Completer<String>();
      final started = Completer<void>();
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        tmdbCredential: () {
          if (!started.isCompleted) started.complete();
          return credentials.future;
        },
      );
      final Future<Object?> work = operation == 'tmdb details'
          ? catalog.details({'provider': 'tmdb', 'mediaType': 'movie', 'id': 7})
          : catalog.search('Example');
      final rejected = expectLater(work, throwsA(isA<Cancelled>()));
      await started.future;
      catalog.invalidateMemoryCaches();
      credentials.complete('read-token');
      await rejected;
      expect(transport.started.isCompleted, isFalse);
      expect(store.localEntries('catalog-v1:'), isEmpty);
    });
  }

  for (final operation in ['single', 'batch', 'confirmation']) {
    test(
      'AI invalidation rejects late $operation result without caching',
      () async {
        final transport = _AiTransport();
        final ai = MediaAiRecognition(store, transport: transport);
        final config = SubtitleAiConfig(model: 'test');
        final cancel = CancelToken();
        final Future<Object?> work = switch (operation) {
          'single' => ai.analyzeFilename(
            'Example S01E01.mkv',
            config: config,
            cancel: cancel,
          ),
          'batch' => ai.analyzeFilenames(
            ['Example S01E01.mkv'],
            config: config,
            cancel: cancel,
          ),
          _ => ai.confirm(
            const AiMediaIdentity(
              name: 'Example',
              kind: 'anime',
              confidence: .99,
            ),
            [
              {
                'provider': 'bangumi',
                'mediaType': 'tv',
                'id': '7',
                'name': 'Example',
              },
            ],
            config: config,
            cancel: cancel,
          ),
        };
        final rejected = expectLater(work, throwsA(isA<Cancelled>()));
        await transport.started.future;
        ai.invalidate();
        transport.reply.complete(
          jsonEncode(switch (operation) {
            'single' => _identity,
            'batch' => {
              'items': [
                {'id': '0', 'identity': _identity},
              ],
            },
            _ => {
              'status': 'match',
              'selection': {
                'provider': 'bangumi',
                'mediaType': 'tv',
                'id': '7',
              },
              'confidence': .99,
            },
          }),
        );
        await rejected;
        expect(store.localEntries('media-ai-'), isEmpty);
      },
    );
  }
}
