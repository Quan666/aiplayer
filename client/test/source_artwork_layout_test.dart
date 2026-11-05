import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

const _series = SourceEntry(name: 'Series', path: 'Series', directory: true);
const _footage = SourceEntry(name: 'Footage', path: 'Footage', directory: true);
const _clip = SourceEntry(
  name: 'clip-001.mp4',
  path: 'Footage/clip-001.mp4',
  size: 100,
);
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
  Future<File?> loadVisible(String url, {bool Function()? canStart}) async =>
      image;

  @override
  Future<File?> loadNearby(String url, {bool Function()? canStart}) async =>
      image;
}

class _Model extends AppModel {
  final String frame;
  final File poster;
  final previewPaths = <String>[];
  Completer<void>? previewGate;
  SourceEntry clip = _clip;
  bool missingPreview = false;
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
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) async {
    previewPaths.add(entry.path);
    final gate = previewGate;
    if (gate != null) {
      await Future.any([
        gate.future,
        if (cancel != null)
          cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
      ]);
    }
    cancel?.check();
    return SourcePreviewBinding(
      sourcePreviewId(sourceId, entry.path),
      browsingMediaId(sourceId, entry.path),
      missingPreview ? null : frame,
      false,
    );
  }

  @override
  String? thumbnailPath(String id) => frame;

  @override
  bool ensureMediaPreview(String id) => true;

  @override
  String ensureSourceMediaPreview(String sourceId, SourceEntry entry) =>
      sourcePreviewId(sourceId, entry.path);

  @override
  Future<SourceAdapter> adapter(String id) async => _Source(this);

  @override
  void dispose() {
    _posterCache.close();
    super.dispose();
  }
}

class _Source extends SourceAdapter {
  final _Model model;
  _Source(this.model);

  @override
  Future<List<SourceEntry>> list(String path) async => path.isEmpty
      ? [_series, _footage, _video]
      : path == _footage.path
      ? [model.clip]
      : [_episode];

  @override
  Future<SourceEntry> stat(String path) async => path == _video.path
      ? _video
      : path == _clip.path
      ? model.clip
      : _episode;

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

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'file view restores sole-video covers and reuses warm artwork on return at $width',
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
          final settings = File(
            albumSettingsPath(root.path, 'nas', _footage.path),
          );
          await settings.parent.create(recursive: true);
          await settings.writeAsString(
            jsonEncode({
              'album': true,
              'cover': {'name': 'poster.png', 'path': poster.path},
            }),
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
          final singleVideoFolder = find.byKey(const ValueKey('Footage'));
          final videoRow = find.byKey(const ValueKey('Movie.mp4'));
          expect(folderRow, findsOneWidget);
          expect(videoRow, findsOneWidget);
          expect(singleVideoFolder, findsOneWidget);
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
          final singleVideoCover = find.descendant(
            of: singleVideoFolder,
            matching: find.byType(AlbumVideoThumbnail),
          );
          await _until(tester, () => singleVideoCover.evaluate().isNotEmpty);
          expect(
            tester.widget<AlbumVideoThumbnail>(singleVideoCover).firstFrame,
            isFalse,
          );
          await _waitForImages(tester, singleVideoFolder);
          expect(
            tester
                .widget<AlbumVideoThumbnail>(
                  find.descendant(
                    of: videoRow,
                    matching: find.byType(AlbumVideoThumbnail),
                  ),
                )
                .firstFrame,
            isFalse,
          );
          expect(
            tester
                .widget<MediaArtwork>(
                  find.descendant(
                    of: singleVideoFolder,
                    matching: find.byType(MediaArtwork),
                  ),
                )
                .thumbnail,
            frame.path,
          );
          await _waitForImages(tester, folderRow);
          await _waitForImages(tester, videoRow);
          expect(singleVideoCover, findsOneWidget);
          expect(model.previewPaths, contains(_clip.path));
          final posterBounds = tester.getRect(folderArtwork);
          final frameBounds = tester.getRect(videoArtwork);
          expect(posterBounds.size, frameBounds.size);
          expect(posterBounds.left, frameBounds.left);
          expect(posterBounds.right, frameBounds.right);
          for (final row in [folderRow, singleVideoFolder, videoRow]) {
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

          // Importing a different directory must not invalidate already
          // displayed screenshots merely because media/location revisions move.
          model.addMedia(
            'nas',
            const SourceEntry(
              name: 'Other.mp4',
              path: 'Elsewhere/Other.mp4',
              size: 10,
            ),
          );
          final gate = model.previewGate = Completer<void>();
          await tester.tap(find.byTooltip('返回'));
          await _until(tester, () => singleVideoCover.evaluate().isNotEmpty);
          // Observe the first rendered parent list while every fresh preview
          // lookup is blocked. Warm artwork must already be available here.
          expect(gate.isCompleted, isFalse);
          for (final row in [singleVideoFolder, videoRow]) {
            final thumbnail = tester.widget<AlbumVideoThumbnail>(
              find.descendant(
                of: row,
                matching: find.byType(AlbumVideoThumbnail),
              ),
            );
            expect(thumbnail.initialThumbnail, frame.path);
            expect(
              tester
                  .widget<MediaArtwork>(
                    find.descendant(
                      of: row,
                      matching: find.byType(MediaArtwork),
                    ),
                  )
                  .thumbnail,
              frame.path,
            );
          }
          expect(tester.widget<MediaArtwork>(folderArtwork).poster, _posterUrl);
          await _waitForImages(tester, singleVideoFolder);
          await _waitForImages(tester, videoRow);
          expect(gate.isCompleted, isFalse);

          // The retained path is only valid for the original video identity.
          // A changed file must not inherit that screenshot while validation
          // of its replacement is still blocked.
          model.clip = SourceEntry(
            name: _clip.name,
            path: _clip.path,
            size: _clip.size + 1,
            modified: 2,
          );
          unawaited(
            tester
                .widget<RefreshIndicator>(find.byType(RefreshIndicator))
                .onRefresh(),
          );
          await _until(
            tester,
            () =>
                singleVideoCover.evaluate().isNotEmpty &&
                tester
                        .widget<AlbumVideoThumbnail>(singleVideoCover)
                        .entry
                        .size ==
                    model.clip.size,
          );
          expect(
            tester
                .widget<AlbumVideoThumbnail>(singleVideoCover)
                .initialThumbnail,
            isNull,
          );
          expect(
            tester
                .widget<MediaArtwork>(
                  find.descendant(
                    of: singleVideoFolder,
                    matching: find.byType(MediaArtwork),
                  ),
                )
                .thumbnail,
            isNull,
          );
          gate.complete();
          await _waitForImages(tester, singleVideoFolder);

          await tester.tap(folderRow);
          await _until(tester, () => episodeRow.evaluate().isNotEmpty);
          final missing = model.previewGate = Completer<void>();
          model.missingPreview = true;
          await tester.tap(find.byTooltip('返回'));
          await _until(tester, () => singleVideoCover.evaluate().isNotEmpty);
          expect(
            tester
                .widget<AlbumVideoThumbnail>(singleVideoCover)
                .initialThumbnail,
            frame.path,
          );
          missing.complete();
          await _until(
            tester,
            () =>
                tester
                    .widget<MediaArtwork>(
                      find.descendant(
                        of: singleVideoFolder,
                        matching: find.byType(MediaArtwork),
                      ),
                    )
                    .thumbnail ==
                null,
          );
          // A missing binding removes the retained seed as well as the image.
          await tester.tap(folderRow);
          await _until(tester, () => episodeRow.evaluate().isNotEmpty);
          model.previewGate = Completer<void>();
          await tester.tap(find.byTooltip('返回'));
          await _until(tester, () => singleVideoCover.evaluate().isNotEmpty);
          expect(
            tester
                .widget<AlbumVideoThumbnail>(singleVideoCover)
                .initialThumbnail,
            isNull,
          );
          expect(tester.takeException(), isNull);
        } finally {
          final gate = model.previewGate;
          if (gate != null && !gate.isCompleted) gate.complete();
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
