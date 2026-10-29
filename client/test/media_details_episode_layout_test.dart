import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _EpisodeModel extends AppModel {
  final frames = <String, String>{};
  final frameReads = <String, int>{};
  final requests = <String>{};
  final entries = const [
    SourceEntry(
      name: 'Example S01E01.mkv',
      path: 'Example/Example S01E01.mkv',
      size: 100,
    ),
    SourceEntry(
      name: 'Example S01E02.mkv',
      path: 'Example/Example S01E02.mkv',
      size: 200,
    ),
  ];
  _EpisodeModel(super.store, super.documents);

  @override
  String? thumbnailPath(String id) {
    frameReads.update(id, (value) => value + 1, ifAbsent: () => 1);
    return frames[id];
  }

  @override
  void ensureMediaPreview(String id) => requests.add(id);

  @override
  String ensureSourceMediaPreview(String sourceId, SourceEntry entry) {
    final id = sourcePreviewId(sourceId, entry.path);
    requests.add(id);
    return id;
  }

  @override
  Future<SourceAdapter> adapter(String id) async => _EpisodeAdapter(entries);

  // Hold the listing at the pre-import state to cover a partially imported
  // directory while recognition is still running or the source is offline.
  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async => value;

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async => identifyDirectory(path, entries);
}

class _EpisodeAdapter extends SourceAdapter {
  final List<SourceEntry> entries;
  _EpisodeAdapter(this.entries);
  @override
  Future<List<SourceEntry>> list(String path) async => entries;
  @override
  Future<SourceEntry> stat(String path) async => entries.first;
  @override
  Stream<List<int>> read(String path, int offset, int length) =>
      const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _EpisodeModel model;
  setUpAll(() async {
    await Future.wait([
      (FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load(),
      (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load(),
    ]);
  });
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('details-episode-layout-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _EpisodeModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'known and unplayed source episodes use one aligned row and overview',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = model.addMedia('nas', model.entries.first);
      final second = model.sourcePreviewId('nas', model.entries.last.path);
      final frameSource = Platform.environment['DETAILS_EPISODE_FRAME'];
      final frame = frameSource == null
          ? (File('${root.path}/episode-frame.png')..writeAsBytesSync(
              images.encodePng(images.Image(width: 64, height: 44)),
            ))
          : File(frameSource);
      model.frames[first] = frame.path;
      if (Platform.environment['DETAILS_EPISODE_PREVIEW_PATH'] != null) {
        await tester.runAsync(() async {
          final ready = Completer<ImageInfo>();
          final stream = artworkImage(
            frame,
            64,
          ).resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (image, _) => ready.complete(image),
            onError: (Object error, StackTrace? trace) =>
                ready.completeError(error, trace),
          );
          stream.addListener(listener);
          final image = await ready.future;
          stream.removeListener(listener);
          image.dispose();
        });
      }
      store.setLocal('episodeTitle:$first', '这是需要换行显示的长剧集标题，播放过的剧集仍然使用同一列宽');
      final record = store.get('media', first)!;
      store.save('media', first, {
        ...record.data,
        'bangumiId': '7',
        'metadataTitle': '魔术师与伙伴们的旅途',
        'rating': 7.5,
        'totalEpisodes': 12,
        'airDate': '2026-10-01',
        'summary': '年轻的魔术师和伙伴们一起踏上新的旅途。面对接踵而来的挑战，他们逐渐学会彼此信任，也发现了隐藏在平凡生活中的勇气。',
      });
      store.save('progress', model.progressKey(record), {
        'position': 53,
        'duration': 1455,
        'updatedAt': '2026-10-23T07:20:00Z',
      });
      final boundary = GlobalKey();
      String? played;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: RepaintBoundary(
            key: boundary,
            child: SourceBrowser(
              model: model,
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
              initialPath: 'Example',
              onPlay: (record) async => played = record.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaDetailsOverview), findsOneWidget);
      expect(find.byTooltip('选择下载'), findsOneWidget);
      expect(find.byTooltip('下载视频'), findsNothing);
      final rows = find.byType(MediaDetailsEpisodeTile);
      expect(rows, findsNWidgets(2));
      expect(model.media, hasLength(1));
      final titles = find.byKey(const ValueKey('episode-title'));
      final thumbs = find.byKey(const ValueKey('episode-thumbnail'));
      final actions = find.byKey(const ValueKey('episode-action'));
      expect(
        tester.getRect(titles.at(0)).left,
        tester.getRect(titles.at(1)).left,
      );
      expect(
        tester.getRect(titles.at(0)).right,
        tester.getRect(titles.at(1)).right,
      );
      expect(tester.getRect(thumbs.at(0)).size, const Size(64, 44));
      expect(tester.getRect(thumbs.at(1)).size, const Size(64, 44));
      expect(
        tester.getRect(actions.at(0)).left,
        tester.getRect(actions.at(1)).left,
      );
      expect(model.requests, containsAll([first, second]));
      for (final row in rows.evaluate()) {
        final artwork = tester.widget<MediaArtwork>(
          find.descendant(
            of: find.byWidget(row.widget),
            matching: find.byType(MediaArtwork),
          ),
        );
        expect(
          artwork.poster,
          isEmpty,
          reason: 'episodes use video frames, not the series poster',
        );
      }
      final rowArtwork = tester
          .widgetList<MediaArtwork>(
            find.descendant(of: rows, matching: find.byType(MediaArtwork)),
          )
          .toList();
      expect(rowArtwork.first.thumbnail, frame.path);
      expect(rowArtwork.last.thumbnail, isNull);
      expect(tester.takeException(), isNull);
      final preview = Platform.environment['DETAILS_EPISODE_PREVIEW_PATH'];
      if (preview != null) {
        // Let the file read and codec started by Image complete outside the
        // widget test's fake clock before capturing the painted frame.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(preview);
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.tap(find.byKey(ValueKey(model.entries.first.path)));
      await tester.pumpAndSettle();
      expect(played, first);
      await tester.tap(find.byTooltip('视频选项').first);
      await tester.pumpAndSettle();
      expect(find.text('手动搜索影视资料'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(model.entries.last.path)));
      await tester.pumpAndSettle();
      expect(played, model.sourceMedia('nas', model.entries.last.path)!.id);
      expect(
        played,
        isNot(second),
        reason: 'playing imports the formerly unplayed entry',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a frame completion refreshes only the changed episode', (
    tester,
  ) async {
    final ids = [
      for (final entry in model.entries) model.addMedia('nas', entry),
    ];
    final records = [for (final id in ids) store.get('media', id)!];
    store.save('progress', model.progressKey(records.last), {'position': 30});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final record in records)
                MediaDetailsEpisodeTile(
                  model: model,
                  item: record,
                  onPlay: () {},
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    model.frameReads.clear();
    store.setLocal('preview:${ids.first}', {'revision': 1});
    model.changed();
    await tester.pumpAndSettle();
    expect(model.frameReads, {ids.first: 1});
    model.frameReads.clear();
    model.changed();
    await tester.pumpAndSettle();
    expect(model.frameReads, isEmpty);

    // A probe can discover dimensions/duration without publishing a new frame
    // or changing the technical-info cache. Only that episode should refresh.
    final previewRevision = store.localPrefixRevision('preview:');
    final technicalRevision = store.localPrefixRevision('technical:');
    model.recordMediaMetadata(
      ids.last,
      duration: 90,
      width: 1920,
      height: 1080,
    );
    model.changed();
    await tester.pumpAndSettle();
    expect(store.localPrefixRevision('preview:'), previewRevision);
    expect(store.localPrefixRevision('technical:'), technicalRevision);
    expect(model.frameReads, {ids.last: 1});
    final lastRow = find.byType(MediaDetailsEpisodeTile).last;
    expect(
      find.descendant(
        of: lastRow,
        matching: find.textContaining('1920 × 1080'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lastRow, matching: find.textContaining('01:30')),
      findsOneWidget,
    );
    model.frameReads.clear();
    model.changed();
    await tester.pumpAndSettle();
    expect(model.frameReads, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden episode updates coalesce until it becomes visible', (
    tester,
  ) async {
    final id = model.addMedia('nas', model.entries.first);
    final row = MediaDetailsEpisodeTile(
      model: model,
      item: store.get('media', id)!,
      onPlay: () {},
    );
    Future<void> mount(bool active) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TickerMode(enabled: active, child: row),
        ),
      ),
    );
    await mount(true);
    await tester.pumpAndSettle();
    await mount(false);
    model.frameReads.clear();
    for (var i = 1; i <= 3; i++) {
      store.setLocal('preview:$id', {'revision': i});
      model.changed();
    }
    await tester.pumpAndSettle();
    expect(model.frameReads, isEmpty);
    await mount(true);
    await tester.pumpAndSettle();
    expect(model.frameReads, {id: 1});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
