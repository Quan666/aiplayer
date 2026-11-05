import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

class _NoUiIndexStore extends AppStore {
  var locationLookups = 0;
  _NoUiIndexStore(super.path);
  @override
  Map<String, dynamic>? locationFor(String sourceId, String path) {
    locationLookups++;
    return super.locationFor(sourceId, path);
  }
}

class _CountingPreviewModel extends AppModel {
  final reads = <String, int>{};
  _CountingPreviewModel(
    super.store,
    super.documents, {
    required PreviewCapture capture,
  }) : super(
         backgroundWork: false,
         enableThumbnails: true,
         previewCapture: capture,
       );

  @override
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    required CancelToken cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) {
    reads.update(entry.path, (count) => count + 1, ifAbsent: () => 1);
    return super.readSourceMediaPreview(
      sourceId,
      entry,
      cancel: cancel,
      albumCover: albumCover,
      originalResolution: originalResolution,
    );
  }
}

class _PendingPreviewModel extends AppModel {
  var reads = 0, captures = 0, revision = 0;
  var binding = Completer<SourcePreviewBinding>();
  _PendingPreviewModel(super.store, super.documents)
    : super(backgroundWork: false, enableThumbnails: false);

  @override
  Object get sourcePreviewRevision => revision;

  @override
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    required CancelToken cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) {
    reads++;
    return binding.future;
  }

  @override
  bool tryEnsureSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    SourcePreviewBinding? binding,
  }) {
    captures++;
    return true;
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? diagnostics,
}) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: diagnostics?.call());
}

void main() {
  testWidgets(
    'a prepared first frame stays visible while its replacement binding is cold',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-initial-cover-'),
      ))!;
      final small = '${root.path}/small.jpg', full = '${root.path}/full.jpg';
      await tester.runAsync(() async {
        await File(small)
            .writeAsBytes(image.encodeJpg(image.Image(width: 60, height: 100)));
        await File(
          full,
        ).writeAsBytes(image.encodeJpg(image.Image(width: 120, height: 200)));
      });
      final store = AppStore(':memory:');
      final model = _PendingPreviewModel(store, root);
      Widget view({int modified = 1, String? initial}) => MaterialApp(
        home: SizedBox(
          width: 200,
          height: 300,
          child: AlbumVideoThumbnail(
            model: model,
            sourceId: 'local',
            entry: SourceEntry(
              name: 'clip.mp4',
              path: '${root.path}/clip.mp4',
              modified: modified,
            ),
            edge: 300,
            fit: BoxFit.contain,
            originalResolution: true,
            initialThumbnail: initial,
          ),
        ),
      );
      RawImage? rendered() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((raw) => raw.image != null)
          .firstOrNull;
      try {
        await tester.pumpWidget(view(initial: small));
        await _until(tester, () => rendered() != null);
        final resident = rendered()!.image;
        model.binding.complete(
          const SourcePreviewBinding('original', 'original', null, true),
        );
        await tester.pump();
        expect(rendered()?.image, same(resident));
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
          small,
        );
        await _until(tester, () => model.captures > 0);
        expect(rendered()?.image, same(resident));

        model.binding = Completer<SourcePreviewBinding>()
          ..complete(SourcePreviewBinding('original', 'original', full, false));
        model.revision++;
        model.changed();
        await _until(tester, () {
          expect(rendered()?.image, isNotNull);
          return rendered()!.image!.height == 200;
        });
        expect(rendered()!.fit, BoxFit.contain);
        expect(rendered()!.image!.width, 120);

        // A new file revision must discard the previous identity's pixels.
        model.binding = Completer<SourcePreviewBinding>();
        await tester.pumpWidget(view(modified: 2));
        expect(rendered(), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        if (!model.binding.isCompleted) {
          model.binding.complete(
            const SourcePreviewBinding('original', 'original', null, true),
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await root.delete(recursive: true);
        });
      }
    },
  );

  testWidgets('late prepared covers display while capture is suspended', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('album-late-cover-'),
    ))!;
    final path = '${root.path}/cover.jpg';
    await tester.runAsync(
      () => File(path)
          .writeAsBytes(image.encodeJpg(image.Image(width: 60, height: 100))),
    );
    final store = AppStore(':memory:');
    final model = _PendingPreviewModel(store, root);
    Widget view(String? initial) => MaterialApp(
      home: AlbumVideoThumbnail(
        model: model,
        sourceId: 'local',
        entry: const SourceEntry(name: 'clip.mp4', path: '/clip.mp4'),
        edge: 200,
        active: false,
        initialThumbnail: initial,
      ),
    );
    try {
      await tester.pumpWidget(view(null));
      expect(find.byType(RawImage), findsNothing);
      await tester.pumpWidget(view(path));
      await _until(
        tester,
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((raw) => raw.image != null),
      );
      expect(model.reads, 0);
      expect(model.captures, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        model.dispose();
        await model.flushMetadataTasks();
        store.dispose();
        await root.delete(recursive: true);
      });
    }
  });

  testWidgets(
    'a resident grid cover survives notifications, scrolling and original upgrade',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-original-'),
      ))!;
      final path = '${root.path}/clip.mp4';
      await tester.runAsync(() => File(path).writeAsBytes(Uint8List(32)));
      final small = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      final full = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 640, height: 480)),
      );
      final ready = Completer<MediaPreview>();
      final tokens = <CancelToken>[];
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, token) {
          tokens.add(token);
          if (tokens.length == 1) {
            return Future.value(MediaPreview(small, 30, 640, 480));
          }
          return Future.any([
            ready.future,
            token.whenCancelled.then<MediaPreview>(
              (_) => throw const Cancelled(),
            ),
          ]);
        },
      );
      final entry = SourceEntry(name: 'clip.mp4', path: path, size: 32);
      Widget view(bool original) => MaterialApp(
        home: Scaffold(
          body: ArtworkScrollScope(
            child: ListView(
              children: [
                SizedBox(
                  height: 180,
                  child: AlbumVideoThumbnail(
                    key: const ValueKey('cover'),
                    model: model,
                    sourceId: 'local',
                    entry: entry,
                    edge: 640,
                    originalResolution: original,
                  ),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      RawImage? rendered() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((raw) => raw.image != null)
          .firstOrNull;
      try {
        await tester.pumpWidget(view(false));
        await _until(tester, () => rendered() != null);
        final resident = rendered()!.image;
        final smallId = albumVideoPreviewId('local', path);
        final saved = Map<String, dynamic>.from(
          store.local('preview:$smallId'),
        );
        model.changed();
        await tester.pump();
        expect(rendered()!.image, same(resident));
        final drag = await tester.startGesture(const Offset(300, 130));
        await drag.moveBy(const Offset(0, -24));
        await tester.pump();
        expect(rendered()!.image, same(resident));
        await drag.up();
        await tester.pumpAndSettle();
        expect(tokens, hasLength(1));
        await tester.pumpWidget(view(true));
        expect(rendered()!.image, same(resident));
        await _until(tester, () => tokens.length == 2);
        expect(rendered()!.image, same(resident));
        final binding = await tester.runAsync(
          () => model.readSourceMediaPreview(
            'local',
            entry,
            cancel: CancelToken(),
            albumCover: true,
            originalResolution: true,
          ),
        );
        expect(binding!.thumbnail, saved['path']);
        expect(binding.thumbnailId, smallId);
        expect(binding.needsCapture, isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(tokens.last.cancelled, isTrue);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        expect(
          tokens,
          hasLength(2),
          reason: 'No frame or new original capture in background',
        );
        expect(rendered()!.image, same(resident));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _until(tester, () => tokens.length == 3);
        expect(rendered()!.image, same(resident));
        ready.complete(MediaPreview(full, 30, 640, 480, capturedPosition: 0));
        await _until(tester, () => rendered()?.image?.width == 640);
        expect(store.local('preview:$smallId'), saved);
        final fullId = albumVideoPreviewId(
          'local',
          path,
          originalResolution: true,
        );
        expect(store.local('preview:$fullId')['originalResolution'], isTrue);
        expect(store.local('preview:$fullId')['path'], isNot(saved['path']));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await root.delete(recursive: true);
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  test(
    'album covers stay independent of imported and file-browser covers',
    () async {
      final root = await Directory.systemTemp.createTemp('album-cover-policy-');
      final path = '${root.path}/imported.mp4';
      final otherPath = '${root.path}/unimported.mp4';
      await File(path).writeAsBytes(Uint8List(32));
      await File(otherPath).writeAsBytes(Uint8List(32));
      final resumePath = '${root.path}/resume.jpg';
      final jpeg = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      await File(resumePath).writeAsBytes(jpeg);
      final store = _NoUiIndexStore('${root.path}/library.db');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, _) async =>
            MediaPreview(jpeg, 60, 80, 60, capturedPosition: 0),
      );
      final imported = SourceEntry(name: 'imported.mp4', path: path, size: 32);
      final other = SourceEntry(
        name: 'unimported.mp4',
        path: otherPath,
        size: 32,
      );
      store.save('media', 'film', {'size': 32});
      store.setLocal('location:film', {
        'id': 'film',
        'source': 'local',
        'path': path,
        'size': 32,
      });
      store.save('progress', 'film:32', {'position': 30, 'duration': 60});
      final resumeRequest = MediaPreviewRequest(
        'film',
        'local',
        path,
        32,
        position: 30,
      );
      final resume = {
        'path': resumePath,
        'contentFingerprint': resumeRequest.contentFingerprint,
        'fingerprint': resumeRequest.fingerprint,
        'requestedPosition': 30.0,
        'capturedPosition': 30.0,
        'formatVersion': MediaPreview.formatVersion,
      };
      store.setLocal('preview:film', resume);
      Future<SourcePreviewBinding> read(
        SourceEntry entry, {
        bool album = false,
        bool original = false,
      }) => model.readSourceMediaPreview(
        'local',
        entry,
        cancel: CancelToken(),
        albumCover: album,
        originalResolution: original,
      );
      Future<void> waitForCover(String id) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (store.local('preview:$id') == null) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Cover was not persisted: $id');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      try {
        final fileBinding = await read(imported);
        expect(fileBinding.id, 'film');
        expect(fileBinding.thumbnail, resumePath);
        expect(fileBinding.needsCapture, isFalse);
        final albumBinding = await read(imported, album: true);
        expect(albumBinding.id, albumVideoPreviewId('local', path));
        expect(albumBinding.thumbnail, isNull);
        expect(
          model.tryEnsureSourceMediaPreview(
            'local',
            imported,
            binding: albumBinding,
          ),
          isTrue,
        );
        await waitForCover(albumBinding.id);
        final album = await read(imported, album: true);
        expect(album.needsCapture, isFalse);
        expect(album.thumbnail, isNot(resumePath));
        expect(store.local('preview:${album.id}')['firstFrame'], isTrue);
        expect(store.local('preview:${album.id}')['capturedPosition'], 0);
        expect(store.local('preview:film'), resume);
        expect((await read(imported)).thumbnail, resumePath);
        expect(store.get('progress', 'film:32')!.data['position'], 30);
        final detail = await read(imported, album: true, original: true);
        expect(detail.thumbnail, album.thumbnail);
        expect(detail.thumbnailId, album.id);
        expect(detail.id, isNot(album.id));
        expect(detail.needsCapture, isTrue);
        expect(
          model.tryEnsureSourceMediaPreview('local', imported, binding: detail),
          isTrue,
        );
        await waitForCover(detail.id);
        final full = await read(imported, album: true, original: true);
        expect(full.needsCapture, isFalse);
        expect(full.thumbnail, isNot(album.thumbnail));
        expect(full.thumbnailId, detail.id);
        expect(store.local('preview:${full.id}')['originalResolution'], isTrue);
        expect((await read(imported, album: true)).thumbnail, album.thumbnail);
        expect(store.local('preview:film'), resume);
        // A cold ordinary file-browser video keeps the original sampled-scene
        // policy as well; album mode is the only opt-in to frame zero.
        final ordinary = await read(other);
        expect(ordinary.id, browsingMediaId('local', otherPath));
        expect(
          model.tryEnsureSourceMediaPreview('local', other, binding: ordinary),
          isTrue,
        );
        await waitForCover(ordinary.id);
        expect(
          store.local('preview:${ordinary.id}')['firstFrame'],
          isNot(true),
        );
        expect((await read(other)).needsCapture, isFalse);
        expect(store.locationLookups, 0);
      } finally {
        model.dispose();
        await model.flushMetadataTasks();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'a deleted prepared video cover regenerates after an actual file decode failure',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-video-missing-'),
      ))!;
      final path = '${root.path}/personal.mp4';
      final sourceBytes = Uint8List(32);
      await tester.runAsync(() => File(path).writeAsBytes(sourceBytes));
      final frame = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 320, height: 180)),
      );
      var captures = 0;
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, _) async {
          captures++;
          return MediaPreview(frame, 60, 320, 180);
        },
      );
      Widget view(int edge) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: edge.toDouble(),
            height: edge.toDouble(),
            child: AlbumVideoThumbnail(
              model: model,
              sourceId: 'local',
              entry: SourceEntry(name: 'personal.mp4', path: path, size: 32),
              edge: edge,
            ),
          ),
        ),
      );
      bool decoded() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((raw) => raw.image != null);
      try {
        await tester.pumpWidget(view(64));
        await _until(tester, decoded);
        final id = albumVideoPreviewId('local', path);
        for (var round = 0; round < 3; round++) {
          final cached = model.thumbnailPath(id)!;
          await tester.runAsync(() => File(cached).delete());
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          // The mounted binding still points at its old path. A larger decode
          // now actually opens that deleted file rather than hiding the fault
          // behind an existing texture or a fresh binding lookup.
          await tester.pumpWidget(view(128 + 64 * round));
          await _until(
            tester,
            () =>
                captures == round + 2 &&
                decoded() &&
                ArtworkDecodeQueue.instance.activeCount == 0 &&
                ArtworkDecodeQueue.instance.pendingCount == 0,
            diagnostics: () =>
                'round=$round captures=$captures decoded=${decoded()} '
                'thumbnail=${tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail} '
                'active=${ArtworkDecodeQueue.instance.activeCount} '
                'pending=${ArtworkDecodeQueue.instance.pendingCount}',
          );
          expect(
            await tester.runAsync(() => File(path).readAsBytes()),
            sourceBytes,
          );
        }
        expect(store.records('media'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
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
    'publishing one cover does not reread other visible video bindings',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-video-notices-'),
      ))!;
      final paths = [for (var i = 0; i < 3; i++) '${root.path}/$i.mp4'];
      await tester.runAsync(
        () => Future.wait(
          paths.map((path) => File(path).writeAsBytes(Uint8List(32))),
        ),
      );
      final captures = <String, Completer<MediaPreview>>{};
      final frame = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      final store = AppStore(':memory:');
      final model = _CountingPreviewModel(
        store,
        root,
        capture: (uri, token) {
          final result = captures.putIfAbsent(uri, Completer<MediaPreview>.new);
          return Future.any([
            result.future,
            token.whenCancelled.then<MediaPreview>(
              (_) => throw const Cancelled(),
            ),
          ]);
        },
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (final path in paths)
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: AlbumVideoThumbnail(
                        model: model,
                        sourceId: 'local',
                        entry: SourceEntry(
                          name: path.split('/').last,
                          path: path,
                          size: 32,
                          modified: 1,
                        ),
                        edge: 160,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await _until(
          tester,
          () => captures.isNotEmpty && model.reads.length == 3,
        );
        final first = captures.keys.first;
        final untouched = [
          for (final path in paths)
            if (path != first) path,
        ];
        final before = {for (final path in untouched) path: model.reads[path]};
        captures[first]!.complete(MediaPreview(frame, 30, 80, 60));
        await _until(
          tester,
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
        );
        expect({for (final path in untouched) path: model.reads[path]}, before);
        final previous = Map<String, int>.from(model.reads);
        store.setLocal('sources', <dynamic>[]);
        model.changed();
        await _until(
          tester,
          () => paths.every((path) => model.reads[path]! > previous[path]!),
        );
        expect(model.sourcePreviewNotificationId, isNull);
        await _until(tester, () => captures.length >= 2);
        final next = captures.keys.firstWhere((path) => path != first);
        final beforeNested = Map<String, int>.from(model.reads);
        var nested = false;
        void nestedEdit() {
          if (nested || model.sourcePreviewNotificationId == null) return;
          nested = true;
          store.setLocal('sources', <dynamic>[
            {'id': 'other', 'kind': 'local'},
          ]);
          model.changed();
        }

        model.addListener(nestedEdit);
        captures[next]!.complete(MediaPreview(frame, 30, 80, 60));
        await _until(
          tester,
          () =>
              nested &&
              paths.every((path) => model.reads[path]! > beforeNested[path]!),
        );
        model.removeListener(nestedEdit);
        expect(model.sourcePreviewNotificationId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
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
    'disk album video bindings never build the location index on the UI isolate',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-video-index-'),
      ))!;
      final path = '${root.path}/personal.mp4';
      await tester.runAsync(() => File(path).writeAsBytes(Uint8List(32)));
      final frame = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      final store = _NoUiIndexStore('${root.path}/library.db');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, _) async => MediaPreview(frame, 60, 80, 60),
      );
      try {
        // ReceivePort must belong to the real event loop so teardown can drain
        // the worker after the widget binding stops pumping frames.
        await tester.runAsync(
          () => model.readSourceMediaPreview(
            'local',
            SourceEntry(name: 'personal.mp4', path: path, size: 32),
            cancel: CancelToken(),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 200,
                height: 200,
                child: AlbumVideoThumbnail(
                  model: model,
                  sourceId: 'local',
                  entry: SourceEntry(
                    name: 'personal.mp4',
                    path: path,
                    size: 32,
                  ),
                  edge: 200,
                ),
              ),
            ),
          ),
        );
        await _until(
          tester,
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
        );
        expect(store.locationLookups, 0);
        await tester.pumpWidget(const SizedBox());
        expect(store.locationLookups, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
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
    'album video capture stays outside library, reuses cache and tracks content revisions',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-video-'),
      ))!;
      final path = '${root.path}/personal.mp4';
      await tester.runAsync(() => File(path).writeAsBytes(Uint8List(32)));
      final frame = Uint8List.fromList(
        image.encodeJpg(image.Image(width: 80, height: 60)),
      );
      var captures = 0;
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        root,
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: (_, _) async {
          captures++;
          return MediaPreview(frame, 60, 80, 60);
        },
      );
      Widget view(int modified) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: AlbumVideoThumbnail(
              model: model,
              sourceId: 'local',
              entry: SourceEntry(
                name: 'personal.mp4',
                path: path,
                size: 32,
                modified: modified,
              ),
              edge: 200,
            ),
          ),
        ),
      );
      bool decoded() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);
      try {
        await tester.pumpWidget(view(1));
        await _until(tester, decoded);
        expect(captures, 1);
        expect(store.records('media'), isEmpty);
        final id = albumVideoPreviewId('local', path);
        final original = model.thumbnailPath(id);
        expect(original, isNotNull);
        expect(store.local('preview:$id')['firstFrame'], isTrue);
        await tester.pumpWidget(view(1));
        await tester.pump(const Duration(seconds: 1));
        expect(captures, 1);
        // Old sampled-scene caches remain visible while the first-frame
        // migration runs; no user playback is needed to repair the cover.
        final legacy = '${root.path}/legacy-cover.jpg';
        await tester.runAsync(() => File(original!).copy(legacy));
        final old = Map<String, dynamic>.from(store.local('preview:$id'))
          ..['path'] = legacy
          ..['fingerprint'] = MediaPreviewRequest(
            id,
            'local',
            path,
            32,
            revision: '1',
          ).contentFingerprint
          ..remove('firstFrame');
        store.setLocal('preview:$id', old);
        final binding = await tester.runAsync(
          () => model.readSourceMediaPreview(
            'local',
            SourceEntry(
              name: 'personal.mp4',
              path: path,
              size: 32,
              modified: 1,
            ),
            cancel: CancelToken(),
            albumCover: true,
          ),
        );
        expect(binding!.thumbnail, legacy);
        expect(binding.needsCapture, isTrue);
        model.changed();
        await _until(tester, () => captures == 2);
        await _until(
          tester,
          () => store.local('preview:$id')['firstFrame'] == true,
        );
        expect(model.thumbnailPath(id), isNot(legacy));
        await tester.pumpWidget(view(2));
        await _until(
          tester,
          () =>
              captures == 3 && model.thumbnailPath(id) != original && decoded(),
        );
        expect(store.local('browse:$id')['previewRevision'], '2');
        expect(store.records('media'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
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
    'video capture cancels on scroll and paused without frames, then retries on resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-video-life-'),
      ))!;
      final path = '${root.path}/personal.mp4';
      await tester.runAsync(() => File(path).writeAsBytes(Uint8List(32)));
      final store = AppStore(':memory:');
      final tokens = <CancelToken>[];
      final activity = ValueNotifier(true);
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
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtworkScrollScope(
                child: ListView(
                  children: [
                    SizedBox(
                      height: 200,
                      child: AlbumVideoThumbnail(
                        model: model,
                        sourceId: 'local',
                        entry: SourceEntry(
                          name: 'personal.mp4',
                          path: path,
                          size: 32,
                        ),
                        edge: 200,
                        activity: activity,
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        );
        await _until(tester, () => tokens.length == 1);
        final gesture = await tester.startGesture(const Offset(300, 150));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        expect(tokens.first.cancelled, isTrue);
        await gesture.up();
        await _until(tester, () => tokens.length == 2);
        activity.value = false;
        expect(tokens.last.cancelled, isTrue);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        expect(tokens.length, 2);
        activity.value = true;
        await _until(tester, () => tokens.length == 3);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(tokens.last.cancelled, isTrue);
        // No pump/frame is needed to cancel and stop queue refill.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        expect(tokens.length, 3);
        expect(store.records('media'), isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _until(tester, () => tokens.length == 4);
        await tester.pumpWidget(const SizedBox());
        expect(tokens.last.cancelled, isTrue);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        expect(tokens.length, 4);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        activity.dispose();
        await tester.runAsync(() async {
          model.dispose();
          await model.flushMetadataTasks();
          store.dispose();
          await root.delete(recursive: true);
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}
