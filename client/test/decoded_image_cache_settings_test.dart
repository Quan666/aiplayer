import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'image memory budget applies live without discarding mounted artwork',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('image-cache-budget-'),
      ))!;
      final store = AppStore(':memory:')
        ..setLocal('settings', {'decodedImageCacheMiB': 128});
      final model = AppModel(store, root, backgroundWork: false);
      final cache = PaintingBinding.instance.imageCache;
      final originalBudget = cache.maximumSizeBytes;
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(cache.maximumSizeBytes, 128 * 1024 * 1024);
        final app = tester.element(find.byType(MaterialApp));
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: Center(
                child: SizedBox.square(
                  dimension: 128,
                  child: MediaArtwork(
                    thumbnail: File('assets/branding/app_icon.png')
                        .absolute
                        .path,
                    loadWhileScrolling: true,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 150; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage).last).image !=
                  null) {
            break;
          }
        }
        await tester.pumpAndSettle();
        final artwork = find.descendant(
          of: find.byType(MediaArtwork),
          matching: find.byType(RawImage),
        );
        final pixels = tester.widget<RawImage>(artwork).image!.clone();
        try {
          final live = cache.liveImageCount;
          final cached = cache.currentSize;
          final bytes = cache.currentSizeBytes;
          expect(live, greaterThan(0));
          expect(cached, greaterThan(0));
          await tester.runAsync(
            () => model.updatePreferences({'decodedImageCacheMiB': 32}),
          );
          expect(cache.maximumSizeBytes, 32 * 1024 * 1024);
          expect(cache.liveImageCount, live);
          expect(cache.currentSize, cached);
          expect(cache.currentSizeBytes, bytes);
          await tester.pump();
          expect(tester.element(find.byType(MaterialApp)), same(app));
          expect(
            tester.widget<RawImage>(artwork).image!.isCloneOf(pixels),
            isTrue,
          );
          await tester.runAsync(
            () => model.updatePreferences({'decodedImageCacheMiB': 256}),
          );
          expect(cache.maximumSizeBytes, 256 * 1024 * 1024);
          expect(cache.liveImageCount, live);
          expect(cache.currentSize, cached);
          expect(tester.takeException(), isNull);
        } finally {
          pixels.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await tester.runAsync(model.flushMetadataTasks);
        store.dispose();
        cache.maximumSizeBytes = originalBudget;
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
