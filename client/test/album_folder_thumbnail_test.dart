import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_folder_thumbnail.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

class _FolderImages extends AlbumImageService {
  AlbumImageResult result = const AlbumImageResult();
  final requests =
      <({Set<String> include, Set<String> exclude, bool hidden})>[];
  _FolderImages()
    : super(
        cacheDirectory: '/unused',
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );

  @override
  AlbumImageHandle load(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    bool metadataOnly = false,
    SourceEntry? cover,
    int priority = 0,
  }) {
    expect(folder, isTrue);
    requests.add((
      include: Set.of(extensions),
      exclude: Set.of(excludedExtensions),
      hidden: hideHidden,
    ));
    return AlbumImageHandle(Future.value(result), () {});
  }
}

class _CountingFolderImages extends AlbumImageService {
  int folderLoads = 0;
  _CountingFolderImages(Directory root)
    : super(
        cacheDirectory: '${root.path}/cache',
        documentsPath: root.path,
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );

  @override
  AlbumImageHandle load(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    bool metadataOnly = false,
    SourceEntry? cover,
    int priority = 0,
  }) {
    if (folder || entry.directory) folderLoads++;
    return super.load(
      entry,
      targetEdge: targetEdge,
      folder: folder,
      extensions: extensions,
      excludedExtensions: excludedExtensions,
      hideHidden: hideHidden,
      metadataOnly: metadataOnly,
      cover: cover,
      priority: priority,
    );
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

bool _decoded(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((widget) => widget.image != null);

void main() {
  testWidgets(
    'warm video folder returns immediately without another lookup and respects filters and hiding',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'album-folder-warm-',
        );
        final media = await Directory('${root.path}/media').create();
        await File('${media.path}/clip.mp4').writeAsBytes([0, 1, 2]);
        return root;
      }))!;
      final folder = SourceEntry(
        name: 'media',
        path: '${root.path}/media',
        directory: true,
      );
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      final images = _CountingFolderImages(root);
      Widget view({Set<String> excluded = const {}}) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 160,
            child: AlbumFolderThumbnail(
              model: model,
              service: images,
              sourceId: 'local',
              entry: folder,
              edge: 160,
              active: false,
              excludedExtensions: excluded,
            ),
          ),
        ),
      );
      try {
        final prepared = await tester.runAsync(
          () => images.load(folder, targetEdge: 160, folder: true).future,
        );
        expect(prepared?.singleVideo?.path, '${folder.path}/clip.mp4');
        expect(images.folderLoads, 1);

        await tester.pumpWidget(view());
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);
        expect(find.byType(AlbumThumbnail), findsNothing);
        expect(images.folderLoads, 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(view());
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);
        expect(images.folderLoads, 1);

        // The warm identity cannot bypass a newly excluded video extension.
        await tester.pumpWidget(view(excluded: const {'.mp4'}));
        expect(find.byType(AlbumVideoThumbnail), findsNothing);
        expect(find.byType(AlbumThumbnail), findsOneWidget);
        await tester.pumpWidget(view());
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);

        await tester.runAsync(() async {
          final settings = File(
            albumSettingsPath(root.path, 'local', folder.path),
          );
          await settings.parent.create(recursive: true);
          await settings.writeAsString(jsonEncode({'hideCover': true}));
        });
        images.invalidate();
        await tester.pump();
        expect(find.byType(AlbumVideoThumbnail), findsNothing);
        final hidden = await tester.runAsync(
          () => images.load(folder, targetEdge: 160, folder: true).future,
        );
        expect(hidden?.path, isNull);
        expect(hidden?.singleVideo, isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(view());
        expect(find.byType(AlbumVideoThumbnail), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await root.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'sole-video folder uses the shared screenshot without importing media',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-folder-video-'),
      ))!;
      final video = SourceEntry(
        name: 'clip.mp4',
        path: '${root.path}/clip.mp4',
        size: 32,
        modified: 1,
      );
      await tester.runAsync(() => File(video.path).writeAsBytes(Uint8List(32)));
      final screenshot = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      final capture = Completer<MediaPreview>();
      final tokens = <CancelToken>[];
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, token) {
          tokens.add(token);
          return Future.any([
            capture.future,
            token.whenCancelled.then<MediaPreview>(
              (_) => throw const Cancelled(),
            ),
          ]);
        },
      );
      final images = _FolderImages()
        ..result = AlbumImageResult(singleVideo: video);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 160,
                height: 160,
                child: AlbumFolderThumbnail(
                  model: model,
                  service: images,
                  sourceId: 'local',
                  entry: SourceEntry(
                    name: 'folder',
                    path: root.path,
                    directory: true,
                  ),
                  edge: 160,
                  placeholder: const Icon(Icons.folder_outlined),
                ),
              ),
            ),
          ),
        );
        await _until(tester, () => tokens.length == 1);
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);
        expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
        expect(_decoded(tester), isFalse);
        images.setActive(false);
        expect(tokens.first.cancelled, isTrue);
        // The service pause must cancel capture without another background
        // frame and must not let the native queue refill while paused.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        expect(tokens, hasLength(1));
        images.setActive(true);
        await _until(tester, () => tokens.length == 2);
        capture.complete(MediaPreview(screenshot, 30, 80, 60));
        await _until(tester, () => _decoded(tester));
        expect(store.records('media'), isEmpty);
        expect(images.requests, hasLength(1));
        expect(tokens, hasLength(2));
        model.changed();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tokens, hasLength(2));
        expect(images.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await root.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'refresh and filter changes retire a video fallback and keep photo priority',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-folder-cover-refresh-'),
      ))!;
      final photo = '${root.path}/cover.jpg';
      final video = SourceEntry(
        name: 'clip.mp4',
        path: '${root.path}/clip.mp4',
        size: 32,
      );
      await tester.runAsync(() async {
        await File(video.path).writeAsBytes(Uint8List(32));
        await File(photo)
            .writeAsBytes(image.encodeJpg(image.Image(width: 80, height: 60)));
      });
      final tokens = <CancelToken>[];
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, token) async {
          tokens.add(token);
          await token.whenCancelled;
          throw const Cancelled();
        },
      );
      final images = _FolderImages()
        ..result = AlbumImageResult(singleVideo: video);
      Widget view({Set<String> include = const {}, bool hidden = true}) =>
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 160,
                height: 160,
                child: AlbumFolderThumbnail(
                  model: model,
                  service: images,
                  sourceId: 'local',
                  entry: SourceEntry(
                    name: 'folder',
                    path: root.path,
                    directory: true,
                  ),
                  edge: 160,
                  extensions: include,
                  excludedExtensions: const {'.mkv'},
                  hideHidden: hidden,
                ),
              ),
            ),
          );
      try {
        await tester.pumpWidget(view());
        await _until(tester, () => tokens.length == 1);
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);

        // A refreshed folder containing a usable photo replaces the pending
        // video capture rather than retaining its old fallback indefinitely.
        images.result = AlbumImageResult(path: photo, singleVideo: video);
        images.invalidate();
        await _until(tester, () => _decoded(tester));
        expect(tokens.first.cancelled, isTrue);
        expect(find.byType(AlbumVideoThumbnail), findsNothing);
        expect(find.byType(AlbumThumbnail), findsOneWidget);
        expect(tokens, hasLength(1));

        // Filter edits invalidate the prepared folder result and are forwarded
        // to the worker; they cannot keep a previously allowed video cover.
        images.result = const AlbumImageResult();
        await tester.pumpWidget(view(include: const {'.png'}, hidden: false));
        await _until(tester, () => images.requests.length == 3);
        expect(find.byType(AlbumVideoThumbnail), findsNothing);
        expect(images.requests.last.include, {'.png'});
        expect(images.requests.last.exclude, {'.mkv'});
        expect(images.requests.last.hidden, isFalse);
        expect(_decoded(tester), isFalse);
        expect(tokens, hasLength(1));
        expect(store.records('media'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
