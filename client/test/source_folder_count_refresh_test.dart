import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/directory_preview_context.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<SourceEntry> _episodes(String folder, int count) => [
  for (var episode = 1; episode <= count; episode++)
    SourceEntry(
      name: 'Example S01E${episode.toString().padLeft(2, '0')}.mkv',
      path: '$folder/Example S01E${episode.toString().padLeft(2, '0')}.mkv',
    ),
];

class _CatalogTransport implements JsonTransport {
  static const subject = {
    'id': 7,
    'type': 2,
    'name': 'Example',
    'name_cn': '至高之力',
    'platform': 'TV',
    'images': {'large': 'https://posters.invalid/example.jpg'},
  };

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (uri.path.startsWith('/search/subject/')) {
      return {
        'list': [subject],
      };
    }
    if (uri.path == '/v0/episodes') {
      return {
        'data': [
          for (var episode = 1; episode <= 20; episode++)
            {'sort': episode, 'name_cn': '第 $episode 集'},
        ],
      };
    }
    return subject;
  }
}

// A valid poster URL with no failed download must not suppress directory work.
// Keep image I/O out of this source-listing regression.
class _PosterCache extends PosterCache {
  _PosterCache({required super.directory});

  @override
  Future<File?>? loadVisible(String url, {bool Function()? canStart}) =>
      Future.value();

  @override
  Future<File?>? loadNearby(String url, {bool Function()? canStart}) =>
      Future.value();
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);

  final counts = <String, int>{'Series': 3};
  final gates = <String, Completer<List<SourceEntry>>>{};
  final requests = <String>[];
  int activeRequests = 0, maxActiveRequests = 0;
  int completedCollections = 0;

  @override
  LibraryCatalog get catalog => _catalog;
  late final _catalog = LibraryCatalog(
    store,
    transport: _CatalogTransport(),
    strategy: () => preferences.metadataStrategy,
  );

  @override
  PosterCache get posterCache => _posterCache;
  late final _posterCache = _PosterCache(directory: documents);

  @override
  Future<SourceAdapter> adapter(String id) async => _Connection(this);

  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final result = await super.synchronizeCollectionInBackground(
      sourceId,
      value,
      importMissing: importMissing,
      anchorId: anchorId,
      cancel: cancel,
    );
    completedCollections++;
    return result;
  }

  @override
  void dispose() {
    _posterCache.close();
    super.dispose();
  }
}

class _Connection extends SourceAdapter {
  _Connection(this.owner);
  final _Model owner;
  bool reading = false;

  @override
  Future<List<SourceEntry>> list(String path) async {
    owner.requests.add(path);
    owner.activeRequests++;
    if (owner.activeRequests > owner.maxActiveRequests) {
      owner.maxActiveRequests = owner.activeRequests;
    }
    reading = true;
    try {
      final pending = owner.gates[path];
      if (pending != null) return await pending.future;
      if (path.isEmpty) {
        return [
          for (final name in owner.counts.keys)
            SourceEntry(
              name: name,
              path: name,
              directory: true,
              // Many WebDAV servers keep this unchanged when files are added.
              modified: 100,
            ),
        ];
      }
      return _episodes(path, owner.counts[path] ?? 0);
    } finally {
      if (reading) owner.activeRequests--;
      reading = false;
    }
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();

  @override
  Future<void> close() async {
    if (reading) owner.activeRequests--;
    reading = false;
  }
}

Widget _browser(_Model model) => MaterialApp(
  home: SourceBrowser(
    model: model,
    source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
  ),
);

Future<void> _settle(WidgetTester tester, bool Function() complete) async {
  // Folder summaries run on the directory worker; no pending Flutter frame
  // does not mean that the real isolate has returned its result yet.
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (complete()) return;
  }
  fail('Source listing and its background folder counts did not settle.');
}

Future<void> _refresh(WidgetTester tester, bool Function() complete) async {
  final refresh = tester
      .widget<RefreshIndicator>(find.byType(RefreshIndicator))
      .onRefresh();
  await _settle(tester, complete);
  await refresh;
  await tester.pumpAndSettle();
}

Future<void> _seedRecognizedPreview(_Model model, String path) async {
  final context = directoryPreviewContext(
    source: null,
    strategy: model.preferences.metadataStrategy,
    aiContext: '',
  );
  final prepared = prepareDirectoryInspection(
    'nas',
    path,
    context,
    _episodes(path, 3),
  );
  persistDirectoryPreview(
    model.store,
    'nas',
    path,
    DirectoryPreview(
      collection: prepared.collection!.withMetadata(
        _CatalogTransport.subject,
        const {},
      ),
      context: context,
      fingerprint: prepared.fingerprint,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      modified: 100,
    ),
  );
  model.catalog.reloadSyncedDirectoryPreviews();
}

void main() {
  testWidgets(
    'cached poster counts revalidate on entry and unchanged parent refresh',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('folder-count-');
      final store = AppStore(':memory:');
      final model = _Model(store, root);
      try {
        await model.catalog.inspect(
          'nas',
          'Series',
          _episodes('Series', 3),
          directoryModified: 100,
        );
        expect(
          model.catalog.directoryPreview('nas', 'Series')!.collection!.poster,
          isNotEmpty,
        );
        model.counts['Series'] = 4;
        await tester.pumpWidget(_browser(model));
        await _settle(tester, () => find.text('4 集').evaluate().length == 1);
        expect(find.text('4 集'), findsOneWidget);
        expect(model.requests.where((path) => path == 'Series'), hasLength(1));
        expect(model.media, isEmpty);

        for (final count in [2, 5]) {
          model.counts['Series'] = count;
          final before = model.requests.length;
          await _refresh(
            tester,
            () => find.text('$count 集').evaluate().length == 1,
          );
          expect(find.text('$count 集'), findsOneWidget);
          expect(model.requests.skip(before), ['', 'Series']);
          expect(model.media, isEmpty);
        }

        final requests = model.requests.length;
        await tester.pump(const Duration(minutes: 10));
        await tester.pumpAndSettle();
        expect(model.requests, hasLength(requests));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('concurrent parent refreshes share the same child count read', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('folder-count-coalesce-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _Model(store, root);
    final pending = Completer<List<SourceEntry>>();
    try {
      await _seedRecognizedPreview(model, 'Series');
      await tester.pumpWidget(_browser(model));
      await _settle(
        tester,
        () =>
            model.completedCollections >= 1 &&
            find.text('3 集').evaluate().length == 1,
      );
      expect(find.text('3 集'), findsOneWidget);
      model.gates[''] = pending;
      model.counts['Series'] = 4;
      final before = model.requests.length;
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh;
      final first = refresh();
      final second = refresh();
      expect(identical(first, second), isTrue);
      await tester.pump();
      expect(model.requests.skip(before), ['']);
      pending.complete(const [
        SourceEntry(
          name: 'Series',
          path: 'Series',
          directory: true,
          modified: 100,
        ),
      ]);
      await _settle(tester, () => find.text('4 集').evaluate().length == 1);
      await first;
      expect(find.text('4 集'), findsOneWidget);
      expect(model.requests.skip(before), ['', 'Series']);
      expect(model.media, isEmpty);
    } finally {
      if (!pending.isCompleted) pending.complete([]);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'an emptied folder stays empty when an old library snapshot changes',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('folder-count-empty-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _Model(store, root);
      try {
        await _seedRecognizedPreview(model, 'Series');
        await tester.pumpWidget(_browser(model));
        await _settle(
          tester,
          () =>
              model.completedCollections >= 1 &&
              find.text('3 集').evaluate().length == 1,
        );
        await tester.tap(find.byKey(const ValueKey('Series')));
        await _settle(
          tester,
          () =>
              model.media.length == 3 &&
              find.textContaining('已收录 3 集').evaluate().length == 1,
        );
        expect(model.media, hasLength(3));
        expect(find.textContaining('已收录 3 集'), findsOneWidget);
        final beforeReturn = model.completedCollections;
        await tester.tap(find.byTooltip('返回'));
        await _settle(
          tester,
          () =>
              model.completedCollections > beforeReturn &&
              find.text('3 集').evaluate().length == 1,
        );
        expect(find.text('3 集'), findsOneWidget);

        model.counts['Series'] = 0;
        await _refresh(
          tester,
          () =>
              find.text('3 集').evaluate().isEmpty &&
              find.text('Series').evaluate().length == 1,
        );
        expect(find.text('3 集'), findsNothing);
        expect(find.text('Series'), findsOneWidget);

        // Existing imported records can outlive files removed on the source.
        // A genuine new snapshot must not restore their obsolete folder count.
        final record = model.media.first;
        store.save('media', record.id, {
          ...record.data,
          'episodeTitle': 'Updated episode title',
        });
        model.changed();
        await tester.pumpAndSettle();
        expect(find.text('3 集'), findsNothing);
        expect(find.text('Series'), findsOneWidget);

        model.counts['Series'] = 4;
        await _refresh(tester, () => find.text('4 集').evaluate().length == 1);
        expect(find.text('4 集'), findsOneWidget);
        expect(model.media, hasLength(3));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'paused count revalidation stops without frames and ignores late listings',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('folder-count-pause-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _Model(store, root)
        ..counts.clear()
        ..counts.addAll({
          for (var folder = 1; folder <= 8; folder++) 'Series$folder': 3,
        });
      final pending = {
        for (final path in model.counts.keys)
          path: Completer<List<SourceEntry>>(),
      };
      try {
        for (final path in model.counts.keys) {
          await _seedRecognizedPreview(model, path);
        }
        await tester.pumpWidget(_browser(model));
        await _settle(
          tester,
          () =>
              model.completedCollections >= 8 &&
              find.text('3 集').evaluate().length == 8,
        );
        expect(find.text('3 集'), findsNWidgets(8));
        model.gates.addAll(pending);
        final refresh = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await _settle(tester, () => model.activeRequests == 4);
        expect(model.activeRequests, 4);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.idle();
        expect(model.activeRequests, 0);
        final pausedRequests = model.requests.length;
        for (final entry in pending.entries) {
          entry.value.complete(_episodes(entry.key, 9));
          model.counts[entry.key] = 4;
        }
        model.gates.clear();
        await tester.idle();
        expect(model.requests, hasLength(pausedRequests));
        expect(find.text('3 集'), findsNWidgets(8));
        await refresh;

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _settle(tester, () => find.text('4 集').evaluate().length == 8);
        expect(find.text('4 集'), findsNWidgets(8));
        expect(find.text('9 集'), findsNothing);
        expect(model.maxActiveRequests, lessThanOrEqualTo(4));
        expect(model.media, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        for (final gate in pending.values) {
          if (!gate.isCompleted) gate.complete([]);
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );
}
