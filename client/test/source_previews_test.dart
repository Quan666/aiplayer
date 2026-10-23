import 'package:aiplayer/ui/media_artwork.dart';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'identified favorites use their poster and preserve their return boundary',
    (tester) async {
      final fixture = _Fixture();
      await fixture.model.catalog.inspect(
        'nas',
        '0/',
        _files(0),
        directoryModified: 7,
      );
      SourceFavorites(
        fixture.store,
      ).toggle(const SourceFavorite(sourceId: 'nas', path: '0/', name: '收藏作品'));
      try {
        await fixture.mount(tester);
        final favorite = find.byKey(const ValueKey('favorite:nas\u00000'));
        expect(favorite, findsOneWidget);
        expect(_posters(tester, favorite), ['https://posters.example/作品甲.jpg']);
        await tester.tap(find.text('收藏作品'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('返回'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        final ids = fixture.model.media.map((record) => record.id).toSet();
        fixture.model.applyBangumi(
          '作品甲',
          {
            'id': 999,
            'name_cn': '手动匹配作品',
            'images': {'large': 'https://posters.example/manual.jpg'},
          },
          mediaIds: ids,
          manual: true,
        );
        fixture.model.changed();
        await tester.pumpAndSettle();
        expect(_posters(tester, favorite), [
          'https://posters.example/manual.jpg',
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets(
    'reopening a directory restores every cached child poster in the first listing frame',
    (tester) async {
      final fixture = _Fixture();
      try {
        await fixture.mount(tester);
        await tester.tap(find.text('NAS'));
        await tester.pumpAndSettle();
        expect(_posters(tester), hasLength(4));
        expect(fixture.model.childReads, 4);
        expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
        final calls = fixture.model.childReads;
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('NAS'));
        await tester.pump();
        await tester.pump();
        expect(_posters(tester).toSet(), {
          for (final name in _names) 'https://posters.example/$name.jpg',
        });
        expect(fixture.model.childReads, calls);
        await tester.pumpAndSettle();
        expect(fixture.model.childReads, calls);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  test(
    'directory previews survive catalog recreation and invalidate on content, source and preferences',
    () async {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      store.setLocal('sources', [
        {'id': 'nas', 'kind': 'webdav', 'url': 'https://old.example/'},
      ]);
      final catalog = _PreviewCatalog(store);
      final entries = _files(0);
      final first = await catalog.inspect(
        'nas',
        '0/',
        entries,
        directoryModified: 7,
      );
      expect(first!.poster, 'https://posters.example/作品甲.jpg');
      await catalog.inspect('nas', '0/', entries, directoryModified: 7);
      expect(catalog.resolutions, 1);
      final restored = _PreviewCatalog(store);
      expect(
        restored.directoryPreview('nas', '0/', modified: 7)!.collection!.poster,
        first.poster,
      );
      expect(restored.directoryPreview('nas', '0/', modified: 8), isNull);
      final replacement = [
        for (final entry in _files(1))
          SourceEntry(
            name: entry.name,
            path: entry.path.replaceFirst('1/', '0/'),
            size: entry.size,
            modified: 8,
          ),
      ];
      expect(
        (await restored.inspect(
          'nas',
          '0/',
          replacement,
          directoryModified: 8,
        ))!.title,
        '作品乙',
      );
      expect(restored.resolutions, 1);
      store.setLocal('sources', [
        {'id': 'nas', 'kind': 'webdav', 'url': 'https://new.example/'},
      ]);
      expect(restored.directoryPreview('nas', '0/', modified: 8), isNull);
      await restored.inspect('nas', '0/', replacement, directoryModified: 8);
      store.setLocal('settings', {'metadataStrategy': 'balanced'});
      expect(restored.directoryPreview('nas', '0/', modified: 8), isNull);
      await restored.inspect('nas', '0/', replacement, directoryModified: 8);
      restored.invalidateDirectoryPreviews('nas');
      expect(restored.directoryPreview('nas', '0/'), isNull);
      expect(store.localEntries('directory-preview:'), isEmpty);
    },
  );

  test(
    'old successful preview remains available until its directory identity changes',
    () async {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      final catalog = _PreviewCatalog(store);
      await catalog.inspect('nas', '0/', _files(0), directoryModified: 7);
      final entry = store.localEntries('directory-preview:').entries.single;
      store.setLocal(entry.key, {...entry.value as Map, 'at': 0});
      final restored = _PreviewCatalog(store);
      expect(restored.directoryPreview('nas', '0/', modified: 7), isNotNull);
      expect(
        restored
            .directoryPreview('nas', '0/', modified: 7, allowStale: true)!
            .collection!
            .poster,
        'https://posters.example/作品甲.jpg',
      );
      expect(restored.directoryPreview('nas', '0/', modified: 8), isNull);
    },
  );
}

const _names = ['作品甲', '作品乙', '作品丙', '作品丁'];
List<SourceEntry> _files(int index) => [
  for (var episode = 1; episode <= 2; episode++)
    SourceEntry(
      name: '${_names[index]} S01E0$episode.mkv',
      path: '$index/${_names[index]} S01E0$episode.mkv',
      size: 100,
      modified: 7,
    ),
];

List<String> _posters(WidgetTester tester, [Finder? scope]) {
  final artworks = scope == null
      ? find.byType(MediaArtwork)
      : find.descendant(of: scope, matching: find.byType(MediaArtwork));
  return tester
      .widgetList<MediaArtwork>(artworks)
      .map((artwork) => artwork.poster)
      .where((url) => url.isNotEmpty)
      .toList();
}

class _Fixture {
  final directory = Directory.systemTemp.createTempSync('aiplayer-preview-ui-');
  final store = AppStore(':memory:');
  late final model = _PreviewModel(store, directory);
  _Fixture() {
    store.setLocal('settings', {
      'metadataStrategy': 'conservative',
      'autoDiscover': false,
    });
    store.setLocal('sources', [
      {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
    ]);
  }
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Scaffold(
          body: SourcesPage(
            model: model,
            onImport: () async {},
            onPlay: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  }
}

class _PreviewCatalog extends LibraryCatalog {
  int resolutions = 0;
  _PreviewCatalog(super.store)
    : super(
        strategy: () =>
            (store.local('settings') as Map?)?['metadataStrategy'] ??
            'conservative',
      );
  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    resolutions++;
    return {
      'id': title.hashCode,
      'name_cn': title,
      'images': {'large': 'https://posters.example/$title.jpg'},
    };
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async => {};
}

class _PreviewModel extends AppModel {
  int childReads = 0;
  _PreviewModel(super.store, super.documents);
  late final _testCatalog = _PreviewCatalog(store);
  @override
  LibraryCatalog get catalog => _testCatalog;
  @override
  Future<SourceAdapter> adapter(String id) async => _PreviewAdapter(this);
}

class _PreviewAdapter extends SourceAdapter {
  final _PreviewModel model;
  _PreviewAdapter(this.model);
  @override
  Future<List<SourceEntry>> list(String path) async {
    if (path.isEmpty) {
      return [
        for (var i = 0; i < _names.length; i++)
          SourceEntry(
            name: _names[i],
            path: '$i/',
            directory: true,
            modified: 7,
          ),
      ];
    }
    model.childReads++;
    return _files(int.parse(path.split('/').first));
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}
