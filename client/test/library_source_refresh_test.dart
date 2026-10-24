import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  final paths = <String>[];
  final listings = <String, List<SourceEntry>>{};
  final pending = <String, Completer<List<SourceEntry>>>{};
  int active = 0, maximum = 0, closed = 0;
  @override
  Future<SourceAdapter> adapter(String id) async => _Source(this);
}

class _Source extends SourceAdapter {
  final _Model model;
  bool reading = false;
  _Source(this.model);
  @override
  Future<List<SourceEntry>> list(String path) async {
    model.paths.add(path);
    reading = true;
    model.active++;
    if (model.active > model.maximum) model.maximum = model.active;
    try {
      if (path == 'Offline') throw const AppFailure('offline');
      return await (model.pending[path]?.future ??
          Future.value(model.listings[path] ?? const []));
    } finally {
      if (reading) model.active--;
      reading = false;
    }
  }

  @override
  Future<void> close() async {
    model.closed++;
    if (reading) model.active--;
    reading = false;
  }

  @override
  Future<SourceEntry> stat(String path) => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

List<SourceEntry> _episodes(String folder, int count) => [
  for (var episode = 1; episode <= count; episode++)
    SourceEntry(
      name: '$folder S01E0$episode.mkv',
      path: '$folder/$folder S01E0$episode.mkv',
      size: 42,
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _Model model;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-source-refresh-');
    store = AppStore('${root.path}/library.db');
    store.setLocal('settings', {'metadataStrategy': 'off'});
    model = _Model(store, root);
  });
  tearDown(() async {
    model.dispose();
    store.dispose();
    await root.delete(recursive: true);
  });

  void seed(String folder, int count) {
    for (final entry in _episodes(folder, count)) {
      model.addMedia('nas', entry);
    }
  }

  Future<void> waitForRequest() async {
    for (var attempt = 0; attempt < 200 && model.paths.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(model.paths, isNotEmpty);
  }

  test(
    'pull refresh deduplicates known folders and imports new episodes',
    () async {
      seed('Alpha', 2);
      seed('Beta', 1);
      model.listings['Alpha'] = _episodes('Alpha', 3);
      model.listings['Beta'] = _episodes('Beta', 2);
      final work = model.refreshLibrarySources();
      expect(model.refreshLibrarySources(), same(work));
      await work;
      expect(model.paths, unorderedEquals(['Alpha', 'Beta']));
      expect(model.maximum, 1);
      expect(model.closed, 2);
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.media, hasLength(5));
      expect(snapshot.folders, hasLength(2));
    },
  );

  test(
    'background cancellation closes active listing without starting another',
    () async {
      seed('Alpha', 1);
      seed('Beta', 1);
      final pending = Completer<List<SourceEntry>>();
      model.pending['Alpha'] = pending;
      model.pending['Beta'] = pending;
      final work = model.refreshLibrarySources();
      final cancelled = expectLater(work, throwsA(isA<Cancelled>()));
      await waitForRequest();
      model.setForeground(false);
      await cancelled;
      expect(model.paths, hasLength(1));
      expect(model.closed, 1);
      pending.complete(_episodes(model.paths.single, 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(model.paths, hasLength(1));
      expect((await model.loadLibrarySnapshot()).media, hasLength(2));
      model.setForeground(true);
      model.pending.clear();
      model.listings['Alpha'] = _episodes('Alpha', 2);
      model.listings['Beta'] = _episodes('Beta', 2);
      await model.refreshLibrarySources();
      expect((await model.loadLibrarySnapshot()).media, hasLength(4));
      expect(model.maximum, 1);
    },
  );

  test(
    'source changes cancel stale results and allow another explicit refresh',
    () async {
      seed('Alpha', 1);
      final pending = model.pending['Alpha'] = Completer<List<SourceEntry>>();
      final work = model.refreshLibrarySources();
      final cancelled = expectLater(work, throwsA(isA<Cancelled>()));
      await waitForRequest();
      store.setLocal('sources', [
        {'id': 'nas', 'kind': 'webdav', 'url': 'https://changed.invalid'},
      ]);
      model.changed();
      await cancelled;
      pending.complete(_episodes('Alpha', 2));
      expect((await model.loadLibrarySnapshot()).media, hasLength(1));
      model.pending.clear();
      model.listings['Alpha'] = _episodes('Alpha', 3);
      await model.refreshLibrarySources();
      expect((await model.loadLibrarySnapshot()).media, hasLength(3));
    },
  );

  test(
    'offline folder preserves content and other directories still refresh',
    () async {
      seed('Offline', 1);
      seed('Alpha', 1);
      model.listings['Alpha'] = _episodes('Alpha', 2);
      await expectLater(
        model.refreshLibrarySources(),
        throwsA(isA<AppFailure>()),
      );
      expect(model.paths, unorderedEquals(['Offline', 'Alpha']));
      expect((await model.loadLibrarySnapshot()).media, hasLength(3));
      expect(model.closed, 2);
    },
  );

  for (final change in ['delete', 'rebind']) {
    test('mixed folder guard rejects $change during its listing', () async {
      seed('Alpha', 1);
      final other = _episodes('Beta', 1).single;
      model.addMedia(
        'nas',
        SourceEntry(name: other.name, path: 'Alpha/${other.name}', size: 42),
      );
      final snapshot = await model.loadLibrarySnapshot();
      final folder = snapshot.folders.values.single;
      expect(folder.seriesKey, isNull);
      final guard = folder.records.first;
      final pending = model.pending['Alpha'] = Completer<List<SourceEntry>>();
      final work = model.refreshLibrarySources();
      final cancelled = expectLater(work, throwsA(isA<Cancelled>()));
      await waitForRequest();
      // Simulate a different connection committing while the network is busy;
      // no model notification is needed for the worker's transaction guard.
      final writer = AppStore(store.path);
      try {
        if (change == 'delete') {
          writer.save('media', guard.id, guard.data, deleted: true);
        } else {
          writer.setLocal('location:${guard.id}', {
            ...snapshot.locations[guard.id]!,
            'path': 'Moved/${guard.data['fileName']}',
          });
        }
      } finally {
        writer.dispose();
      }
      pending.complete(_episodes('Alpha', 3));
      await cancelled;
      final updated = await model.loadLibrarySnapshot();
      expect(updated.media.length, change == 'delete' ? 1 : 2);
      expect(model.paths, ['Alpha']);
      expect(model.closed, 1);
    });
  }
}
