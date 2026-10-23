import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _ListModel extends AppModel {
  _ListModel(super.store, super.documents) : super(backgroundWork: false);

  final frames = <String, String>{};
  final previews = <String>{};
  final records = <SyncRecord>[];
  final entries = <SourceEntry>[];
  bool folders = false;

  @override
  String? thumbnailPath(String id) => frames[id];

  @override
  Future<bool> needsMediaPreview(String id) async => true;

  @override
  void ensureMediaPreview(String id) => previews.add(id);

  @override
  String ensureSourceMediaPreview(String sourceId, SourceEntry entry) {
    final id = sourcePreviewId(sourceId, entry.path);
    previews.add(id);
    return id;
  }

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async => records;

  @override
  Future<SourceAdapter> adapter(String id) async => _ListAdapter(entries);

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async => folders ? null : identifyDirectory(path, entries);

  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async => value;
}

class _ListAdapter extends SourceAdapter {
  _ListAdapter(this.entries);
  final List<SourceEntry> entries;
  @override
  Future<List<SourceEntry>> list(String path) async => entries;
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

Finder _artwork(String image) => find.byWidgetPredicate(
  (widget) =>
      widget is MediaArtwork &&
      (widget.thumbnail == image || widget.poster == image),
  skipOffstage: false,
);

bool _decoded(Finder artwork) => find
    .descendant(
      of: artwork,
      matching: find.byType(RawImage, skipOffstage: false),
      skipOffstage: false,
    )
    .evaluate()
    .any((element) => (element.widget as RawImage).image != null);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String failure,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail(failure);
}

Future<String> _assertNextCoverReady(
  WidgetTester tester,
  Finder list,
  _ListModel model,
) async {
  final viewport = tester.getRect(list);
  Finder cover(String image) =>
      find.descendant(of: list, matching: _artwork(image), skipOffstage: false);
  final candidates = tester.widgetList<MediaArtwork>(
    find.descendant(
      of: list,
      matching: find.byType(MediaArtwork, skipOffstage: false),
      skipOffstage: false,
    ),
  );
  final next = candidates.firstWhere((artwork) {
    final image = artwork.thumbnail ?? artwork.poster;
    if (image.isEmpty) return false;
    final bounds = tester.getRect(cover(image));
    return bounds.top >= viewport.bottom &&
        bounds.top < viewport.bottom + viewport.height * .5;
  });
  final image = next.thumbnail ?? next.poster;
  final target = cover(image);
  await _waitFor(
    tester,
    () => _decoded(target),
    'The next list cover must be decoded before entering the viewport.',
  );
  final before = model.previews.toSet();
  final position = tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      )
      .position;
  position.jumpTo(
    position.pixels + tester.getRect(target).top - viewport.bottom + 90,
  );
  // The first newly visible layout/paint has actual pixels, without waiting
  // for scroll idle, IO, or the native image decoder after entry.
  await tester.pump();
  expect(tester.getRect(target).overlaps(viewport), isTrue);
  expect(_decoded(target), isTrue);
  expect(model.previews, before);
  await tester.pump(const Duration(milliseconds: 150));
  return image;
}

void main() {
  late Directory directory;
  late AppStore store;
  late _ListModel model;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    directory = await Directory.systemTemp.createTemp('list-artwork-');
    store = AppStore(
      ':memory:',
    )..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
    model = _ListModel(store, directory);
  });

  tearDown(() async {
    model.dispose();
    await model.sync.dispose();
    store.dispose();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await directory.delete(recursive: true);
  });

  Future<void> seed(WidgetTester tester, {String source = 'nas'}) async {
    await tester.runAsync(() async {
      final bytes = images.encodePng(images.Image(width: 96, height: 64));
      for (var index = 1; index <= 80; index++) {
        final episode = index.toString().padLeft(3, '0');
        final entry = SourceEntry(
          name: 'Example S01E$episode.mp4',
          path: 'Example/Example S01E$episode.mp4',
          size: 1024,
        );
        model.entries.add(entry);
        final id = model.addMedia(source, entry);
        final record = store.get('media', id)!;
        store.save('media', id, {
          ...record.data,
          'series': 'Example',
          'season': '1',
          'episode': '$index',
          'bangumiId': '123',
          'metadataTitle': 'Example',
        });
        model.records.add(store.get('media', id)!);
        final file = File('${directory.path}/$episode.png');
        await file.writeAsBytes(bytes);
        model.frames[id] = file.path;
      }
    });
  }

  Future<void> mount(WidgetTester tester, Widget child) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      // Native decodes cannot be interrupted. Let their completion callbacks
      // release the shared queue before this test's fake async zone closes.
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    });
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Scaffold(body: GlassBackground(child: child)),
      ),
    );
    await _waitFor(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      'List loading did not complete.',
    );
    await tester.pumpAndSettle();
  }

  testWidgets('library episode covers are ready before their first frame', (
    tester,
  ) async {
    await seed(tester);
    await mount(tester, LibraryPage(model: model));
    await _waitFor(
      tester,
      () => _decoded(_artwork(model.frames[model.records.first.id]!)),
      'Library cover did not decode.',
    );
    await tester.tap(find.byKey(ValueKey('details:${model.records.first.id}')));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('series-details-list'));
    final image = await _assertNextCoverReady(tester, list, model);
    expect(
      model.previews,
      contains(model.frames.entries.firstWhere((e) => e.value == image).key),
    );
    expect(
      find.byType(MediaDetailsEpisodeTile).evaluate().length,
      lessThan(30),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('source episode covers prepare the next visible rows', (
    tester,
  ) async {
    await seed(tester);
    await mount(
      tester,
      SourceBrowser(
        model: model,
        source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
        initialPath: 'Example',
      ),
    );
    expect(find.byType(MediaDetailsOverview), findsOneWidget);
    final image = await _assertNextCoverReady(
      tester,
      find.byType(ListView),
      model,
    );
    expect(
      model.previews,
      contains(model.frames.entries.firstWhere((e) => e.value == image).key),
    );
    expect(
      find.byType(MediaDetailsEpisodeTile).evaluate().length,
      lessThan(30),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('local file covers prepare the next visible rows', (
    tester,
  ) async {
    await seed(tester, source: 'local');
    await mount(
      tester,
      SourcesPage(model: model, onImport: () async {}, onPlay: (_) async {}),
    );
    await tester.tap(find.text('本地视频').first);
    await tester.pumpAndSettle();
    await _assertNextCoverReady(tester, find.byType(ListView), model);
    expect(find.byType(MediaArtwork).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('folder posters prepare the next visible rows from disk cache', (
    tester,
  ) async {
    model.folders = true;
    await tester.runAsync(() async {
      final bytes = images.encodePng(images.Image(width: 96, height: 64));
      for (var index = 1; index <= 80; index++) {
        final folder = 'Series ${index.toString().padLeft(3, '0')}';
        model.entries.add(
          SourceEntry(name: folder, path: folder, directory: true),
        );
        final id = model.addMedia(
          'nas',
          SourceEntry(
            name: '$folder S01E01.mp4',
            path: '$folder/$folder S01E01.mp4',
          ),
        );
        final poster = 'https://example.com/folder-$index.png';
        final record = store.get('media', id)!;
        store.save('media', id, {
          ...record.data,
          'bangumiId': '$index',
          'metadataTitle': folder,
          'poster': poster,
        });
        final file = model.posterCache.cachedFile(poster);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
    });
    await mount(
      tester,
      SourceBrowser(
        model: model,
        source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
      ),
    );
    expect(find.byType(MediaDetailsOverview), findsNothing);
    await _assertNextCoverReady(tester, find.byType(ListView), model);
    expect(find.byType(MediaArtwork).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hidden local lists pause cold covers and resume at the saved offset',
    (tester) async {
      await seed(tester, source: 'local');
      var active = true;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return TickerMode(
              enabled: active,
              child: SourcesPage(
                model: model,
                active: active,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            );
          },
        ),
      );
      await tester.tap(find.text('本地视频').first);
      await tester.pumpAndSettle();
      final first = model.frames[model.records.first.id]!;
      await _waitFor(
        tester,
        () => _decoded(_artwork(first)),
        'Initial file cover did not decode.',
      );
      update(() => active = false);
      await tester.pump();
      final before = model.previews.toSet();
      final list = find.byType(ListView);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(2000);
      await tester.pump();
      final viewport = tester.getRect(list);
      final cold = tester
          .widgetList<MediaArtwork>(find.byType(MediaArtwork))
          .firstWhere(
            (artwork) =>
                tester.getRect(_artwork(artwork.thumbnail!)).overlaps(viewport),
          )
          .thumbnail!;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(_decoded(_artwork(cold)), isFalse);
      expect(model.previews, before);
      update(() => active = true);
      await tester.pump(const Duration(milliseconds: 150));
      await _waitFor(
        tester,
        () => _decoded(_artwork(cold)),
        'Returning to the list must resume cover loading.',
      );
      expect(position.pixels, 2000);
      position.jumpTo(0);
      await tester.pump();
      expect(
        _decoded(_artwork(first)),
        isTrue,
        reason:
            'Reverse scrolling reuses the resident decoded cover on its first frame.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
