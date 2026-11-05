import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_viewer.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

Future<String> _fixture() async {
  final root = await Directory.systemTemp.createTemp('album-encoded-preview-');
  final image = raster.Image(width: 2048, height: 1365);
  raster.fill(image, color: raster.ColorRgb8(35, 170, 120));
  await File('${root.path}/cached-original.jpg')
      .writeAsBytes(raster.encodeJpg(image));
  return root.path;
}

void main() {
  testWidgets(
    'viewer reuses a complete encoded initial preview without loading its source again',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(() => Isolate.run(_fixture)))!;
      final store = AppStore(':memory:');
      final model = AppModel(store, Directory(root), backgroundWork: false);
      final entry = SourceEntry(
        name: 'photo.jpg',
        // Deliberately absent: the already cached original is sufficient.
        path: '$root/unavailable-original.jpg',
        size: 4096,
        modified: 123,
      );
      final preview = AlbumImageResult(
        path: '$root/cached-original.jpg',
        sourcePath: entry.path,
        encodedSource: true,
        width: 2048,
        height: 1365,
      );
      final snapshot = AlbumIndex(
        [entry],
        sourceId: 'local',
        directory: root,
      ).filter(AlbumOptions());
      final queue = ArtworkDecodeQueue.instance;
      final current = find.descendant(
        of: find.byKey(const ValueKey('album-current-page')),
        matching: find.byType(AlbumThumbnail),
      );
      bool pixelsReady() => tester
          .widgetList<RawImage>(
            find.descendant(of: current, matching: find.byType(RawImage)),
          )
          .any((raw) => (raw.image?.width ?? 0) >= 800);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumViewer(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              password: '',
              snapshot: snapshot,
              initialIndex: 0,
              initialPreview: preview,
            ),
          ),
        );
        for (var frame = 0; frame < 200 && !pixelsReady(); frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(pixelsReady(), isTrue);
        await tester.pump();
        final photo = tester.widget<AlbumThumbnail>(current);
        expect(photo.initialResult?.encodedSource, isTrue);
        expect(photo.initialResult?.sourcePath, entry.path);
        expect(
          photo.service.peek(entry),
          isNull,
          reason: 'A complete preview must not require a redundant viewer-service request',
        );
        expect(photo.service.pendingCount, 0);
        expect(photo.service.activeCount, 0);
        expect(queue.activeCount, 0);
        expect(queue.pendingCount, 0);
        final artwork = tester.widget<MediaArtwork>(
          find
              .descendant(of: current, matching: find.byType(MediaArtwork))
              .first,
        );
        expect(artwork.thumbnail, preview.path);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (var frame = 0; frame < 100 && queue.activeCount > 0; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        model.dispose();
        await tester.runAsync(model.flushMetadataTasks);
        store.dispose();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => Directory(root).delete(recursive: true));
      }
    },
  );
}
