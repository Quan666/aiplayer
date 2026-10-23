import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends AppStore {
  _Store(super.path);
  int enumerations = 0;
  @override
  Map<String, dynamic> localEntries(String prefix) {
    enumerations++;
    return super.localEntries(prefix);
  }
}

class _Catalog extends LibraryCatalog {
  _Catalog(super.store, LibraryCatalog production)
    : super(
        prepareDirectory: production.prepareDirectory,
        persistDirectory: production.persistDirectory,
        readDirectory: production.readDirectory,
        episodeNamesCovered: production.episodeNamesCovered,
      );
  int resolves = 0;
  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    cancel?.check();
    resolves++;
    return {'id': '42', 'name': 'Series', 'name_cn': '测试系列'};
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async => {'1': '第一集', '2': '第二集', '3': '第三集'};
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  int listings = 0, episodes = 2;
  late final _trackedCatalog = _Catalog(store, super.catalog);
  @override
  LibraryCatalog get catalog => _trackedCatalog;
  @override
  Future<SourceAdapter> adapter(String id) async => _Source(this);
}

class _Source extends SourceAdapter {
  final _Model model;
  _Source(this.model);
  @override
  Future<List<SourceEntry>> list(String path) async {
    model.listings++;
    return [
      for (var i = 1; i <= model.episodes; i++)
        SourceEntry(name: 'Series E0$i.mkv', path: 'Series/Series E0$i.mkv'),
    ];
  }

  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  fail('Cache clearing or automatic directory reload did not complete.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'model clears disk caches once without enumerating UI database',
    () async {
      final root = await Directory.systemTemp.createTemp('model-cache-clear-');
      final store = _Store('${root.path}/library.db');
      final model = AppModel(store, root, backgroundWork: false);
      try {
        store.save('media', 'one', {'title': 'Series', 'bangumiId': '42'});
        store.save('progress', 'one', {'position': 88});
        store.setLocal('manualMetadata:one', true);
        store.setLocal('catalog-v1:old', {'data': 'stale'});
        store.setLocal('preview:one', {
          'path': '${root.path}/previews/one.jpg',
        });
        await Directory('${root.path}/previews').create();
        await File('${root.path}/previews/one.jpg').writeAsString('preview');
        await Directory('${root.path}/poster-cache-v1').create();
        await File(
          '${root.path}/poster-cache-v1/old.img',
        ).writeAsString('poster');
        final first = model.clearCaches();
        expect(model.clearingCaches, isTrue);
        expect(identical(first, model.clearCaches()), isTrue);
        await first;
        expect(model.clearingCaches, isFalse);
        expect(store.enumerations, 0);
        expect(store.local('cacheClearEpoch'), 1);
        expect(store.local('catalog-v1:old'), isNull);
        expect(store.local('preview:one'), isNull);
        expect(store.get('media', 'one')!.data['bangumiId'], '42');
        expect(store.get('progress', 'one')!.data['position'], 88);
        expect(store.local('manualMetadata:one'), isTrue);
        expect(await Directory('${root.path}/previews').exists(), isFalse);
        expect(
          await Directory('${root.path}/poster-cache-v1').list().isEmpty,
          isTrue,
        );
        expect(model.catalog.cacheMaintenance, isFalse);
        await model.clearCaches();
        expect(store.local('cacheClearEpoch'), 2);
      } finally {
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('clearing resumes recognition queued before its debounce', () async {
    final root = await Directory.systemTemp.createTemp('pending-cache-clear-');
    final store = AppStore('${root.path}/library.db');
    final model = _Model(store, root);
    try {
      final id = model.addMedia(
        'nas',
        const SourceEntry(
          name: 'Series E01.mkv',
          path: 'Series/Series E01.mkv',
        ),
      );
      await model.clearCaches();
      for (
        var i = 0;
        i < 100 && store.get('media', id)!.data['bangumiId'] == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.get('media', id)!.data['bangumiId'], '42');
    } finally {
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  });

  test(
    'disposal during a pending preview drain cannot update the model',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'disposed-cache-clear-',
      );
      final store = AppStore('${root.path}/library.db');
      final model = AppModel(store, root, backgroundWork: false);
      final pending = Completer<void>();
      model.trackPlaybackPreviewWork(pending.future);
      final clearing = model.clearCaches();
      final stopped = expectLater(clearing, throwsA(isA<Cancelled>()));
      model.dispose();
      pending.complete();
      await stopped;
      expect(model.clearingCaches, isFalse);
      store.dispose();
      await root.delete(recursive: true);
    },
  );

  testWidgets('retained source reloads listing and recognition after clear', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('source-cache-clear-'),
    ))!;
    final store = AppStore('${root.path}/library.db');
    final model = _Model(store, root);
    final active = ValueNotifier(true);
    var cleared = false;
    Object? failure;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, _) => SourceBrowser(
                model: model,
                source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
                initialPath: 'Series/',
                active: value,
                onPlay: (_) async {},
              ),
            ),
          ),
        ),
      );
      await _wait(
        tester,
        () =>
            model._trackedCatalog.resolves > 0 &&
            store.records('media').every((r) => r.data['bangumiId'] == '42'),
      );
      await tester.pumpAndSettle();
      expect(store.records('media'), hasLength(2));
      final reads = model.listings;
      final resolves = model._trackedCatalog.resolves;
      active.value = false;
      await tester.pump();
      model.episodes = 3;
      unawaited(
        model.clearCaches().then(
          (_) {
            cleared = true;
          },
          onError: (Object e) {
            failure = e;
            cleared = true;
          },
        ),
      );
      await _wait(tester, () => cleared);
      expect(failure, isNull);
      expect(model.listings, reads, reason: 'offscreen pages stay paused');
      active.value = true;
      await tester.pump();
      await _wait(
        tester,
        () =>
            model.listings > reads &&
            model._trackedCatalog.resolves > resolves &&
            store.records('media').length == 3 &&
            store.records('media').every((r) => r.data['episodeTitle'] != null),
      );
      expect(find.text('测试系列'), findsWidgets);
      expect(store.records('progress'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.pump(const Duration(seconds: 30));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        store.dispose();
        await root.delete(recursive: true);
      });
      active.dispose();
    }
  });
}
