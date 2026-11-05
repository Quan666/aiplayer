import 'dart:io';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

void main() {
  testWidgets(
    'disk LRU eviction keeps a visible decoded photo through pause and resize',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'album-grid-retention-',
        );
        for (final name in ['first', 'second']) {
          final image = raster.Image(width: 320, height: 160);
          raster.fill(
            image,
            color: raster.ColorRgb8(name == 'first' ? 220 : 20, 60, 100),
          );
          await File('${root.path}/$name.jpg')
              .writeAsBytes(raster.encodeJpg(image));
        }
        return root;
      }))!;
      final service = _CountingImages('${directory.path}/cache');
      Future<SourceEntry> entry(String name) async {
        final path = '${directory.path}/$name.jpg';
        final stat = await File(path).stat();
        return SourceEntry(
          name: '$name.jpg',
          path: path,
          size: stat.size,
          modified: stat.modified.millisecondsSinceEpoch,
        );
      }

      final first = (await tester.runAsync(() => entry('first')))!;
      final second = (await tester.runAsync(() => entry('second')))!;
      final prepared = (await tester.runAsync(
        () => service.load(first, targetEdge: 128).future,
      ))!;
      Widget shell({
        bool enabled = true,
        int edge = 128,
        SourceEntry? selected,
      }) => MaterialApp(
        home: TickerMode(
          enabled: enabled,
          child: Center(
            child: SizedBox.square(
              dimension: edge.toDouble(),
              child: AlbumThumbnail(
                service: service,
                entry: selected ?? first,
                edge: edge,
                initialResult: selected == null ? prepared : null,
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(shell());
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null)) {
            break;
          }
        }
        final imageElement = tester.element(find.byType(Image));
        final image = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!
            .clone();
        void retained() {
          expect(tester.element(find.byType(Image)), same(imageElement));
          expect(
            tester
                .widget<RawImage>(find.byType(RawImage))
                .image!
                .isCloneOf(image),
            isTrue,
          );
        }

        final firstLoads = service.loads[first.path];
        // The real worker has room for one JPEG/sidecar pair. Publishing a second
        // source physically removes the first file and sends its eviction event.
        await tester.runAsync(
          () => service.load(second, targetEdge: 128).future,
        );
        expect(service.wasEvicted(prepared.path!), isTrue);
        await tester.pump();
        retained();
        expect(service.loads[first.path], firstLoads);
        for (var i = 0; i < 3; i++) {
          service.setScrolling(true);
          service.setScrolling(false);
          await tester.pumpWidget(shell());
          retained();
        }
        expect(service.loads[first.path], firstLoads);
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
          prepared.path,
        );
        await tester.pumpWidget(shell(enabled: false));
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // Deliberately no pump after pause; background work remains stopped.
        await tester.idle();
        expect(ArtworkDecodeQueue.instance.pendingCount, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(shell());
        retained();
        await tester.pumpWidget(shell(edge: 192));
        retained();
        // A different file must never inherit the old photo, even while its own
        // worker request has not supplied a decoded frame yet.
        await tester.pumpWidget(shell(selected: second));
        final changed = tester.widgetList<RawImage>(find.byType(RawImage));
        expect(
          changed.any((raw) => raw.image?.isCloneOf(image) == true),
          isFalse,
        );
        image.dispose();
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await directory.delete(recursive: true);
        });
      }
    },
  );
}

class _CountingImages extends AlbumImageService {
  final loads = <String, int>{};
  _CountingImages(String cacheDirectory)
    : super(
        cacheDirectory: cacheDirectory,
        sourceId: 'local',
        source: const {'kind': 'local'},
        maxThumbnailFiles: 2,
        maxCacheBytes: 64 * 1024,
        maxConcurrentRequests: 1,
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
    loads.update(entry.path, (value) => value + 1, ifAbsent: () => 1);
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
