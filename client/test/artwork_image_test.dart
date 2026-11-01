import 'dart:async';
import 'dart:io';

import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

Future<ImageInfo> _load(ImageProvider provider) {
  final ready = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (image, _) {
      ready.complete(image);
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      ready.completeError(error, stack);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return ready.future;
}

Future<String> _writeFixture((String, int, int) request) async {
  final (directory, width, height) = request;
  final file = File('$directory/${width}x$height.png');
  await file.writeAsBytes(
    images.encodePng(images.Image(width: width, height: height)),
  );
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'portrait and landscape decodes bound both edges and reuse textures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'artwork-decode-',
      );
      try {
        for (final size in [(100, 300), (300, 100)]) {
          final file = File(
            await compute(_writeFixture, (directory.path, size.$1, size.$2)),
          );
          final provider = artworkImage(file, 128);
          final first = await _load(provider);
          final second = await _load(provider);
          expect(first.image.width, lessThanOrEqualTo(128));
          expect(first.image.height, lessThanOrEqualTo(128));
          expect(
            first.image.width / first.image.height,
            closeTo(size.$1 / size.$2, .1),
          );
          expect(first.image.isCloneOf(second.image), isTrue);
          first.dispose();
          second.dispose();
          await provider.evict();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'dense portrait covers decode enough real pixels without upscaling',
    () async {
      final directory = await Directory.systemTemp.createTemp('dense-poster-');
      try {
        for (final size in [(1200, 1800), (60, 90)]) {
          final file = File(
            await compute(_writeFixture, (directory.path, size.$1, size.$2)),
          );
          final provider = artworkImage(
            file,
            832,
            coverAspectRatio: 2 / 3,
            maxDecodeEdge: 1280,
          );
          final decoded = await _load(provider);
          if (size.$1 == 1200) {
            // A 180x270 logical cover at DPR 3 needs at least 540x810 pixels.
            expect(decoded.image.width, inInclusiveRange(555, 556));
            expect(decoded.image.height, 832);
          } else {
            expect(decoded.image.width, 60);
            expect(decoded.image.height, 90);
          }
          decoded.dispose();
          await provider.evict();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cover crop geometry and pixel budget have independent cache keys',
    () async {
      final directory = await Directory.systemTemp.createTemp('cover-crop-');
      try {
        final file = File(
          await compute(_writeFixture, (directory.path, 2000, 1000)),
        );
        final portrait = artworkImage(
          file,
          768,
          coverAspectRatio: 2 / 3,
          maxDecodeEdge: 1280,
        );
        final landscape = artworkImage(
          file,
          768,
          coverAspectRatio: 2,
          maxDecodeEdge: 1280,
        );
        final lowerBudget = artworkImage(
          file,
          768,
          coverAspectRatio: 2 / 3,
          maxDecodeEdge: 1024,
        );
        final fitted = artworkImage(file, 768);
        final keys = [
          for (final provider in [portrait, landscape, lowerBudget, fitted])
            await provider.obtainKey(ImageConfiguration.empty),
        ];
        expect(keys.toSet(), hasLength(4));
        final croppedPixels = await _load(portrait);
        final repeatedPixels = await _load(portrait);
        final landscapePixels = await _load(landscape);
        final boundedPixels = await _load(lowerBudget);
        final fittedPixels = await _load(fitted);
        expect(croppedPixels.image.width, 1280);
        expect(croppedPixels.image.height, 640);
        expect(landscapePixels.image.width, 768);
        expect(landscapePixels.image.height, 384);
        expect(boundedPixels.image.width, 1024);
        expect(boundedPixels.image.height, 512);
        expect(fittedPixels.image.width, 768);
        expect(fittedPixels.image.height, 384);
        expect(croppedPixels.image.isCloneOf(repeatedPixels.image), isTrue);
        expect(croppedPixels.image.isCloneOf(landscapePixels.image), isFalse);
        for (final pixels in [
          croppedPixels,
          repeatedPixels,
          landscapePixels,
          boundedPixels,
          fittedPixels,
        ]) {
          pixels.dispose();
        }
        for (final provider in [portrait, landscape, lowerBudget, fitted]) {
          await provider.evict();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('a wall cover upgrades its resident pixels when DPR increases', (
    tester,
  ) async {
    late Directory directory;
    late String path;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('poster-dpr-');
      path = await compute(_writeFixture, (directory.path, 1200, 1800));
    });
    Widget cover(double ratio) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: ratio),
        child: Center(
          child: SizedBox(
            width: 180,
            height: 270,
            child: MediaArtwork(thumbnail: path, loadWhileScrolling: true),
          ),
        ),
      ),
    );
    Future<RawImage> waitForHeight(int height) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump();
        final images = tester.widgetList<RawImage>(find.byType(RawImage));
        for (final image in images) {
          if ((image.image?.height ?? 0) >= height) return image;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      throw TestFailure(
        'The wall cover did not decode at least $height pixels.',
      );
    }

    try {
      await tester.pumpWidget(cover(1));
      final small = (await waitForHeight(270)).image!;
      expect(small.height, lessThan(640));
      await tester.pumpWidget(cover(3));
      // Retain the already available frame while the native decode is queued.
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      final dense = (await waitForHeight(810)).image!;
      expect(dense.width, greaterThanOrEqualTo(540));
      expect(dense.height, greaterThanOrEqualTo(810));
      expect(dense.width, lessThanOrEqualTo(1280));
      expect(dense.height, lessThanOrEqualTo(1280));
      expect(
        tester.widget<Image>(find.byType(Image)).filterQuality,
        FilterQuality.medium,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
