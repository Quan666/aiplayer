import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/directory_sort.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'folder downloads start at their selected directory without a source root',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.store.setLocal('sources', [
          {'id': 'nas-a', 'label': 'NAS'},
          {'id': 'nas-b', 'label': 'Other NAS'},
        ]);
        for (final (id, source, selected, relative) in [
          ('one', 'nas-a', '2026-10/Show', 'Show/Season 1/one.mkv'),
          ('two', 'nas-a', '2026-10/Show', 'Show/Season 1/two.mkv'),
          ('other', 'nas-b', '2026-10/Show', 'Show/Season 1/one.mkv'),
          ('archive', 'nas-a', 'Archive/Show', 'Show/one.mkv'),
        ]) {
          fixture.add(
            id,
            source,
            '$selected/${relative.substring('Show/'.length)}',
          );
          fixture.offlineLocations[id]!.addAll({
            'downloadRoot': selected,
            'downloadRelativePath': relative,
          });
        }
        final snapshot = await fixture.read();
        final roots = snapshot.localDirectories['']!.entries;
        expect(roots.map((entry) => entry.name), ['Show', 'Show', 'Show']);
        expect(roots.map((entry) => entry.path).toSet(), hasLength(3));
        expect(
          snapshot.localDirectories.values.any(
            (entry) =>
                ['NAS', 'Other NAS', '2026-10', 'Archive'].contains(entry.name),
          ),
          isFalse,
        );
        final season = snapshot.localDirectories.values.singleWhere(
          (directory) => directory.records.containsKey('one'),
        );
        final show = snapshot.localDirectories[season.parentPath]!;
        expect(show.sourceId, isNull);
        expect(show.parentPath, '');
        expect(season.name, 'Season 1');
        expect(season.records.keys, unorderedEquals(['one', 'two']));
        expect(fixture.store.fullReads, 0);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'worker prepares original folders for every completed download',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.add('folder-episode', 'nas-a', 'Series/Season 1/E01.mkv');
        fixture.add('batch-episode', 'nas-a', 'Series/Season 1/E02.mkv');
        fixture.add('single-episode', 'nas-a', r'Series\Season 1\E03.mkv');
        fixture.add(
          'single-movie',
          'nas-a',
          '/Movies/2026/../Feature/Movie.mp4',
        );
        fixture.add('other-source', 'nas-b', 'Series/Season 1/E01.mkv');
        fixture.add('root-file', 'nas-a', 'Trailer.mp4');
        fixture.add('direct-link', 'http', '');
        fixture.add(
          'import',
          'local',
          '/device/imports/Home.mp4',
          offline: false,
        );
        fixture.add(
          'remote-only',
          'nas-a',
          'Other/Not downloaded.mp4',
          offline: false,
        );

        final snapshot = await fixture.read();
        expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
        expect(fixture.store.fullReads, 0);
        expect(snapshot.localEntries, hasLength(8));
        expect(snapshot.localRecords, hasLength(8));
        final root = snapshot.localDirectories['']!;
        expect(root.parentPath, isNull);
        expect(root.records.keys, ['import']);
        expect(
          root.entries.where((entry) => !entry.directory).single.path,
          'import',
        );
        expect(root.entries.where((entry) => entry.directory), hasLength(3));
        final nas = _source(snapshot, 'nas-a');
        final otherNas = _source(snapshot, 'nas-b');
        final http = _source(snapshot, 'http');
        expect(nas.parentPath, '');
        expect(nas.name, 'nas-a');
        expect(nas.records.keys, ['root-file']);
        expect(http.records.keys, ['direct-link']);
        final series = _child(snapshot, nas, 'Series');
        final season = _child(snapshot, series, 'Season 1');
        expect(series.sourceId, isNull);
        expect(series.records, isEmpty);
        expect(season.parentPath, series.path);
        expect(
          season.records.keys,
          unorderedEquals([
            'folder-episode',
            'batch-episode',
            'single-episode',
          ]),
        );
        expect(season.entries.every((entry) => !entry.directory), isTrue);
        expect(season.entries.map((entry) => entry.path), season.records.keys);
        final otherSeason = _child(
          snapshot,
          _child(snapshot, otherNas, 'Series'),
          'Season 1',
        );
        expect(otherSeason.path, isNot(season.path));
        expect(otherSeason.records.keys, ['other-source']);
        final feature = _child(
          snapshot,
          _child(snapshot, nas, 'Movies'),
          'Feature',
        );
        expect(feature.records.keys, ['single-movie']);
        expect(
          snapshot.localDirectories.values.any(
            (directory) => directory.name == '2026',
          ),
          isFalse,
        );
        // The hierarchy contains only direct membership, never copied subtrees.
        expect(
          snapshot.localDirectories.values.fold<int>(
            0,
            (count, directory) => count + directory.records.length,
          ),
          snapshot.localRecords.length,
        );
        expect(() => snapshot.localDirectories.clear(), throwsUnsupportedError);
        expect(() => season.entries.clear(), throwsUnsupportedError);
        expect(() => season.records.clear(), throwsUnsupportedError);
        expect(
          () => season.records['folder-episode']!.data['title'] = 'mutated',
          throwsUnsupportedError,
        );
        expect(
          season.records['folder-episode'],
          same(snapshot.localRecords['folder-episode']),
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'offline removal prunes empty folders while stable siblings remain',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.add('one', 'nas', 'Show/Season 1/one.mkv');
        fixture.add('two', 'nas', 'Show/Season 2/two.mkv');
        fixture.add('import', 'local', '/device/Home.mp4', offline: false);
        final original = await fixture.read();
        final originalSource = _source(original, 'nas');
        final show = _child(original, originalSource, 'Show');
        final firstSeason = _child(original, show, 'Season 1');
        final secondSeason = _child(original, show, 'Season 2');

        fixture.offlineLocations.remove('one');
        fixture.offlineRevision++;
        final removed = await fixture.read();
        expect(removed.localRecords.keys, unorderedEquals(['two', 'import']));
        expect(removed.localDirectories, isNot(contains(firstSeason.path)));
        expect(_source(removed, 'nas').path, originalSource.path);
        expect(removed.localDirectories[secondSeason.path]?.records.keys, [
          'two',
        ]);
        expect(original.localDirectories[firstSeason.path]?.records.keys, [
          'one',
        ]);

        fixture.offlineLocations.remove('two');
        fixture.offlineRevision++;
        final empty = await fixture.read();
        expect(empty.localDirectories.keys, ['']);
        expect(empty.localDirectories['']!.entries.single.path, 'import');
        expect(empty.localRecords.keys, ['import']);
        expect(fixture.store.fullReads, 0);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'external binding and deletion revisions exclude stale downloads',
    () async {
      final fixture = await _Fixture.create();
      final writer = AppStore.openExisting(fixture.store.path);
      try {
        for (final id in ['source', 'path', 'revision', 'deleted', 'sql']) {
          fixture.add(id, 'nas-$id', 'Show/$id.mkv');
        }
        fixture.add('unbound', 'nas-unbound', 'Show/unbound.mkv');
        writer.removeLocal('location:unbound');
        final original = await fixture.read();
        expect(original.localRecords, hasLength(6));
        // A removed remote binding can still use its completed managed copy.
        expect(_source(original, 'nas-unbound').entries.single.name, 'Show');
        for (final (id, patch) in [
          ('source', {'source': 'replacement'}),
          ('path', {'path': 'Elsewhere/video.mkv'}),
          ('revision', {'previewRevision': 'replacement'}),
        ]) {
          writer.setLocal('location:$id', {
            ...writer.local('location:$id') as Map,
            ...patch,
          });
        }
        writer.save('media', 'deleted', {}, deleted: true);
        writer.db.execute(
          'UPDATE records SET deleted=1 WHERE kind=? AND id=?',
          ['media', 'sql'],
        );
        final changed = await fixture.read();
        expect(changed.localRecords.keys, ['unbound']);
        expect(
          changed.localDirectories.values
              .where((value) => value.sourceId != null)
              .single
              .sourceId,
          'nas-unbound',
        );
        expect(original.localRecords, hasLength(6));
        expect(fixture.store.fullReads, 0);
      } finally {
        writer.dispose();
        await fixture.close();
      }
    },
  );

  test('progress and search reuse the immutable hierarchy', () async {
    final fixture = await _Fixture.create(memory: true);
    try {
      fixture.add('one', 'nas', 'Show/Season/one.mkv');
      final original = await fixture.read();
      fixture.store.save('progress', 'one:32', {
        'position': 5,
        'updatedAt': '2026-10-29',
      });
      final progressed = await fixture.read();
      expect(progressed.localDirectories, same(original.localDirectories));
      expect(progressed.localEntries, same(original.localEntries));
      expect(progressed.recent.single.id, 'one');
      final searched = await fixture.read(query: 'no matching title');
      expect(searched.groups, isEmpty);
      expect(searched.localDirectories, same(original.localDirectories));
      fixture.offlineLocations.clear();
      fixture.offlineRevision++;
      final removed = await fixture.read();
      expect(removed.localDirectories, isNot(same(original.localDirectories)));
      expect(removed.localDirectories.keys, ['']);
      expect(removed.localDirectories['']!.entries, isEmpty);
    } finally {
      await fixture.close();
    }
  });

  for (final memory in [false, true]) {
    test(
      'source names and rename supply folder sort names (memory: $memory)',
      () async {
        final fixture = await _Fixture.create(memory: memory);
        try {
          fixture.add('one', 'source-a', 'Show/one.mkv');
          fixture.add('two', 'source-z', 'Show/two.mkv');
          fixture.store.setLocal('sources', [
            {'id': 'source-a', 'label': 'Zulu'},
            {'id': 'source-z', 'label': 'Alpha'},
          ]);
          final original = await fixture.read();
          final sourceKey = _source(original, 'source-a').path;
          List<String> sortedNames(LibrarySnapshot snapshot) =>
              const DirectorySort()
                  .apply(snapshot.localDirectories['']!.entries)
                  .map((entry) => entry.name)
                  .toList();
          expect(sortedNames(original), ['Alpha', 'Zulu']);
          expect(_source(original, 'source-a').name, 'Zulu');

          fixture.store.setLocal('sources', [
            {'id': 'source-a', 'label': 'Beta'},
            {'id': 'source-z', 'label': 'Alpha'},
          ]);
          final renamed = await fixture.read();
          expect(sortedNames(renamed), ['Alpha', 'Beta']);
          expect(_source(renamed, 'source-a').path, sourceKey);
          expect(_source(renamed, 'source-a').name, 'Beta');
          expect(_source(original, 'source-a').name, 'Zulu');

          fixture.store.setLocal('sources', [
            {'id': 'source-a', 'label': 'Beta'},
            {'id': 'source-z', 'label': ''},
          ]);
          expect(_source(await fixture.read(), 'source-z').name, 'source-z');
          if (!memory) expect(fixture.store.fullReads, 0);
        } finally {
          await fixture.close();
        }
      },
    );
  }

  test(
    'hidden download parents also hide descendants from flat search and counts',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.add('normal', 'nas', 'Show/one.mp4');
        fixture.add('hidden-parent', 'nas', '.Secret/two.mp4');
        fixture.add('nested-hidden', 'nas', r'Show\.Extras\three.mp4');
        fixture.add('hidden-file', 'nas', 'Show/.four.mp4');
        fixture.add(
          'import',
          'local',
          '/device/.Private/Home.mp4',
          offline: false,
        );
        final snapshot = await fixture.read();
        expect(snapshot.localEntries, hasLength(5));
        expect(snapshot.localHiddenEntries, 3);
        final entries = {
          for (final entry in snapshot.localEntries) entry.path: entry,
        };
        expect(entries['hidden-parent']!.hidden, isTrue);
        expect(entries['nested-hidden']!.hidden, isTrue);
        expect(entries['import']!.hidden, isFalse);
        expect(
          const DirectorySort()
              .apply(snapshot.localEntries, hideHiddenFiles: true)
              .map((entry) => entry.path),
          unorderedEquals(['normal', 'import']),
        );
        expect(
          const DirectorySort().apply(
            snapshot.localEntries,
            hideHiddenFiles: false,
          ),
          hasLength(5),
        );
        final show = _child(snapshot, _source(snapshot, 'nas'), 'Show');
        final extras = _child(snapshot, show, '.Extras');
        expect(extras.entries.single.hidden, isTrue);
        expect(extras.records.keys, ['nested-hidden']);
        expect(fixture.store.fullReads, 0);
      } finally {
        await fixture.close();
      }
    },
  );
}

LocalDirectorySnapshot _source(LibrarySnapshot snapshot, String source) =>
    snapshot.localDirectories.values.singleWhere(
      (value) => value.sourceId == source,
    );

LocalDirectorySnapshot _child(
  LibrarySnapshot snapshot,
  LocalDirectorySnapshot parent,
  String name,
) =>
    snapshot.localDirectories[parent.entries
        .singleWhere((entry) => entry.directory && entry.name == name)
        .path]!;

class _Fixture {
  final Directory directory;
  final _CountingStore store;
  late final reader = LibrarySnapshotReader(store);
  final offlineLocations = <String, Map<String, dynamic>>{};
  var offlineRevision = 0;

  _Fixture(this.directory, this.store);

  static Future<_Fixture> create({bool memory = false}) async {
    final directory = await Directory.systemTemp.createTemp('local-hierarchy-');
    return _Fixture(
      directory,
      _CountingStore(
        memory ? ':memory:' : p.join(directory.path, 'library.db'),
      ),
    );
  }

  void add(String id, String source, String path, {bool offline = true}) {
    final name = path.isEmpty
        ? '$id.mp4'
        : path.replaceAll('\\', '/').split('/').last;
    store.save('media', id, {'title': name, 'fileName': name, 'size': 32});
    store.setLocal('location:$id', {
      'id': id,
      'source': source,
      'path': path,
      'size': 32,
    });
    if (offline) {
      offlineLocations[id] = {
        'id': id,
        'source': 'local',
        'path': '/managed/offline/$id.mp4',
        'size': 32,
        'offline': true,
        'remoteSource': source,
        'remotePath': path,
        'remoteRevision': '',
      };
      offlineRevision++;
    }
  }

  Future<LibrarySnapshot> read({String query = ''}) => reader.read(
    query: query,
    revision: (
      store.recordsRevision('media'),
      store.recordsRevision('progress'),
      max(store.locationRevision, store.localKeyRevision('sources')),
    ),
    offlineRevision: offlineRevision,
    offlineLocations: offlineLocations,
  );

  Future<void> close() async {
    reader.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  }
}

class _CountingStore extends AppStore {
  var fullReads = 0;
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
