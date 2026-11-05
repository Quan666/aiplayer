import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

Future<String> _fixtures() async {
  final directory = await Directory.systemTemp.createTemp('artwork-resume-');
  for (final name in ['first', 'second']) {
    final image = raster.Image(width: 768, height: 512);
    raster.fill(
      image,
      color: raster.ColorRgb8(name == 'first' ? 230 : 20, 50, 120),
    );
    await File('${directory.path}/$name.jpg')
        .writeAsBytes(raster.encodeJpg(image));
  }
  final animation = raster.Image(width: 64, height: 64)..frameDuration = 80;
  raster.fill(animation, color: raster.ColorRgb8(230, 40, 80));
  final second = raster.Image(width: 64, height: 64)..frameDuration = 80;
  raster.fill(second, color: raster.ColorRgb8(20, 180, 210));
  animation.addFrame(second);
  await File('${directory.path}/animated.gif')
      .writeAsBytes(raster.encodeGif(animation));
  return directory.path;
}

Future<void> _nativeFrames(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 100; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (ready() && ArtworkDecodeQueue.instance.activeCount == 0) {
      await tester.pump();
      return;
    }
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets(
    'retained animated artwork pauses offscreen and resumes without a new decode stream',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(() => Isolate.run(_fixtures)))!;
      final cache = PaintingBinding.instance.imageCache;
      final queue = ArtworkDecodeQueue.instance;
      Widget shell(bool active) => MaterialApp(
        home: TickerMode(
          enabled: active,
          child: Center(
            child: SizedBox.square(
              dimension: 64,
              child: MediaArtwork(
                thumbnail: '$root/animated.gif',
                maxDecodeEdge: 64,
                loadWhileScrolling: true,
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(shell(true));
        await _nativeFrames(
          tester,
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((raw) => raw.image != null),
        );
        await tester.pumpWidget(shell(false));
        final paused = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!
            .clone();
        try {
          cache
            ..clear()
            ..clearLiveImages();
          for (var frame = 0; frame < 4; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 100));
            expect(
              tester
                  .widget<RawImage>(find.byType(RawImage))
                  .image!
                  .isCloneOf(paused),
              isTrue,
            );
          }
          await tester.pumpWidget(shell(true));
          expect(cache.pendingImageCount, 0);
          var advanced = false;
          for (var frame = 0; frame < 8 && !advanced; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 100));
            advanced = !tester
                .widget<RawImage>(find.byType(RawImage))
                .image!
                .isCloneOf(paused);
          }
          expect(advanced, isTrue);
        } finally {
          paused.dispose();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _nativeFrames(tester, () => queue.activeCount == 0);
        cache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => Directory(root).delete(recursive: true));
      }
    },
  );

  testWidgets(
    'hidden artwork resumes its retained stream without rereading an evicted file',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final root = (await tester.runAsync(() => Isolate.run(_fixtures)))!;
      final cache = PaintingBinding.instance.imageCache;
      final queue = ArtworkDecodeQueue.instance;
      final failures = <String>[];
      Widget shell({
        bool active = true,
        String name = 'first',
        bool secondCopy = false,
      }) => MaterialApp(
        home: TickerMode(
          enabled: active,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 384,
                  height: 256,
                  child: MediaArtwork(
                    thumbnail: '$root/$name.jpg',
                    maxDecodeEdge: 384,
                    loadWhileScrolling: true,
                    onThumbnailError: (path, error) => failures.add(path),
                  ),
                ),
                if (secondCopy)
                  SizedBox(
                    width: 192,
                    height: 128,
                    child: MediaArtwork(
                      thumbnail: '$root/$name.jpg',
                      maxDecodeEdge: 384,
                      loadWhileScrolling: true,
                      onThumbnailError: (path, error) => failures.add(path),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      bool decoded() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);

      try {
        cache
          ..clear()
          ..clearLiveImages();
        await tester.pumpWidget(shell());
        await _nativeFrames(tester, decoded);
        final element = tester.element(find.byType(Image));
        final provider = tester.widget<Image>(find.byType(Image)).image;
        final pixels = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!
            .clone();
        try {
          await tester.pumpWidget(shell(active: false));
          cache
            ..clear()
            ..clearLiveImages();
          // A hidden, mounted cell already owns its frame. Cache pruning must not
          // turn route resume into another disk read or bypass decode admission.
          await tester.runAsync(() => File('$root/first.jpg').delete());
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.idle(); // Deliberately no pump while paused.
          expect(queue.pendingCount, 0);
          expect(queue.activeCount, 0);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(shell());
          expect(tester.element(find.byType(Image)), same(element));
          expect(tester.widget<Image>(find.byType(Image)).image, provider);
          expect(
            cache.pendingImageCount,
            0,
            reason: 'TickerMode resume must reuse the retained completer, not start an unqueued file read',
          );
          for (var frame = 0; frame < 3; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
            expect(
              tester
                  .widget<RawImage>(find.byType(RawImage))
                  .image!
                  .isCloneOf(pixels),
              isTrue,
            );
          }
          expect(failures, isEmpty);
          expect(cache.pendingImageCount, 0);

          await tester.pumpWidget(shell(secondCopy: true));
          await tester.pump();
          final shared = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .toList();
          expect(shared, hasLength(2));
          expect(
            shared.every((raw) => raw.image?.isCloneOf(pixels) == true),
            isTrue,
          );
          expect(
            tester
                .widgetList<Image>(find.byType(Image))
                .every((image) => image.image == provider),
            isTrue,
          );
          expect(cache.pendingImageCount, 0);
          expect(queue.activeCount, 0);
          expect(queue.pendingCount, 0);
          expect(failures, isEmpty);

          await tester.pumpWidget(shell(name: 'second'));
          await _nativeFrames(
            tester,
            () =>
                decoded() &&
                !tester
                    .widget<RawImage>(find.byType(RawImage))
                    .image!
                    .isCloneOf(pixels),
          );
          expect(
            tester.widget<Image>(find.byType(Image)).image,
            isNot(provider),
          );
          expect(failures, isEmpty);
        } finally {
          pixels.dispose();
        }
        await tester.pumpWidget(const SizedBox());
        cache
          ..clear()
          ..clearLiveImages();
        expect(cache.liveImageCount, 0);
        expect(cache.pendingImageCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await _nativeFrames(tester, () => queue.activeCount == 0);
        cache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => Directory(root).delete(recursive: true));
      }
    },
  );
}
