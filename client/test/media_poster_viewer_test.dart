import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _PosterModel extends AppModel {
  _PosterModel(super.store, super.documents) : super(backgroundWork: false);

  int networkRequests = 0;
  late final _cache = PosterCache(
    directory: Directory('${documents.path}/posters'),
    createClient: () {
      networkRequests++;
      throw StateError('A saved cover must work offline');
    },
  );

  @override
  PosterCache get posterCache => _cache;

  @override
  void dispose() {
    _cache.close();
    super.dispose();
  }
}

void main() {
  testWidgets('detail cover opens, zooms and closes using the cached artwork', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('poster-viewer-');
    final store = AppStore(':memory:');
    final model = _PosterModel(store, root);
    const poster = 'https://offline.invalid/cover.png';
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    try {
      await tester.runAsync(() async {
        await model.posterCache.restore(
          poster,
          await File('assets/branding/app_icon.png').readAsBytes(),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: MediaDetailsHeader(
                  model: model,
                  details: const MediaCollectionDetails(
                    title: '封面测试作品',
                    poster: poster,
                    availableEpisodes: 3,
                    videoCount: 3,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump();
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null)) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('details-poster')));
      await tester.pump();
      final viewer = find.byKey(const ValueKey('media-poster-viewer'));
      expect(viewer, findsOneWidget);
      final viewerImages = find.descendant(
        of: viewer,
        matching: find.byType(RawImage),
      );
      expect(
        tester
            .widgetList<RawImage>(viewerImages)
            .any((image) => image.image != null),
        isTrue,
        reason:
            'Opening a larger cover reuses the displayed image immediately.',
      );
      await tester.pumpAndSettle();
      final interactive = find.byType(InteractiveViewer);
      final transform = tester
          .widget<InteractiveViewer>(interactive)
          .transformationController!;
      final point = tester.getCenter(interactive);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(2.5, .01));
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 1);
      await tester.tap(find.byTooltip('关闭封面'));
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(find.byType(MediaDetailsHeader), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('details-poster')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(model.networkRequests, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
