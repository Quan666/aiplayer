import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _PosterModel extends AppModel {
  _PosterModel(super.store, super.documents, {PosterCache? posterCache})
    : _providedCache = posterCache,
      super(backgroundWork: false);

  final PosterCache? _providedCache;

  int networkRequests = 0;
  late final _cache = PosterCache(
    directory: Directory('${documents.path}/posters'),
    createClient: () {
      networkRequests++;
      throw StateError('A saved cover must work offline');
    },
  );

  @override
  PosterCache get posterCache => _providedCache ?? _cache;

  @override
  void dispose() {
    posterCache.close();
    super.dispose();
  }
}

const _smallPoster = 'https://image.tmdb.org/t/p/w500/viewer.jpg';
const _originalPoster = 'https://image.tmdb.org/t/p/original/viewer.jpg';

class _DelayedOriginalCache extends PosterCache {
  _DelayedOriginalCache(Directory directory) : super(directory: directory);

  final originalReady = Completer<File?>();
  final requests = <String>[];
  int originalDownloads = 0;

  @override
  Future<File?> load(String url) {
    requests.add(url);
    if (url == _originalPoster && resolvedFile(url) == null) {
      originalDownloads++;
      return originalReady.future;
    }
    return super.load(url);
  }
}

Finder get _viewer => find.byKey(const ValueKey('media-poster-viewer'));

Iterable<RawImage> _viewerImages(WidgetTester tester) => tester
    .widgetList<RawImage>(
      find.descendant(of: _viewer, matching: find.byType(RawImage)),
    )
    .where((raw) => raw.image != null);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump();
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail(reason);
}

Future<void> _withOriginalPoster(
  WidgetTester tester,
  Future<void> Function(_DelayedOriginalCache cache, File original) check,
) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late Directory root;
  late File original;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('original-poster-viewer-');
    original = File('${root.path}/original.png');
    await original.writeAsBytes(
      images.encodePng(images.Image(width: 1200, height: 1800)),
    );
  });
  final store = AppStore(':memory:');
  final cache = _DelayedOriginalCache(Directory('${root.path}/posters'));
  final model = _PosterModel(store, root, posterCache: cache);
  try {
    await tester.runAsync(() async {
      await cache.restore(
        _smallPoster,
        images.encodePng(images.Image(width: 100, height: 150)),
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
                  title: '原图测试作品',
                  poster: _smallPoster,
                  availableEpisodes: 1,
                  videoCount: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _waitFor(
      tester,
      () => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((raw) => raw.image != null),
      'The detail thumbnail did not decode.',
    );
    expect(cache.requests, isNot(contains(_originalPoster)));
    await tester.tap(find.byKey(const ValueKey('details-poster')));
    await tester.pump();
    expect(_viewerImages(tester), isNotEmpty);
    expect(
      _viewerImages(tester).every((raw) => raw.image!.height <= 150),
      isTrue,
      reason:
          'The existing small cover is visible before the original arrives.',
    );
    await tester.pumpAndSettle();
    expect(cache.requests, contains(_originalPoster));
    expect(cache.originalDownloads, 1);
    await check(cache, original);
    expect(tester.takeException(), isNull);
  } finally {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    });
  }
}

void main() {
  testWidgets('original replaces the small cover and zoom decodes more pixels', (
    tester,
  ) async {
    await _withOriginalPoster(tester, (cache, original) async {
      // The delayed original must not turn a loaded detail cover into a blank.
      expect(_viewerImages(tester), isNotEmpty);
      await tester.runAsync(() async {
        await cache.restore(_originalPoster, await original.readAsBytes());
      });
      cache.originalReady.complete(cache.resolvedFile(_originalPoster));
      await _waitFor(
        tester,
        () => _viewerImages(tester).any((raw) => raw.image!.height >= 800),
        'The viewer never replaced its small cover with original-image pixels.',
      );
      expect(_viewerImages(tester).length, 1);
      final fittedHeight = _viewerImages(tester).single.image!.height;
      final point = tester.getCenter(find.byType(InteractiveViewer));
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(point);
      await _waitFor(
        tester,
        () => _viewerImages(tester).any((raw) => raw.image!.height == 1800),
        'Double-tap zoom must decode sharper pixels from the original.',
      );
      expect(
        _viewerImages(tester).single.image!.height,
        greaterThan(fittedHeight),
      );

      ResizeImage displayedProvider() => tester
          .widgetList<Image>(
            find.descendant(of: _viewer, matching: find.byType(Image)),
          )
          .map((image) => image.image)
          .whereType<ResizeImage>()
          .singleWhere(
            (provider) =>
                (provider.imageProvider as FileImage).file.path ==
                cache.cachedFile(_originalPoster).path,
          );
      final zoomedProvider = displayedProvider();
      final interactive = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      interactive.transformationController!.value = Matrix4.diagonal3Values(
        4.2,
        4.2,
        1,
      )..setTranslationRaw(point.dx * (1 - 4.2), point.dy * (1 - 4.2), 0);
      await tester.pump();
      expect(
        displayedProvider(),
        same(zoomedProvider),
        reason: 'An in-progress gesture must not repeatedly start new decodes.',
      );
      interactive.onInteractionEnd!(ScaleEndDetails());
      await _waitFor(
        tester,
        () => displayedProvider().width == 4096,
        'Gesture completion must upgrade decoding within the memory bound.',
      );
      final largestProvider = displayedProvider();
      late Object largestKey;
      largestProvider.obtainKey(ImageConfiguration.empty).then((key) {
        largestKey = key;
      });
      await _waitFor(
        tester,
        () =>
            !PaintingBinding.instance.imageCache
                .statusForKey(largestKey)
                .pending &&
            _viewerImages(tester).length == 1 &&
            _viewerImages(tester).single.image!.height == 1800,
        'The largest decode must complete before the viewer closes.',
      );
      interactive.transformationController!.value = Matrix4.identity();
      interactive.onInteractionEnd!(ScaleEndDetails());
      await tester.pumpAndSettle();
      expect(
        displayedProvider(),
        same(largestProvider),
        reason: 'Zooming out reuses the sharper decoded image.',
      );

      await tester.tap(find.byTooltip('关闭封面'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('details-poster')));
      await tester.pump();
      expect(
        _viewerImages(tester).any((raw) => raw.image!.height > 150),
        isTrue,
        reason: 'Reopening immediately reuses the cached original.',
      );
      await tester.pumpAndSettle();
      expect(cache.originalDownloads, 1);
    });
  });

  testWidgets('failed original leaves the saved cover visible and zoomable', (
    tester,
  ) async {
    await _withOriginalPoster(tester, (cache, _) async {
      cache.originalReady.complete(null);
      await tester.pumpAndSettle();
      expect(_viewerImages(tester), isNotEmpty);
      expect(
        _viewerImages(tester).every((raw) => raw.image!.height <= 150),
        isTrue,
      );
      final interactive = find.byType(InteractiveViewer);
      final point = tester.getCenter(interactive);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(interactive)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        closeTo(2.5, .01),
      );
      expect(_viewerImages(tester), isNotEmpty);
      expect(cache.originalDownloads, 1);
    });
  });

  testWidgets('a late original waits for resume without background frames', (
    tester,
  ) async {
    await _withOriginalPoster(tester, (cache, original) async {
      final imageCache = PaintingBinding.instance.imageCache;
      // The fitted screen's decode bucket is 896 physical pixels. Querying the
      // synchronous key must never itself resolve or start the image provider.
      late Object originalKey;
      artworkImage(original, 896).obtainKey(ImageConfiguration.empty).then((
        key,
      ) {
        originalKey = key;
      });
      expect(imageCache.statusForKey(originalKey).tracked, isFalse);
      final requestCount = cache.requests.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      cache.originalReady.complete(original);
      await tester.idle();
      // Android may deliver no frames at all after paused. Let only the late
      // asynchronous result arrive; pumping would conceal lifecycle mistakes.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      expect(imageCache.statusForKey(originalKey).tracked, isFalse);
      expect(cache.requests.length, requestCount);
      expect(_viewerImages(tester), isNotEmpty);
      expect(
        _viewerImages(tester).every((raw) => raw.image!.height <= 150),
        isTrue,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _waitFor(
        tester,
        () => _viewerImages(tester).any((raw) => raw.image!.height >= 800),
        'The original should decode normally after returning to the foreground.',
      );
      expect(cache.originalDownloads, 1);
    });
  });

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
