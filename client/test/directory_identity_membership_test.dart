import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

const _subject = {
  'id': 42,
  'provider': 'bangumi',
  'type': 2,
  'name': 'Example',
  'platform': 'TV',
};

List<SourceEntry> _entries({bool opaque = true}) => [
  for (var episode = 1; episode <= 4; episode++)
    SourceEntry(
      name: episode == 4 && opaque ? 'opaque.mkv' : 'Example S01E0$episode.mkv',
      path: episode == 4 && opaque
          ? 'Example/opaque.mkv'
          : 'Example/Example S01E0$episode.mkv',
    ),
];

void _save(AppStore store, SourceEntry entry, String id, String episode) {
  store.save('media', id, {
    'fileName': entry.name,
    'title': entry.name,
    'series': 'Example',
    'season': '1',
    'episode': episode,
    ...subjectMediaFields(_subject),
  });
  store.setLocal('location:$id', {
    'id': id,
    'source': 'nas',
    'path': entry.path,
  });
}

class _Transport implements JsonTransport {
  int requests = 0;
  bool missingSearch = false;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    requests++;
    if (uri.path.startsWith('/search/subject/')) {
      return {
        'list': [if (!missingSearch) _subject],
      };
    }
    if (uri.path == '/v0/episodes') {
      return {
        'data': [
          for (var episode = 1; episode <= 4; episode++)
            {'sort': episode, 'name_cn': 'Episode $episode'},
        ],
      };
    }
    return _subject;
  }
}

class _CountingStore extends AppStore {
  _CountingStore() : super(':memory:');
  int reads = 0;

  @override
  dynamic local(String key) {
    reads++;
    return super.local(key);
  }

  @override
  SyncRecord? get(String kind, String id) {
    reads++;
    return super.get(kind, id);
  }

  @override
  Map<String, dynamic>? locationFor(String sourceId, String path) {
    reads++;
    return super.locationFor(sourceId, path);
  }
}

void main() {
  late Directory root;
  late AppStore store;
  late DirectoryMetadataWorker worker;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('directory-identity-');
    store = AppStore('${root.path}/library.db');
    worker = DirectoryMetadataWorker(store.path);
  });
  tearDown(() async {
    await worker.close();
    store.dispose();
    await root.delete(recursive: true);
  });

  test(
    'prepared folder snapshots merge identities without any UI store reads',
    () {
      final entries = _entries();
      final snapshot = {
        for (var index = 0; index < entries.length; index++)
          entries[index].path: SyncRecord(
            kind: 'media',
            id: '$index',
            data: {
              'series': 'Example',
              'season': '1',
              'episode': '${index + 1}',
              ...subjectMediaFields(_subject),
            },
          ),
      };
      final counted = _CountingStore();
      try {
        counted.reads = 0;
        final collection = identifyStoredDirectory(
          counted,
          'nas',
          'Example',
          entries,
          recordsByPath: snapshot,
        );
        expect(collection!.episodeCount, 4);
        expect(collection.membershipComplete, isTrue);
        expect(counted.reads, 0);
      } finally {
        counted.dispose();
      }
    },
  );

  test(
    'disk worker includes a verified opaque sibling in partial parsing',
    () async {
      final entries = _entries();
      for (var index = 0; index < entries.length; index++) {
        _save(store, entries[index], '$index', '${index + 1}');
      }
      expect(identifyDirectory('Example', entries)!.episodeCount, 3);
      final prepared = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(prepared.collection!.episodeCount, 4);
      expect(prepared.collection!.videos, hasLength(4));
      expect(prepared.collection!.membershipComplete, isTrue);
      final synced = await worker.synchronizeListing(
        'nas',
        'Example',
        entries,
        hideHidden: true,
      );
      expect(synced!.collection.episodeCount, 4);
      expect(synced.collection.identities[entries.last.path]!.episode, '4');
      expect(synced.changed, isFalse);
    },
  );

  test(
    'manual identity correction changes only the affected directory fingerprint',
    () async {
      final entries = _entries(opaque: false);
      for (var index = 0; index < entries.length; index++) {
        _save(store, entries[index], '$index', '${index + 1}');
      }
      final last = store.get('media', '3')!;
      store.setLocal('manualMetadata:3', true);
      store.save('media', '3', {...last.data, 'episode': '3'});
      final before = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(before.collection!.episodeCount, 3);
      store.save('media', '3', last.data);
      final corrected = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(corrected.collection!.episodeCount, 4);
      expect(corrected.fingerprint, isNot(before.fingerprint));
      store.save('media', 'unrelated', {'title': 'Elsewhere'});
      store.setLocal('unrelated-progress', 10);
      final unchanged = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(unchanged.fingerprint, corrected.fingerprint);
    },
  );

  test(
    'current explicit filename repairs an obsolete automatic episode guess',
    () async {
      final entries = _entries(opaque: false);
      for (var index = 0; index < entries.length; index++) {
        _save(store, entries[index], '$index', '${index == 3 ? 3 : index + 1}');
      }
      final prepared = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(prepared.collection!.episodeCount, 4);
      final result = await worker.synchronizeListing(
        'nas',
        'Example',
        entries,
        hideHidden: true,
      );
      expect(result!.collection.episodeCount, 4);
      expect(store.get('media', '3')!.data['episode'], '4');
      expect(result.changed, isTrue);
    },
  );

  test(
    'unknown extras and conflicting identities never become a fourth episode',
    () async {
      final entries = _entries();
      for (var index = 0; index < 3; index++) {
        _save(store, entries[index], '$index', '${index + 1}');
      }
      final unknown = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(unknown.collection!.episodeCount, 3);
      expect(unknown.collection!.listedVideoCount, 4);
      expect(unknown.collection!.membershipComplete, isFalse);
      _save(store, entries.last, 'extra', '4');
      final extra = store.get('media', 'extra')!;
      store.save('media', 'extra', {...extra.data, 'bangumiId': '99'});
      final conflict = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(conflict.collection!.episodeCount, 3);
      expect(conflict.collection!.listedVideoCount, 4);
      expect(conflict.collection!.membershipComplete, isFalse);
      expect(conflict.fingerprint, isNot(unknown.fingerprint));
      store.save('media', 'extra', {...extra.data, 'season': '2'});
      final otherSeason = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(otherSeason.collection!.episodeCount, 3);
      expect(otherSeason.collection!.membershipComplete, isFalse);
      expect(otherSeason.fingerprint, isNot(conflict.fingerprint));
      store.save('media', 'extra', {...extra.data, 'episode': '3'});
      final alternate = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(alternate.collection!.videos, hasLength(4));
      expect(alternate.collection!.episodeCount, 3);
      expect(alternate.collection!.membershipComplete, isTrue);
    },
  );

  test(
    'manual episode overrides survive complete AI synchronization and batching',
    () async {
      final entries = _entries();
      _save(store, entries[2], 'manual', '4');
      store.setLocal('manualMetadata:manual', true);
      final identities = {
        for (var index = 0; index < entries.length; index++)
          entries[index].path: ReleaseName('Example', '1', '${index + 1}'),
      };
      final collection = DirectoryCollection(
        title: 'Example',
        season: '1',
        videos: entries,
        identities: identities,
        subject: _subject,
        episodeCount: 4,
      );
      final full = await worker.synchronize(
        'nas',
        collection,
        importMissing: false,
      );
      expect(full.collection.identities[entries[2].path]!.episode, '4');
      expect(full.collection.episodeCount, 3);
      expect(full.collection.listedVideoCount, 4);
      expect(full.collection.membershipComplete, isTrue);
      expect(store.get('media', 'manual')!.data['episode'], '4');
      expect(full.changed, isFalse);
      final batch = await worker.synchronize(
        'nas',
        DirectoryCollection(
          title: collection.title,
          season: collection.season,
          videos: [entries[2]],
          identities: identities,
          subject: _subject,
          episodeCount: 4,
          listedVideoCount: 4,
          membershipComplete: true,
        ),
        importMissing: false,
      );
      expect(batch.collection.episodeCount, 3);
      expect(batch.collection.videos, hasLength(1));
    },
  );

  test(
    'cached metadata never replaces the freshly prepared membership',
    () async {
      final entries = _entries(opaque: false);
      var collection = identifyDirectory('Example', entries.take(3).toList())!;
      final transport = _Transport();
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        prepareDirectory: (_, _, _, _, _) async =>
            DirectoryInspection('same', collection, 0),
      );
      final old = await catalog.inspect('nas', 'Example', entries);
      expect(old!.episodeCount, 3);
      final requests = transport.requests;
      collection = identifyDirectory('Example', entries)!;
      final fresh = await catalog.inspect('nas', 'Example', entries);
      expect(fresh!.episodeCount, 4);
      expect(fresh.videos, hasLength(4));
      expect(fresh.membershipComplete, isTrue);
      expect(transport.requests, requests);
    },
  );

  test(
    'complete AI preview survives repeated partial parsing but not manual or listing changes',
    () async {
      final entries = _entries();
      final transport = _Transport()..missingSearch = true;
      var aiCalls = 0;
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        prepareDirectory: (source, path, context, entries, cancel) => worker
            .prepareInspection(source, path, context, entries, cancel: cancel),
        aiFallback: (_, _, _, _) async {
          aiCalls++;
          if (aiCalls > 1) return null;
          return DirectoryCollection(
            title: 'Example',
            season: '1',
            videos: entries,
            identities: {
              for (var index = 0; index < entries.length; index++)
                entries[index].path: ReleaseName(
                  'Example',
                  '1',
                  '${index + 1}',
                ),
            },
            subject: _subject,
            episodeTitles: {
              for (var episode = 1; episode <= 4; episode++)
                '$episode': 'Episode $episode',
            },
          );
        },
      );
      final first = await catalog.inspect('nas', 'Example', entries);
      expect(first!.episodeCount, 4);
      expect(first.membershipComplete, isTrue);
      expect(store.records('media'), isEmpty);
      final requests = transport.requests;
      for (var attempt = 0; attempt < 2; attempt++) {
        final cached = await catalog.inspect('nas', 'Example', entries);
        expect(cached!.episodeCount, 4);
        expect(cached.videos, hasLength(4));
        expect(cached.identities[entries.last.path]!.episode, '4');
        expect(cached.membershipComplete, isTrue);
      }
      expect(transport.requests, requests);
      expect(aiCalls, 1);

      _save(store, entries.last, 'opaque', '5');
      store.setLocal('manualMetadata:opaque', true);
      final manual = await catalog.inspect('nas', 'Example', entries);
      expect(manual!.identities[entries.last.path]!.episode, '5');
      final removed = await catalog.inspect(
        'nas',
        'Example',
        entries.take(3).toList(),
      );
      expect(removed!.episodeCount, 3);
      expect(removed.videos, hasLength(3));
      expect(removed.identities.containsKey(entries.last.path), isFalse);
    },
  );

  test(
    'identifying an excluded file as another work invalidates complete AI membership',
    () async {
      final entries = _entries();
      for (var index = 0; index < 3; index++) {
        _save(store, entries[index], '$index', '${index + 1}');
      }
      var aiCalls = 0;
      final catalog = LibraryCatalog(
        store,
        transport: _Transport()..missingSearch = true,
        prepareDirectory: (source, path, context, entries, cancel) => worker
            .prepareInspection(source, path, context, entries, cancel: cancel),
        aiFallback: (_, _, _, _) async {
          if (++aiCalls > 1) return null;
          return DirectoryCollection(
            title: 'Example',
            season: '1',
            videos: entries,
            identities: {
              for (var index = 0; index < entries.length; index++)
                entries[index].path: ReleaseName(
                  'Example',
                  '1',
                  '${index + 1}',
                ),
            },
            subject: _subject,
            episodeTitles: {
              for (var episode = 1; episode <= 4; episode++)
                '$episode': 'Episode $episode',
            },
          );
        },
      );
      final first = await catalog.inspect('nas', 'Example', entries);
      expect(first!.episodeCount, 4);
      final previous = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      _save(store, entries.last, 'other', '4');
      final other = store.get('media', 'other')!;
      store.save('media', 'other', {...other.data, 'bangumiId': '99'});
      store.setLocal('manualMetadata:other', true);
      final changed = await worker.prepareInspection(
        'nas',
        'Example',
        'test',
        entries,
      );
      expect(changed.collection!.episodeCount, 3);
      expect(changed.fingerprint, isNot(previous.fingerprint));
      final fresh = await catalog.inspect('nas', 'Example', entries);
      expect(fresh!.episodeCount, 3);
      expect(fresh.identities.containsKey(entries.last.path), isFalse);
      expect(fresh.membershipComplete, isFalse);
    },
  );

  test(
    'preview serialization retains partial membership in its compact envelope',
    () async {
      final entries = _entries();
      final transport = _Transport();
      final catalog = LibraryCatalog(store, transport: transport);
      final collection = await catalog.inspect('nas', 'Example', entries);
      expect(collection!.episodeCount, 3);
      expect(collection.listedVideoCount, 4);
      expect(collection.membershipComplete, isFalse);
      final restored = readDirectoryPreview(
        store,
        'nas',
        'Example',
      )!.collection!;
      expect(restored.listedVideoCount, 4);
      expect(restored.membershipComplete, isFalse);
      final envelopeCatalog = LibraryCatalog(
        store,
        transport: transport,
        readDirectory: (_, _, _) async => null,
      );
      final envelope = envelopeCatalog
          .directoryPreview('nas', 'Example')!
          .collection!;
      expect(envelope.videos, isEmpty);
      expect(envelope.listedVideoCount, 4);
      expect(envelope.membershipComplete, isFalse);
    },
  );
}
