import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

/// Run from client/ with the real desktop engine:
/// xvfb-run -a flutter drive -d linux --profile --no-pub
///   --driver=test_driver/artwork_performance_driver.dart
///   --target=integration_test/artwork_performance_test.dart
///   --dart-define=ARTWORK_ARTIFACT_DIR=/root/aiplayer/artifacts
///
/// This is a component performance probe, not a full-app or device benchmark.
/// Cold means decoded images and PosterCache path handles are cold; OS filesystem
/// caches are not purged. No frame-time threshold is asserted: software rendering
/// provides useful comparisons but cannot establish mobile/GPU performance.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('measure artwork decoding, scrolling and details transitions', (
    tester,
  ) async {
    const artifactDirectory = String.fromEnvironment(
      'ARTWORK_ARTIFACT_DIR',
      defaultValue: '../artifacts',
    );
    final root = await Directory.systemTemp.createTemp('artwork-performance-');
    final posters = Directory('${root.path}/posters');
    await posters.create();
    final results = <Map<String, Object?>>[];
    final urls = List.generate(
      18,
      (index) => 'https://artwork.invalid/poster-$index.jpg',
    );
    final thumbnails = <String>[];
    var networkAttempts = 0;
    PosterCache createCache() => PosterCache(
      directory: posters,
      createClient: () {
        networkAttempts++;
        throw StateError('The performance fixture must remain offline');
      },
    );
    var cache = createCache();

    try {
      // Encoding fixtures is deliberately outside the measured UI workload and
      // off the UI isolate. Distinct paths give each card a real cache entry.
      final fixtureBytes = await compute(_encodeFixtures, 0);
      for (var index = 0; index < urls.length; index++) {
        await cache.cachedFile(urls[index]).writeAsBytes(fixtureBytes[0]);
        final thumbnail = File('${root.path}/thumbnail-$index.jpg');
        await thumbnail.writeAsBytes(fixtureBytes[1]);
        thumbnails.add(thumbnail.path);
      }
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();
      // IntegrationTest's setSurfaceSize changes layout constraints but not the
      // view metrics read by MediaQuery. Use the actual native window so viewport
      // visibility checks in the app and in this probe refer to the same screen.
      final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
      debugPrint('Artwork benchmark native viewport: $viewport');

      Future<void> reset({required bool cold}) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        if (cold) {
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          cache.close();
          cache = createCache();
        }
      }

      for (final kind in ['poster', 'continue-watching']) {
        for (final cold in [true, false]) {
          await reset(cold: cold);
          final controller = ScrollController();
          try {
            final measurement = await _measure(tester, () async {
              await tester.pumpWidget(
                _Gallery(
                  cache: cache,
                  urls: urls,
                  thumbnails: thumbnails,
                  controller: controller,
                  landscape: kind == 'continue-watching',
                ),
              );
              final initial = await _waitForVisibleImages(
                tester,
                stage: '$kind/${cold ? 'cold' : 'warm'}/initial',
              );
              var decodedChecks = initial;
              // Animate actual scroll positions to exercise frame scheduling,
              // shared scrolling deferral, and images entering the viewport.
              for (final fraction in [.3, .6, 1.0, .6, .3, 0.0]) {
                await controller.animateTo(
                  controller.position.maxScrollExtent * fraction,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.linear,
                );
                await tester.pump();
                decodedChecks += await _waitForVisibleImages(
                  tester,
                  stage: '$kind/${cold ? 'cold' : 'warm'}/scroll-$fraction',
                );
              }
              return decodedChecks;
            });
            results.add({
              'scenario': '$kind-${cold ? 'cold' : 'warm'}',
              ...measurement,
            });
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
          }
        }
      }

      for (final cold in [true, false]) {
        await reset(cold: cold);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        await tester.pumpAndSettle();
        final measurement = await _measure(tester, () async {
          var decodedChecks = 0;
          for (var index = 0; index < 3; index++) {
            unawaited(
              navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('详情')),
                    body: Center(
                      child: SizedBox(
                        width: 360,
                        height: 540,
                        child: MediaArtwork(poster: urls[index], cache: cache),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            decodedChecks += await _waitForVisibleImages(
              tester,
              stage: 'details/${cold ? 'cold' : 'warm'}/$index',
            );
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
          }
          return decodedChecks;
        });
        results.add({
          'scenario': 'details-${cold ? 'cold' : 'warm'}',
          ...measurement,
        });
      }

      expect(networkAttempts, 0);
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
        'platform': Platform.operatingSystem,
        'dartVersion': Platform.version,
        'viewport': _sizeData(viewport),
        'devicePixelRatio': tester.view.devicePixelRatio,
        'fixture': {
          'poster': {
            'width': 1500,
            'height': 2250,
            'bytes': fixtureBytes[0].length,
          },
          'thumbnail': {
            'width': 1920,
            'height': 1080,
            'bytes': fixtureBytes[1].length,
          },
          'distinctFilesPerKind': urls.length,
        },
        'coldDefinition':
            'Flutter ImageCache and PosterCache path handles reset; '
            'persistent files retained; OS file cache not reset',
        'scope':
            'MediaArtwork component; local JPEGs; no network or video capture; '
            'synthetic gallery and details route; no full-app or device guarantee',
        'networkAttempts': networkAttempts,
        'scenarios': results,
      };
      final artifacts = Directory(artifactDirectory);
      await artifacts.create(recursive: true);
      final file = File('${artifacts.path}/artwork-performance.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      binding.reportData = report;
      debugPrint('Artwork performance report: ${file.absolute.path}');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      cache.close();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<Map<String, Object?>> _measure(
  WidgetTester tester,
  Future<int> Function() action,
) async {
  // Engine timings arrive in batches (up to roughly one second in profile).
  // Drain previous samples before attaching and allow the last batch to arrive.
  await Future<void>.delayed(const Duration(milliseconds: 1100));
  final frames = <ui.FrameTiming>[];
  void collect(List<ui.FrameTiming> batch) => frames.addAll(batch);
  WidgetsBinding.instance.addTimingsCallback(collect);
  final watch = Stopwatch()..start();
  late int decodedChecks;
  try {
    decodedChecks = await action();
    watch.stop();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  } finally {
    WidgetsBinding.instance.removeTimingsCallback(collect);
  }
  expect(
    frames,
    isNotEmpty,
    reason: 'A real engine must report rendered frames',
  );
  expect(tester.takeException(), isNull);
  return {
    'elapsedMs': watch.elapsedMilliseconds,
    'decodedVisibleImageChecks': decodedChecks,
    'frameCount': frames.length,
    'buildMs': _distribution(frames.map((frame) => frame.buildDuration)),
    'rasterMs': _distribution(frames.map((frame) => frame.rasterDuration)),
    'totalSpanMs': _distribution(frames.map((frame) => frame.totalSpan)),
    'imageCacheEntries': PaintingBinding.instance.imageCache.currentSize,
    'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
  };
}

Map<String, Object> _distribution(Iterable<Duration> values) {
  final samples = values.map((value) => value.inMicroseconds / 1000).toList()
    ..sort();
  return {
    'count': samples.length,
    'p50': samples[(samples.length * .5).ceil() - 1],
    'p95': samples[(samples.length * .95).ceil() - 1],
    'max': samples.last,
    'over16_67ms': samples.where((value) => value > 1000 / 60).length,
    'over33_33ms': samples.where((value) => value > 1000 / 30).length,
  };
}

Future<int> _waitForVisibleImages(
  WidgetTester tester, {
  required String stage,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var visible = 0, decoded = 0;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    final list = find.byType(ListView);
    final viewport = list.evaluate().isEmpty
        ? Offset.zero &
              (tester.view.physicalSize / tester.view.devicePixelRatio)
        : tester.getRect(list);
    visible = 0;
    decoded = 0;
    for (final element in find.byType(MediaArtwork).evaluate()) {
      final artwork = find.byElementPredicate(
        (candidate) => candidate == element,
      );
      if (!tester.getRect(artwork).overlaps(viewport)) continue;
      visible++;
      final images = tester.widgetList<RawImage>(
        find.descendant(of: artwork, matching: find.byType(RawImage)),
      );
      if (images.any((image) => image.image != null)) decoded++;
    }
    if (visible > 0 && decoded == visible) return decoded;
  }
  final diagnostic = _artworkDiagnostics(tester, stage);
  final encoded = const JsonEncoder.withIndent('  ').convert(diagnostic);
  debugPrint('Artwork decode failure:\n$encoded');
  const artifactDirectory = String.fromEnvironment(
    'ARTWORK_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  await Directory(artifactDirectory).create(recursive: true);
  await File(
    '$artifactDirectory/artwork-performance-failure.json',
  ).writeAsString(encoded);
  fail(
    'Visible artwork did not decode within 45 seconds at $stage: '
    '$decoded/$visible. See artwork-performance-failure.json',
  );
}

Map<String, double> _sizeData(Size size) => {
  'width': size.width,
  'height': size.height,
};

Map<String, double> _rectData(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Map<String, Object?> _artworkDiagnostics(WidgetTester tester, String stage) {
  final nativeSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final list = find.byType(ListView);
  final viewport = list.evaluate().isEmpty
      ? Offset.zero & nativeSize
      : tester.getRect(list);
  final missing = <Map<String, Object?>>[];
  for (final element in find.byType(MediaArtwork).evaluate()) {
    final artwork = find.byElementPredicate(
      (candidate) => candidate == element,
    );
    final rect = tester.getRect(artwork);
    if (!rect.overlaps(viewport)) continue;
    final images = tester.widgetList<RawImage>(
      find.descendant(of: artwork, matching: find.byType(RawImage)),
    );
    if (images.any((image) => image.image != null)) continue;
    final widget = element.widget as MediaArtwork;
    final mediaQuery = MediaQuery.of(element);
    var clipped = rect.intersect(Offset.zero & mediaQuery.size);
    final ancestorClips = <Map<String, double>>[];
    RenderObject? ancestor = element.findRenderObject()?.parent;
    while (ancestor != null) {
      if (ancestor is RenderAbstractViewport) {
        final clip = MatrixUtils.transformRect(
          ancestor.getTransformTo(null),
          ancestor.paintBounds,
        );
        ancestorClips.add(_rectData(clip));
        clipped = clipped.intersect(clip);
      }
      ancestor = ancestor.parent;
    }
    missing.add({
      'poster': widget.poster,
      'thumbnail': widget.thumbnail,
      'rect': _rectData(rect),
      'mediaQuerySize': _sizeData(mediaQuery.size),
      'mediaQueryPixelRatio': mediaQuery.devicePixelRatio,
      'ancestorViewportClips': ancestorClips,
      'visibleAfterAppClipping': !clipped.isEmpty,
      'routeIsCurrent': ModalRoute.of(element)?.isCurrent,
      'scrollScopeActive': ArtworkScrollScope.maybeOf(element)?.value,
      'horizontalScrolling': Scrollable.maybeOf(
        element,
        axis: Axis.horizontal,
      )?.position.isScrollingNotifier.value,
      'deferHorizontal': Scrollable.recommendDeferredLoadingForContext(
        element,
        axis: Axis.horizontal,
      ),
      'resolvedPosterFile': widget.cache?.resolvedFile(widget.poster)?.path,
      'imageWidgets': find
          .descendant(of: artwork, matching: find.byType(Image))
          .evaluate()
          .length,
    });
  }
  return {
    'stage': stage,
    'nativePhysicalSize': _sizeData(tester.view.physicalSize),
    'nativeLogicalSize': _sizeData(nativeSize),
    'devicePixelRatio': tester.view.devicePixelRatio,
    'listViewport': _rectData(viewport),
    'missing': missing,
  };
}

class _Gallery extends StatelessWidget {
  const _Gallery({
    required this.cache,
    required this.urls,
    required this.thumbnails,
    required this.controller,
    required this.landscape,
  });

  final PosterCache cache;
  final List<String> urls, thumbnails;
  final ScrollController controller;
  final bool landscape;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          height: landscape ? 180 : 240,
          child: ArtworkScrollScope(
            child: ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemExtent: landscape ? 332 : 172,
              itemCount: urls.length,
              itemBuilder: (_, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: MediaArtwork(
                  poster: landscape ? '' : urls[index],
                  thumbnail: landscape ? thumbnails[index] : null,
                  cache: cache,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

List<Uint8List> _encodeFixtures(int seed) {
  final random = math.Random(seed);
  return [(1500, 2250), (1920, 1080)].map((size) {
    final image = img.Image(width: size.$1, height: size.$2);
    for (final pixel in image) {
      final noise = random.nextInt(40);
      pixel.setRgb(
        (pixel.x * 200 ~/ size.$1 + noise).clamp(0, 255),
        (pixel.y * 200 ~/ size.$2 + noise).clamp(0, 255),
        ((pixel.x + pixel.y) ~/ 10 + noise) % 256,
      );
    }
    return img.encodeJpg(image, quality: 88);
  }).toList();
}
