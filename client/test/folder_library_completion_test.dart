import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _videos = [
  const SourceEntry(
    name: 'Example S01E01.mkv',
    path: 'Series/Example S01E01.mkv',
  ),
  const SourceEntry(
    name: 'Example S01E02.mkv',
    path: 'Series/Example S01E02.mkv',
  ),
];
final _collection = identifyDirectory('Series', _videos)!.withMetadata(
  {'id': 7, 'name_cn': '已识别作品', 'summary': '完整的系列简介', 'total_episodes': 12},
  {'1': '初次相逢', '2': '再次重逢'},
);

class _CachedCatalog extends LibraryCatalog {
  _CachedCatalog(super.store) : super(strategy: () => 'off');
  @override
  DirectoryPreview? directoryPreview(
    String sourceId,
    String path, {
    int? modified,
    bool allowStale = false,
  }) => path == 'Series'
      ? DirectoryPreview(
          collection: _collection,
          context: '',
          fingerprint: '',
          updatedAt: 0,
          modified: 0,
        )
      : null;
  @override
  Future<DirectoryCollection?> inspect(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    int? directoryModified,
    CancelToken? cancel,
  }) async => path == 'Series' ? _collection : null;
}

class _OfflineSeries extends SourceAdapter {
  int seriesReads = 0;
  @override
  Future<List<SourceEntry>> list(String path) async {
    if (path.isEmpty) {
      return [
        const SourceEntry(name: 'Series', path: 'Series', directory: true),
      ];
    }
    seriesReads++;
    throw const AppFailure('offline');
  }

  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _CachedModel extends AppModel {
  _CachedModel(super.store, super.documents) : super(backgroundWork: false);
  final source = _OfflineSeries();
  @override
  LibraryCatalog get catalog => _catalog;
  late final LibraryCatalog _catalog = _CachedCatalog(store);
  @override
  Future<SourceAdapter> adapter(String id) async => source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _CachedModel model;
  setUp(() {
    root = Directory.systemTemp.createTempSync('folder-library-completion-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _CachedModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'old library details recover every cached episode while source is offline',
    () async {
      final id = model.addMedia('nas', _videos.first);
      final episodes = await model.loadSeriesEpisodes(store.get('media', id)!);
      expect(episodes.map((record) => record.data['episode']), ['1', '2']);
      expect(episodes.map((record) => record.data['episodeTitle']), [
        '初次相逢',
        '再次重逢',
      ]);
      expect(
        episodes.every((record) => record.data['summary'] == '完整的系列简介'),
        isTrue,
      );
      expect(store.records('progress'), isEmpty);
      expect(model.source.seriesReads, 1);
    },
  );

  testWidgets(
    'cached parent folder imports unplayed episodes without entering or playing',
    (tester) async {
      model.addMedia('nas', _videos.first);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: SourceBrowser(
            model: model,
            source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.media, hasLength(2));
      expect(
        model.media.every((record) => record.data['bangumiId'] == '7'),
        isTrue,
      );
      expect(
        model.source.seriesReads,
        0,
        reason: 'the cached series already contains all episode paths',
      );
      expect(store.records('progress'), isEmpty);

      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: LibraryPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      final first = model.media.first;
      await tester.tap(find.byKey(ValueKey('details:${first.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已收录 2 集'), findsOneWidget);
      expect(find.textContaining('再次重逢'), findsWidgets);
      expect(find.textContaining('完整的系列简介'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
