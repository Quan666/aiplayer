import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

void main() {
  for (final evictDerivative in [false, true]) {
    testWidgets(
      'recycled gallery cell reuses original pixels after derivative publication (${evictDerivative ? 'disk eviction' : 'memory pressure'})',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final root = (await tester.runAsync(
          () => Isolate.run(() {
            final root = Directory.systemTemp.createTempSync(
              'album-scroll-cache-',
            );
            File('${root.path}/photo.jpg').writeAsBytesSync(
              raster.encodeJpg(raster.Image(width: 1600, height: 1200)),
            );
            return root;
          }),
        ))!;
        final service = AlbumImageService(
          cacheDirectory: '${root.path}/cache',
          sourceId: 'local',
          source: const {'kind': 'local'},
        )..setMaintenanceHeld(true);
        final entry = SourceEntry(
          name: 'photo.jpg',
          path: '${root.path}/photo.jpg',
          size: (await tester.runAsync(
            () => File('${root.path}/photo.jpg').length(),
          ))!,
          modified: 1,
        );
        final original = (await tester.runAsync(
          () => service.load(entry, targetEdge: 128).future,
        ))!;
        final controller = ScrollController();
        final cache = PaintingBinding.instance.imageCache;
        Future<void> waitFor(bool Function() condition) async {
          for (var i = 0; i < 300 && !condition(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(condition(), isTrue);
        }

        final photo = find.byType(AlbumThumbnail);
        final raw = find.descendant(of: photo, matching: find.byType(RawImage));
        bool hasPixels() =>
            raw.evaluate().isNotEmpty &&
            tester.widget<RawImage>(raw).image != null;
        try {
          expect(original.encodedSource, isTrue);
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 512,
                  height: 384,
                  child: GridView.builder(
                    controller: controller,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(128),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                        ),
                    itemCount: 120,
                    itemBuilder: (_, index) => index == 0
                        ? AlbumThumbnail(
                            service: service,
                            entry: entry,
                            edge: 128,
                          )
                        : const ColoredBox(color: Colors.grey),
                  ),
                ),
              ),
            ),
          );
          await waitFor(hasPixels);
          final oldElement = tester.element(photo);
          final pixels = tester.widget<RawImage>(raw).image!.clone();
          try {
            service.setMaintenanceHeld(false);
            await waitFor(
              () =>
                  service.derivativePendingCount == 0 &&
                  service.peekPrepared(entry, targetEdge: 128)?.encodedSource ==
                      false,
            );
            final derivative = service.peekPrepared(entry, targetEdge: 128)!;
            expect(derivative.path, isNot(original.path));
            // No original or source file is available for another native read.
            await tester.runAsync(() async {
              await File(entry.path).delete();
              if (await File(original.path!).exists()) {
                await File(original.path!).delete();
              }
            });
            controller.jumpTo(1024);
            await tester.pump();
            expect(photo, findsNothing);
            controller.jumpTo(0);
            await tester.pump();
            expect(tester.element(photo), isNot(same(oldElement)));
            expect(
              hasPixels(),
              isTrue,
              reason: 'The first returning frame must reuse the decoded original despite the new disk path.',
            );
            expect(
              tester.widget<RawImage>(raw).image!.isCloneOf(pixels),
              isTrue,
            );
            expect(ArtworkDecodeQueue.instance.activeCount, 0);
            expect(ArtworkDecodeQueue.instance.pendingCount, 0);

            if (evictDerivative) {
              final imageElement = tester.element(find.byType(Image));
              service.updateCacheLimits(
                thumbnailBytes: 1,
                originalBytes: 1024 * 1024,
              );
              await waitFor(() => service.wasEvicted(derivative.path!));
              expect(tester.element(find.byType(Image)), same(imageElement));
              expect(
                tester.widget<RawImage>(raw).image!.isCloneOf(pixels),
                isTrue,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              await tester
                  .idle(); // No pump after Android stops drawing frames.
              expect(ArtworkDecodeQueue.instance.pendingCount, 0);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
              await tester.pump();
              expect(
                tester.widget<RawImage>(raw).image!.isCloneOf(pixels),
                isTrue,
              );
              expect(tester.takeException(), isNull);
              return;
            }

            // Once the ordinary memory cache releases the frame, use the durable
            // thumbnail. The old path is a warm-only alias, never a source read.
            controller.jumpTo(1024);
            await tester.pump();
            cache.clear();
            cache.clearLiveImages();
            controller.jumpTo(0);
            await tester.pump();
            await waitFor(hasPixels);
            expect(
              tester.widget<RawImage>(raw).image!.isCloneOf(pixels),
              isFalse,
            );
            expect(tester.takeException(), isNull);
          } finally {
            pixels.dispose();
          }
        } finally {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          service.dispose();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
