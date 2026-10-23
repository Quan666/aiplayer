import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

const _entries = [
  SourceEntry(name: 'Series E01.mkv', path: 'Series/Series E01.mkv'),
  SourceEntry(name: 'Series E02.mkv', path: 'Series/Series E02.mkv'),
  SourceEntry(name: 'Series E03.mkv', path: 'Series/Series E03.mkv'),
];
const _subject = {
  'id': '42',
  'provider': 'bangumi',
  'name': '已识别系列',
  'summary': '系列简介',
  'total_episodes': 12,
};

class _Directory extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => _entries;
  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _Catalog extends LibraryCatalog {
  int resolves = 0, nameLoads = 0;
  bool failNames = false;
  Completer<void>? namesStarted;
  Completer<void>? namesReady;
  _Catalog(super.store);

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    resolves++;
    cancel?.check();
    return _subject;
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async {
    nameLoads++;
    namesStarted?.complete();
    if (namesReady != null) {
      await Future.any([
        namesReady!.future,
        if (cancel != null) cancel.whenCancelled,
      ]);
    }
    cancel?.check();
    if (failNames) throw const AppFailure('temporary metadata failure');
    return {'1': '初遇', '2': '再会', '3': '新的旅程'};
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  late final testCatalog = _Catalog(store);
  @override
  LibraryCatalog get catalog => testCatalog;
  @override
  Future<SourceAdapter> adapter(String id) async => _Directory();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _Model model;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('series-auto-metadata-');
    store = AppStore('${root.path}/library.db');
    model = _Model(store, root);
  });
  tearDown(() async {
    model.dispose();
    store.dispose();
    await root.delete(recursive: true);
  });

  void seed({bool identified = false}) {
    store.save('media', 'first', {
      'title': _entries.first.name,
      'fileName': _entries.first.name,
      'series': 'Series',
      'season': '',
      'episode': '1',
      if (identified) ...subjectMediaFields(_subject),
    });
    store.setLocal('location:first', {
      'id': 'first',
      'source': 'nas',
      'path': _entries.first.path,
    });
  }

  for (final identified in [false, true]) {
    test(
      'details automatically complete every episode metadata, identified=$identified',
      () async {
        seed(identified: identified);
        final loaded = await model.loadSeriesEpisodes(
          store.get('media', 'first')!,
        );
        expect(loaded, hasLength(3));
        expect(loaded.map((r) => r.data['episodeTitle']), ['初遇', '再会', '新的旅程']);
        expect(loaded.every((r) => r.data['bangumiId'] == '42'), isTrue);
        expect(loaded.every((r) => r.data['summary'] == '系列简介'), isTrue);
        expect(model.testCatalog.resolves, identified ? 0 : 1);
        expect(model.testCatalog.nameLoads, 1);
        expect(store.records('progress'), isEmpty);
        final revision = store.recordsRevision('media');
        var notifications = 0;
        model.addListener(() => notifications++);
        await model.loadSeriesEpisodes(store.get('media', 'first')!);
        expect(store.recordsRevision('media'), revision);
        expect(notifications, 0);
      },
    );
  }

  test(
    'episode name failure retains matched series and is retried on next detail load',
    () async {
      seed();
      model.testCatalog.failNames = true;
      final partial = await model.loadSeriesEpisodes(
        store.get('media', 'first')!,
      );
      expect(partial, hasLength(3));
      expect(partial.every((r) => r.data['bangumiId'] == '42'), isTrue);
      expect(
        model.seriesRefreshDelay(partial.first),
        const Duration(seconds: 60),
      );
      model.testCatalog.failNames = false;
      final completed = await model.loadSeriesEpisodes(
        store.get('media', 'first')!,
      );
      expect(completed.map((r) => r.data['episodeTitle']), [
        '初遇',
        '再会',
        '新的旅程',
      ]);
      expect(model.testCatalog.resolves, 1);
      expect(model.testCatalog.nameLoads, 2);
    },
  );

  test(
    'cancelling metadata preserves imported episodes and resume enriches them',
    () async {
      seed();
      final cancel = CancelToken();
      final started = model.testCatalog.namesStarted = Completer<void>();
      model.testCatalog.namesReady = Completer<void>();
      final work = model.loadSeriesEpisodes(
        store.get('media', 'first')!,
        cancel: cancel,
      );
      await started.future.timeout(const Duration(seconds: 5));
      expect(store.records('media'), hasLength(3));
      final stopped = expectLater(work, throwsA(isA<Cancelled>()));
      cancel.cancel();
      await stopped;
      model.testCatalog.namesStarted = null;
      model.testCatalog.namesReady!.complete();
      model.testCatalog.namesReady = null;
      final completed = await model.loadSeriesEpisodes(
        store.get('media', 'first')!,
      );
      expect(completed.map((r) => r.data['episodeTitle']), [
        '初遇',
        '再会',
        '新的旅程',
      ]);
      expect(store.records('progress'), isEmpty);
    },
  );

  test(
    'automatic metadata off still completes files without catalogue requests',
    () async {
      seed();
      store.setLocal('settings', {'metadataStrategy': 'off'});
      final loaded = await model.loadSeriesEpisodes(
        store.get('media', 'first')!,
      );
      expect(loaded, hasLength(3));
      expect(model.testCatalog.resolves, 0);
      expect(model.testCatalog.nameLoads, 0);
    },
  );

  test('model disposal cancels in-flight detail metadata', () async {
    seed();
    final other = _Model(store, root);
    final started = other.testCatalog.namesStarted = Completer<void>();
    other.testCatalog.namesReady = Completer<void>();
    final work = other.loadSeriesEpisodes(store.get('media', 'first')!);
    await started.future.timeout(const Duration(seconds: 5));
    final stopped = expectLater(work, throwsA(isA<Cancelled>()));
    other.dispose();
    await stopped.timeout(const Duration(seconds: 5));
    expect(store.records('progress'), isEmpty);
  });

  for (final playback in [false, true]) {
    test(
      'automatic detail request cancels on ${playback ? 'playback' : 'background'} even after immediate resume',
      () async {
        seed();
        final started = model.testCatalog.namesStarted = Completer<void>();
        final ready = model.testCatalog.namesReady = Completer<void>();
        final work = model.loadSeriesEpisodes(store.get('media', 'first')!);
        await started.future.timeout(const Duration(seconds: 5));
        final stopped = expectLater(work, throwsA(isA<Cancelled>()));
        // No widget pumps/frames intervene between pause and resume.
        if (playback) {
          model.activePlaybackMediaId = 'first';
          model.activePlaybackMediaId = null;
        } else {
          model.setForeground(false);
          model.setForeground(true);
        }
        await stopped.timeout(const Duration(seconds: 5));
        ready.complete();
        expect(
          store.records('media').every((r) => r.data['bangumiId'] == null),
          isTrue,
        );
        model.testCatalog.namesStarted = null;
        model.testCatalog.namesReady = null;
        final loaded = await model.loadSeriesEpisodes(
          store.get('media', 'first')!,
        );
        expect(loaded.map((r) => r.data['episodeTitle']), ['初遇', '再会', '新的旅程']);
        expect(model.testCatalog.nameLoads, 2);
        expect(store.records('progress'), isEmpty);
      },
    );
  }

  for (final change in ['source', 'binding', 'catalogue']) {
    test(
      'late detail metadata cannot overwrite changed $change context',
      () async {
        seed();
        store.setLocal('sources', [
          {'id': 'nas', 'kind': 'webdav', 'url': 'http://example.test/dav/'},
        ]);
        final started = model.testCatalog.namesStarted = Completer<void>();
        final ready = model.testCatalog.namesReady = Completer<void>();
        final work = model.loadSeriesEpisodes(store.get('media', 'first')!);
        await started.future.timeout(const Duration(seconds: 5));
        final stopped = expectLater(work, throwsA(isA<Cancelled>()));
        switch (change) {
          case 'source':
            store.setLocal('sources', <Map<String, dynamic>>[]);
          case 'binding':
            store.setLocal('location:first', {
              'id': 'first',
              'source': 'nas',
              'path': 'Elsewhere/first.mkv',
            });
          case 'catalogue':
            model.catalog.invalidateMetadataCaches();
        }
        ready.complete();
        await stopped.timeout(const Duration(seconds: 5));
        expect(
          store.records('media').every((r) => r.data['bangumiId'] == null),
          isTrue,
        );
      },
    );
  }
}
