import 'dart:io';

import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

void main() {
  testWidgets(
    'retained thumbnail survives cache eviction and pause without replacing pixels',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'retained-frame-',
        );
        await File(
          '${directory.path}/photo.png',
        ).writeAsBytes(raster.encodePng(raster.Image(width: 128, height: 64)));
        return directory;
      }))!;
      final cache = PaintingBinding.instance.imageCache;
      final queue = ArtworkDecodeQueue.instance;
      Widget shell(bool enabled) => MaterialApp(
        home: TickerMode(
          enabled: enabled,
          child: Center(
            child: SizedBox(
              width: 128,
              height: 64,
              child: MediaArtwork(
                thumbnail: '${directory.path}/photo.png',
                maxDecodeEdge: 128,
                loadWhileScrolling: true,
                loadingPlaceholder: const ColoredBox(
                  key: ValueKey('cold-loading'),
                  color: Colors.red,
                ),
              ),
            ),
          ),
        ),
      );
      void visibleFrame(Element imageElement) {
        expect(find.byKey(const ValueKey('cold-loading')), findsNothing);
        expect(tester.element(find.byType(Image)), same(imageElement));
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      }

      try {
        await tester.pumpWidget(shell(true));
        for (var frame = 0; frame < 100; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null) {
            break;
          }
        }
        final imageElement = tester.element(find.byType(Image));
        visibleFrame(imageElement);
        await tester.pumpWidget(shell(false));
        cache
          ..clear()
          ..clearLiveImages();
        await tester.pumpWidget(shell(false));
        visibleFrame(imageElement);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // No pump after pause: neither decode queue may fill in background.
        await tester.idle();
        expect(queue.activeCount, 0);
        expect(queue.pendingCount, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(shell(true));
        visibleFrame(imageElement);
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump();
          visibleFrame(imageElement);
        }
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        cache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
