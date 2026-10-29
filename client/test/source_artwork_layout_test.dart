import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

const _series = SourceEntry(name: 'Series', path: 'Series', directory: true);
const _video = SourceEntry(name: 'Movie.mp4', path: 'Movie.mp4', size: 100);
const _episode = SourceEntry(
  name: 'Series S01E01.mkv',
  path: 'Series/Series S01E01.mkv',
  size: 100,
);
const _posterUrl = 'https://posters.invalid/portrait.png';

class _Transport implements JsonTransport {
  static const subject = {
    'id': 7,
    'type': 2,
    'name': 'Series',
    'name_cn': '已识别作品',
    'platform': 'TV',
    'images': {'large': _posterUrl},
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
          {'sort': 1, 'name_cn': '第一集'},
        ],
      };
    }
    return subject;
  }
}

class _PosterCache extends PosterCache {
  final File image;
  _PosterCache(Directory directory, this.image) : super(directory: directory);

  @override
  File? resolvedFile(String url) => image;

  @override
  Future<File?> loadVisible(String url) async => image;

  @override
  Future<File?> loadNearby(String url, {bool Function()? canStart}) async =>
      image;
}

class _Model extends AppModel {
  final String frame;
  final File poster;
  _Model(super.store, super.documents, this.frame, this.poster)
    : super(backgroundWork: false);

  @override
  LibraryCatalog get catalog => _catalog;
  late final _catalog = LibraryCatalog(
    store,
    transport: _Transport(),
    strategy: () => 'conservative',
  );

  @override
  PosterCache get posterCache => _posterCache;
  late final _posterCache = _PosterCache(documents, poster);

  @override
  String? thumbnailPath(String id) => frame;

  @override
  void ensureMediaPreview(String id) {}

  @override
  String ensureSourceMediaPreview(String sourceId, SourceEntry entry) =>
      sourcePreviewId(sourceId, entry.path);

  @override
  Future<SourceAdapter> adapter(String id) async => _Source();

  @override
  void dispose() {
    _posterCache.close();
    super.dispose();
  }
}

class _Source extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async =>
      path.isEmpty ? [_series, _video] : [_episode];

  @override
  Future<SourceEntry> stat(String path) async =>
      path == _video.path ? _video : _episode;

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

Future<void> _waitForImages(WidgetTester tester, Finder within) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final painted = tester.widgetList<RawImage>(
      find.descendant(of: within, matching: find.byType(RawImage)),
    );
    if (painted.isNotEmpty && painted.every((image) => image.image != null)) {
      return;
    }
  }
  fail('The source artwork did not finish decoding.');
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'portrait folder posters and video frames share the same bounds at $width',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('source-artwork-layout-'),
        ))!;
        final frame = File('${root.path}/frame.png');
        final poster = File('${root.path}/poster.png');
        await tester.runAsync(() async {
          await frame.writeAsBytes(
            images.encodePng(images.Image(width: 160, height: 90)),
          );
          await poster.writeAsBytes(
            images.encodePng(images.Image(width: 80, height: 120)),
          );
        });
        final store = AppStore(':memory:');
        final model = _Model(store, root, frame.path, poster);
        try {
          await model.catalog.inspect('nas', 'Series', [_episode]);
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
          final folderRow = find.byKey(const ValueKey('Series'));
          final videoRow = find.byKey(const ValueKey('Movie.mp4'));
          expect(folderRow, findsOneWidget);
          expect(videoRow, findsOneWidget);
          final folderArtwork = find.descendant(
            of: folderRow,
            matching: find.byType(MediaArtwork),
          );
          final videoArtwork = find.descendant(
            of: videoRow,
            matching: find.byType(MediaArtwork),
          );
          expect(tester.widget<MediaArtwork>(folderArtwork).poster, _posterUrl);
          expect(
            tester.widget<MediaArtwork>(videoArtwork).thumbnail,
            frame.path,
          );
          await _waitForImages(tester, folderRow);
          await _waitForImages(tester, videoRow);
          final posterBounds = tester.getRect(folderArtwork);
          final frameBounds = tester.getRect(videoArtwork);
          expect(posterBounds.size, frameBounds.size);
          expect(posterBounds.left, frameBounds.left);
          expect(posterBounds.right, frameBounds.right);
          for (final row in [folderRow, videoRow]) {
            final rendered = find.descendant(
              of: row,
              matching: find.byType(RawImage),
            );
            expect(rendered, findsOneWidget);
            expect(tester.getSize(rendered), posterBounds.size);
            expect(tester.widget<RawImage>(rendered).fit, BoxFit.cover);
          }
          final portrait = tester
              .widget<RawImage>(
                find.descendant(of: folderRow, matching: find.byType(RawImage)),
              )
              .image!;
          final landscape = tester
              .widget<RawImage>(
                find.descendant(of: videoRow, matching: find.byType(RawImage)),
              )
              .image!;
          expect(portrait.height, greaterThan(portrait.width));
          expect(landscape.width, greaterThan(landscape.height));
          expect(tester.takeException(), isNull);

          await tester.tap(folderRow);
          await tester.pumpAndSettle();
          final episodeRow = find.byType(MediaDetailsEpisodeTile);
          expect(episodeRow, findsOneWidget);
          await tester.ensureVisible(episodeRow);
          await tester.pumpAndSettle();
          await _waitForImages(tester, episodeRow);
          final episodeArtwork = find.descendant(
            of: episodeRow,
            matching: find.byType(MediaArtwork),
          );
          final episodeBounds = tester.getRect(episodeArtwork);
          expect(episodeBounds.size, posterBounds.size);
          expect(episodeBounds.left, posterBounds.left);
          expect(episodeBounds.right, posterBounds.right);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
