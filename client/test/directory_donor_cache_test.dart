import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends AppStore {
  int lookups = 0;
  void Function()? afterCommit;
  void Function()? beforeAction;
  bool rollback = false;
  _Store(super.path);

  @override
  Map<String, dynamic>? locationFor(String sourceId, String path) {
    lookups++;
    return super.locationFor(sourceId, path);
  }

  @override
  void transaction(void Function() action) {
    final before = beforeAction;
    final fail = rollback;
    beforeAction = null;
    rollback = false;
    super.transaction(() {
      before?.call();
      action();
      if (fail) throw StateError('rollback after donor checkpoint');
    });
    final after = afterCommit;
    afterCommit = null;
    after?.call();
  }
}

Map<String, dynamic> _subject(String id) => {
  'id': id,
  'provider': 'bangumi',
  'name': 'Show',
  'mediaType': 'tv',
};

DirectoryCollection _group(int count) {
  final videos = [
    for (var episode = 1; episode <= count; episode++)
      SourceEntry(name: 'Show S01E$episode.mkv', path: 'Show/$episode.mkv'),
  ];
  return DirectoryCollection(
    title: 'Show',
    season: '1',
    videos: videos,
    identities: {
      for (var i = 0; i < videos.length; i++)
        videos[i].path: ReleaseName('Show', '1', '${i + 1}'),
    },
    subject: _subject('7'),
    episodeTitles: {
      for (var episode = 1; episode <= count; episode++)
        '$episode': 'Chapter $episode',
    },
  );
}

DirectoryCollection _batch(DirectoryCollection group, int start, int end) =>
    DirectoryCollection(
      title: group.title,
      season: group.season,
      videos: group.videos.sublist(start, end),
      identities: group.identities,
      subject: group.subject,
      episodeTitles: group.episodeTitles,
    );

void _manual(AppStore store, String id, String subject) {
  final record = store.get('media', id)!;
  store.save('media', id, {
    ...record.data,
    ...subjectMediaFields(_subject(subject)),
  });
  store.setLocal('manualMetadata:$id', true);
}

void main() {
  test(
    'bounded imports read full donor group once across their own commits',
    () {
      final store = _Store(':memory:');
      addTearDown(store.dispose);
      final group = _group(512);
      final seed = synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 0, 1),
        importMissing: true,
      );
      _manual(store, seed.mediaIds.single, '88');
      final cache = DirectoryMetadataDonorCache('nas', group.videos);
      store.lookups = 0;
      for (var offset = 0; offset < group.videos.length; offset += 128) {
        final result = synchronizeDirectoryCollection(
          store,
          'nas',
          _batch(group, offset, offset + 128),
          importMissing: true,
          donorCache: cache,
        );
        expect(result.collection.subject?['id'], '88');
        store.setLocal('lastSync', 'batch $offset');
        store.save('progress', 'playing', {'position': offset});
      }
      expect(
        store.lookups,
        1024,
        reason: '512 donor reads plus 512 batch reads',
      );
      expect(store.all('media'), hasLength(512));
      expect(
        store.all('media').every((record) => record.data['bangumiId'] == '88'),
        isTrue,
      );
    },
  );

  test('a manual edit immediately after commit is seen by the next batch', () {
    final directory = Directory.systemTemp.createTempSync('directory-donors-');
    final store = _Store('${directory.path}/library.db');
    final external = AppStore.openExisting(store.path);
    addTearDown(() {
      external.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    });
    final group = _group(4);
    final seed = synchronizeDirectoryCollection(
      store,
      'nas',
      _batch(group, 0, 1),
      importMissing: true,
    );
    final id = seed.mediaIds.single;
    final cache = DirectoryMetadataDonorCache('nas', group.videos);
    store.afterCommit = () =>
        external.transaction(() => _manual(external, id, '88'));
    synchronizeDirectoryCollection(
      store,
      'nas',
      _batch(group, 0, 2),
      importMissing: true,
      donorCache: cache,
    );
    final result = synchronizeDirectoryCollection(
      store,
      'nas',
      _batch(group, 2, 4),
      importMissing: true,
      donorCache: cache,
    );
    expect(result.collection.subject?['id'], '88');
    for (final id in result.mediaIds) {
      expect(store.get('media', id)!.data['bangumiId'], '88');
    }
  });

  test(
    'rollback invalidates donor evidence captured inside the failed transaction',
    () {
      final store = _Store(':memory:');
      addTearDown(store.dispose);
      final group = _group(3);
      final seed = synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 0, 1),
        importMissing: true,
      );
      final id = seed.mediaIds.single;
      final cache = DirectoryMetadataDonorCache('nas', group.videos);
      store.beforeAction = () => _manual(store, id, '88');
      store.rollback = true;
      expect(
        () => synchronizeDirectoryCollection(
          store,
          'nas',
          _batch(group, 1, 2),
          importMissing: true,
          donorCache: cache,
        ),
        throwsStateError,
      );
      final result = synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 1, 3),
        importMissing: true,
        donorCache: cache,
      );
      expect(result.collection.subject?['id'], '7');
      expect(store.local('manualMetadata:$id'), isNull);
      expect(
        store.all('media').every((record) => record.data['bangumiId'] == '7'),
        isTrue,
      );
    },
  );

  test(
    'direct SQL invalidates cached donor identity and per-episode titles',
    () {
      final store = _Store(':memory:');
      addTearDown(store.dispose);
      final group = _group(3);
      final seed = synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 0, 1),
        importMissing: true,
      );
      final id = seed.mediaIds.single;
      final cache = DirectoryMetadataDonorCache('nas', group.videos);
      synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 1, 2),
        importMissing: true,
        donorCache: cache,
      );
      final updated = {
        ...store.get('media', id)!.data,
        ...subjectMediaFields(_subject('88')),
        'episodeTitle': 'Corrected title',
      };
      store.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
        jsonEncode(updated),
        'media',
        id,
      ]);
      store.db.execute('UPDATE local SET value=? WHERE key=?', [
        jsonEncode('Corrected title'),
        'episodeTitle:$id',
      ]);
      store.setLocal('manualMetadata:$id', true);
      final result = synchronizeDirectoryCollection(
        store,
        'nas',
        _batch(group, 0, 3),
        importMissing: true,
        donorCache: cache,
      );
      expect(result.collection.subject?['id'], '88');
      expect(result.collection.episodeTitles['1'], 'Corrected title');
    },
  );

  test(
    'fresh catalogue titles replace old automatic titles while manual titles survive',
    () {
      final store = _Store(':memory:');
      addTearDown(store.dispose);
      final group = _group(2);
      final seeded = synchronizeDirectoryCollection(
        store,
        'nas',
        group,
        importMissing: true,
      );
      final fresh = group.withMetadata(group.subject, {
        '1': 'New first',
        '2': 'New second',
      });
      final automatic = synchronizeDirectoryCollection(store, 'nas', fresh);
      expect(automatic.collection.episodeTitles, {
        '1': 'New first',
        '2': 'New second',
      });
      final id = seeded.mediaIds.first;
      store.save('media', id, {
        ...store.get('media', id)!.data,
        'episodeTitle': 'Manual first',
      });
      store.setLocal('episodeTitle:$id', 'Manual first');
      store.setLocal('manualMetadata:$id', true);
      final manual = synchronizeDirectoryCollection(store, 'nas', fresh);
      expect(manual.collection.episodeTitles['1'], 'Manual first');
    },
  );
}
