import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectoryModel extends AppModel {
  int sourceOpens = 0, fileStats = 0, sourceCloses = 0;
  _DirectoryModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async {
    if (id != 'local') return super.adapter(id);
    sourceOpens++;
    return _ObservedLocalSource(this);
  }
}

class _ObservedLocalSource extends LocalSource {
  final _DirectoryModel model;
  _ObservedLocalSource(this.model);

  @override
  Future<SourceEntry> stat(String path) {
    model.fileStats++;
    return super.stat(path);
  }

  @override
  Future<void> close() async => model.sourceCloses++;
}

class _DirectoryFixture {
  final Directory root, folder;
  final AppStore store;
  final _DirectoryModel model;
  final String title;
  int plays = 0;

  _DirectoryFixture(this.root, this.folder, this.store, this.model, this.title);

  static Future<_DirectoryFixture> create(String title) async {
    final root = await Directory.systemTemp.createTemp('collection-header-');
    final folder = await Directory('${root.path}/Series').create();
    for (var episode = 1; episode <= 3; episode++) {
      await File('${folder.path}/$title S01E0$episode.mkv').writeAsBytes([1]);
    }
    final store = AppStore('${root.path}/library.db')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    return _DirectoryFixture(
      root,
      folder,
      store,
      _DirectoryModel(store, root),
      title,
    );
  }

  void seed(String id, String name, Map<String, dynamic> data) {
    store.save('media', id, {
      'title': name,
      'fileName': name,
      'size': 1,
      ...data,
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': 'local',
      'path': '${folder.path}/$name',
      'size': 1,
    });
  }

  Future<void> open(WidgetTester tester, int expectedRecords) async {
    await tester.runAsync(() => model.loadLibrarySnapshot());
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: SourceBrowser(
          model: model,
          source: const {'id': 'local', 'kind': 'local', 'label': 'Local'},
          initialPath: folder.path,
          onPlay: (_) async => plays++,
        ),
      ),
    );
    for (var attempt = 0; attempt < 250; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (store.records('media').length == expectedRecords) break;
    }
    expect(store.records('media'), hasLength(expectedRecords));
    // Wait for the real worker-prepared snapshot and its queued UI commits.
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final history in ['movie', 'other series']) {
    testWidgets(
      'current identified collection keeps its details despite historical $history in the same folder',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final fixture = (await tester.runAsync(
          () => _DirectoryFixture.create('Current'),
        ))!;
        try {
          fixture.seed('current-1', 'Current S01E01.mkv', {
            'series': 'Current',
            'season': '1',
            'episode': '1',
            'bangumiId': '7',
            'metadataTitle': '当前作品',
          });
          fixture.seed('historical', 'historical.mkv', {
            'series': 'Unrelated',
            'season': '1',
            if (history == 'movie') ...{
              'tmdbId': '99',
              'metadataType': 'movie',
            } else ...{
              'bangumiId': '99',
              'episode': '8',
            },
            'metadataTitle': '历史其他作品',
          });

          await fixture.open(tester, 4);
          expect(find.byType(MediaDetailsOverview), findsOneWidget);
          expect(find.textContaining('已收录 3 集'), findsOneWidget);
          expect(find.text('当前作品'), findsOneWidget);
          expect(find.text('历史其他作品'), findsNothing);
          expect(fixture.plays, 0);
          expect(fixture.store.records('progress'), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets('single-character series shows every episode on its first open', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = (await tester.runAsync(
      () => _DirectoryFixture.create('甲'),
    ))!;
    try {
      await fixture.open(tester, 3);
      expect(find.byType(MediaDetailsOverview), findsOneWidget);
      expect(find.textContaining('已收录 3 集'), findsOneWidget);
      final snapshot = (await tester.runAsync(
        () => fixture.model.loadLibrarySnapshot(),
      ))!;
      expect(snapshot.series.values.single, hasLength(3));
      expect(snapshot.details.values.single.availableEpisodes, 3);
      expect(fixture.plays, 0);
      expect(fixture.store.records('progress'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'source episode menu reads the current file only after selecting details',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = (await tester.runAsync(
        () => _DirectoryFixture.create('Current'),
      ))!;
      try {
        await fixture.open(tester, 3);
        final path = '${fixture.folder.path}/Current S01E01.mkv';
        final tile = find.byKey(ValueKey(path));
        expect(tester.widget(tile), isA<MediaDetailsEpisodeTile>());
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        final opens = fixture.model.sourceOpens;
        final stats = fixture.model.fileStats;
        final closes = fixture.model.sourceCloses;
        final mediaRevision = fixture.store.recordsRevision('media');
        final locationRevision = fixture.store.locationRevision;

        // The browser snapshot still describes a nonempty file. Inspecting it
        // must stat it again, detect the change, and avoid native demuxing.
        await tester.runAsync(() => File(path).writeAsBytes(const []));
        await tester.tap(
          find.descendant(of: tile, matching: find.byTooltip('视频选项')),
        );
        await tester.pumpAndSettle();
        expect(find.text('查看文件详情'), findsOneWidget);
        expect(fixture.model.sourceOpens, opens);
        expect(fixture.model.fileStats, stats);

        await tester.tap(find.text('查看文件详情'));
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.textContaining('无法读取文件信息').evaluate().isNotEmpty) break;
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('media-file-details')),
          findsOneWidget,
        );
        expect(find.textContaining('无法读取文件信息'), findsOneWidget);
        expect(fixture.model.sourceOpens, opens + 1);
        expect(fixture.model.fileStats, stats + 1);
        expect(fixture.model.sourceCloses, closes + 1);
        expect(fixture.store.recordsRevision('media'), mediaRevision);
        expect(fixture.store.locationRevision, locationRevision);
        expect(fixture.store.records('media'), hasLength(3));
        expect(fixture.store.records('progress'), isEmpty);
        expect(fixture.model.activePlaybackMediaId, isNull);
        expect(fixture.plays, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'conflicting subjects inside the current collection stay separate',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = (await tester.runAsync(
        () => _DirectoryFixture.create('Current'),
      ))!;
      try {
        for (var episode = 1; episode <= 2; episode++) {
          fixture.seed('current-$episode', 'Current S01E0$episode.mkv', {
            'series': 'Current',
            'season': '1',
            'episode': '$episode',
            'bangumiId': '${episode + 6}',
          });
        }
        await fixture.open(tester, 3);
        expect(find.byType(MediaDetailsOverview), findsNothing);
        expect(fixture.store.get('media', 'current-1')!.data['bangumiId'], '7');
        expect(fixture.store.get('media', 'current-2')!.data['bangumiId'], '8');
        expect(fixture.plays, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}
