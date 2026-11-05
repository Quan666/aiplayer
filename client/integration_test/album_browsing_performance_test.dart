import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

// From client/ (run serially with other native builds and Flutter tests):
// dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24' env
// LIBGL_ALWAYS_SOFTWARE=1 flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/album_browsing_performance_test.dart
// --dart-define=ALBUM_PROFILE_ARTIFACT_DIR=/absolute/artifact/path
// Actual AlbumPage/AlbumViewer, workers and loopback WebDAV. Linux software
// rendering and synthetic JPEGs do not establish TV FPS, NAS speed or power use.
const _jpegWidth = int.fromEnvironment(
  'ALBUM_PROFILE_WIDTH',
  defaultValue: 800,
);
const _jpegHeight = int.fromEnvironment(
  'ALBUM_PROFILE_HEIGHT',
  defaultValue: 600,
);
const _jpegNoise = bool.fromEnvironment('ALBUM_PROFILE_NOISE');
const _rapidSwipeCount = 16;
const _settledSwipeCount = int.fromEnvironment(
  'ALBUM_PROFILE_SETTLED_SWIPES',
  defaultValue: 48,
);
// Optional compressed-byte pressure without changing decoded geometry. Padding
// follows JPEG EOI and is reported separately from realistic pixel/noise input.
const _minimumJpegBytes = int.fromEnvironment('ALBUM_PROFILE_JPEG_BYTES');
const _firstViewportOnly = bool.fromEnvironment(
  'ALBUM_PROFILE_FIRST_VIEWPORT_ONLY',
);
const _workingSetOnly = bool.fromEnvironment('ALBUM_PROFILE_WORKING_SET_ONLY');
const _exportSourceJpegs = bool.fromEnvironment(
  'ALBUM_PROFILE_EXPORT_SOURCE_JPEGS',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile album cold open, warm scroll and exact viewer return', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    const groups = int.fromEnvironment(
      'ALBUM_PROFILE_GROUPS',
      defaultValue: 1200,
    );
    final fixture = await _AlbumFixture.start(groups);
    final root = Directory(fixture.root);
    final store = AppStore.openExisting('${fixture.root}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    final wall = find.byKey(const ValueKey('album-wall'));
    final screen = GlobalKey();
    final phases = <Map<String, Object?>>[];
    final returns = <Map<String, Object?>>[];
    final latency = <String, Object?>{};
    final idleSamples = <Map<String, Object?>>[];
    Map<String, Object?>? heldSwipe;
    Map<String, Object?>? recoveredImage;
    Map<String, Object?>? longBrowse;
    Map<String, Object?>? afterIdle, afterVisible;
    var peakPendingJobs = 0, peakActiveJobs = 0, maxDecodedEdge = 0;
    var peakPendingDerivatives = 0;
    var peakActiveDerivatives = 0;
    Map<String, Object?>? initialDerivedCache;
    Future<double>? initialDerivedReady;
    AlbumImageService? wallImages;
    Element? wallElement;

    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: wall, matching: find.byType(Scrollable)).first,
        )
        .position;

    Finder currentViewerPhoto() => find.descendant(
      of: find.byKey(const ValueKey('album-current-page')),
      matching: find.byType(AlbumThumbnail),
    );

    AlbumThumbnail selectedPhoto() =>
        tester.widget<AlbumThumbnail>(currentViewerPhoto());

    bool viewerImageReady() {
      final current = currentViewerPhoto();
      if (current.evaluate().length != 1) return false;
      final selected = selectedPhoto();
      final service = selected.service;
      final prepared = service.peek(selected.entry) ?? selected.initialResult;
      final artwork = find.descendant(
        of: current,
        matching: find.byType(MediaArtwork),
      );
      return artwork.evaluate().isNotEmpty &&
          prepared?.encodedSource == true &&
          prepared?.sourcePath == selected.entry.path &&
          tester.widget<MediaArtwork>(artwork.first).thumbnail ==
              prepared?.path &&
          find.byKey(const ValueKey('album-other-page')).evaluate().isEmpty &&
          _decodedImages(tester, current).any(
            (image) =>
                math.max(image.width, image.height) >=
                math.min(math.max(_jpegWidth, _jpegHeight), selected.edge),
          ) &&
          service.pendingCount == 0 &&
          service.activeCount == 0 &&
          ArtworkDecodeQueue.instance.pendingCount == 0 &&
          ArtworkDecodeQueue.instance.activeCount == 0;
    }

    Future<void> screenshot(String name) async {
      final boundary =
          screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final capture = await boundary.toImage(pixelRatio: 1);
      final png = await capture.toByteData(format: ui.ImageByteFormat.png);
      capture.dispose();
      await compute(_writeScreenshot, (name, png!.buffer.asUint8List()));
    }

    void sampleCapacity() {
      // No test APIs or tree walks inside frame callbacks: they can conflict
      // with a guarded pump and would contaminate measured frame work.
      final service = wallImages;
      if (service == null) return;
      peakPendingJobs = math.max(peakPendingJobs, service.pendingCount);
      peakActiveJobs = math.max(peakActiveJobs, service.activeCount);
      peakPendingDerivatives = math.max(
        peakPendingDerivatives,
        service.derivativePendingCount,
      );
      peakActiveDerivatives = math.max(
        peakActiveDerivatives,
        service.derivativeActiveCount,
      );
    }

    Future<void> derivativesReady(String label) async {
      await _waitFor(() {
        sampleCapacity();
        return wallImages?.derivativePendingCount == 0;
      }, '$label derived thumbnails persisted');
    }

    Future<void> resolve(String label, {bool waitForQueue = true}) async {
      // Observe the layout invalidated by a jump before inspecting children.
      await tester.pump();
      await _waitFor(() {
        sampleCapacity();
        final state = _visibleImages(tester, wallElement);
        maxDecodedEdge = math.max(maxDecodedEdge, state.maxEdge);
        return state.visible > 0 && state.missing == 0;
      }, '$label visible thumbnails');
      if (waitForQueue) {
        await _waitFor(
          () => wallImages?.pendingCount == 0,
          '$label bounded queue settled',
        );
      }
    }

    Future<void> measure(
      String name,
      Future<void> Function() action, {
      bool requireFrames = true,
    }) async {
      // Drain delayed engine timing batches before starting another phase.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final frames = <ui.FrameTiming>[];
      var observing = true;
      var peakNativePending = 0, peakUnqueuedNativePending = 0;
      void sampleNative() {
        final pending = PaintingBinding.instance.imageCache.pendingImageCount;
        peakNativePending = math.max(peakNativePending, pending);
        peakUnqueuedNativePending = math.max(
          peakUnqueuedNativePending,
          pending - ArtworkDecodeQueue.instance.activeCount,
        );
      }

      void collect(List<ui.FrameTiming> values) => frames.addAll(values);
      void sample(Duration _) {
        if (!observing) return;
        sampleCapacity();
        sampleNative();
        // Observe scheduled production frames; do not request extra frames.
        WidgetsBinding.instance.addPostFrameCallback(sample);
      }

      WidgetsBinding.instance.addTimingsCallback(collect);
      WidgetsBinding.instance.addPostFrameCallback(sample);
      final watch = Stopwatch()..start();
      try {
        sampleNative();
        await action();
        sampleNative();
        watch.stop();
        observing = false;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        observing = false;
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      if (requireFrames) {
        expect(frames, isNotEmpty, reason: '$name must render real frames');
      }
      phases.add({
        'phase': name,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'frames': frames.length,
        'peakObservedNativePending': peakNativePending,
        'peakObservedNativePendingOutsideDecodeQueue':
            peakUnqueuedNativePending,
        // Sorting and report JSON encoding happen in _writeReport's isolate.
        'buildUs': [
          for (final frame in frames) frame.buildDuration.inMicroseconds,
        ],
        'rasterUs': [
          for (final frame in frames) frame.rasterDuration.inMicroseconds,
        ],
        'totalSpanUs': [
          for (final frame in frames) frame.totalSpan.inMicroseconds,
        ],
      });
    }

    try {
      expect(fixture.isolateId, isNot(Isolate.current.hashCode));
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await measure('cold-page-open', () async {
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: MaterialApp(
              theme: GlassPalette.theme(),
              home: AlbumPage(
                model: model,
                source: fixture.source,
                initialPath: 'album/',
                initialName: 'Profile album',
              ),
            ),
          ),
        );
        await _waitFor(
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              tester
                      .widget<AlbumWall>(find.byType(AlbumWall))
                      .snapshot
                      .items
                      .length ==
                  groups,
          'first grouped wall',
        );
        wallElement = wall.evaluate().single;
        wallImages =
            (find.byType(AlbumThumbnail).evaluate().first.widget
                    as AlbumThumbnail)
                .service;
        // Observe completion independently of screenshot/phase-drain waits.
        // This future never gates the first pixels or first viewport timing.
        initialDerivedReady = () async {
          await _waitFor(
            () => wallImages!.derivativePendingCount > 0,
            'initial derived work admitted',
          );
          await _waitFor(
            () =>
                wallImages!.pendingCount == 0 &&
                wallImages!.derivativePendingCount == 0,
            'initial derived work finished',
          );
          return watch.elapsedMicroseconds / 1000;
        }();
        latency['firstGridMs'] = watch.elapsedMicroseconds / 1000;
        await _waitFor(
          () => _visibleImages(tester, wallElement).decoded > 0,
          'first decoded thumbnail',
        );
        latency['firstThumbnailMs'] = watch.elapsedMicroseconds / 1000;
        await WidgetsBinding.instance.endOfFrame;
        latency['firstThumbnailFrameMs'] = watch.elapsedMicroseconds / 1000;
        await resolve('initial', waitForQueue: false);
        latency['initialViewportReadyMs'] = watch.elapsedMicroseconds / 1000;
        latency['initialVisibleImages'] = _visibleImages(
          tester,
          wallElement,
        ).visible;
        afterVisible = await fixture.stats();
      });

      // Name sorting must not start a full-directory EXIF pass. Once the
      // bounded visible requests finish, observe idle without forcing a frame.
      await _waitFor(() => wallImages?.pendingCount == 0, 'visible queue idle');
      final beforeIdle = await fixture.stats();
      final idleSnapshot = tester
          .widget<AlbumWall>(find.byType(AlbumWall))
          .snapshot;
      await measure('default-name-sort-idle-after-thumbnails', () async {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        sampleCapacity();
        afterIdle = await fixture.stats();
        expect(wallImages?.pendingCount, 0);
        expect(afterIdle!['gets'], beforeIdle['gets']);
        expect(
          tester.widget<AlbumWall>(find.byType(AlbumWall)).snapshot,
          same(idleSnapshot),
        );
        idleSamples.add({'automaticIndex': false, ...afterIdle!});
      }, requireFrames: false);

      await screenshot('album-initial-viewport.png');
      final beforeDerivatives = await fixture.stats();
      await measure('persist-initial-small-image-cache', () async {
        await derivativesReady('initial viewport');
        latency['initialDerivedCacheReadyMs'] = await initialDerivedReady!;
        latency['derivedCacheAfterViewportMs'] =
            (latency['initialDerivedCacheReadyMs'] as double) -
            (latency['initialViewportReadyMs'] as double);
      }, requireFrames: false);
      final afterDerivatives = await fixture.stats();
      expect(afterDerivatives['gets'], beforeDerivatives['gets']);
      initialDerivedCache = await compute(_derivedCacheStats, root.path);
      expect(
        initialDerivedCache!['files'],
        greaterThanOrEqualTo(latency['initialVisibleImages'] as int),
      );

      if (_firstViewportOnly) {
        binding.reportData = await compute(_writeReport, <String, Object?>{
          'harnessRevision': 14,
          'runStatus': 'complete',
          'firstViewportOnly': true,
          'mode': kProfileMode
              ? 'profile'
              : (kReleaseMode ? 'release' : 'debug'),
          'platform': Platform.operatingSystem,
          'fixture': {
            'photoGroups': groups,
            'listedFiles': fixture.files,
            'jpegWidth': _jpegWidth,
            'jpegHeight': _jpegHeight,
            'jpegNoise': _jpegNoise,
            'minimumJpegBytesIncludingPostEoiPadding': _minimumJpegBytes,
          },
          'scope': 'Actual AlbumPage, production catalog/image workers, separate-isolate loopback WebDAV. Generated JPEGs. Linux software rendering does not establish phone/TV FPS or power use.',
          'startup': latency,
          'initialDerivedCache': initialDerivedCache,
          'network': {'afterCold': afterVisible, 'afterIdle': afterIdle},
          'queue': {
            'peakObservedPending': peakPendingJobs,
            'peakObservedActive': peakActiveJobs,
            'peakObservedDerivativePending': peakPendingDerivatives,
            'peakObservedDerivativeActive': peakActiveDerivatives,
          },
          'phases': phases,
        });
        return;
      }

      final afterCold = afterVisible!;
      final viewport = position().viewportDimension;
      final travel = math.min(position().maxScrollExtent, viewport * 6);
      // Prepare every viewport in the measured strip before reporting warm
      // scroll. This cost and its source transfers are reported separately.
      await measure('prepare-six-viewports', () async {
        for (var offset = 0.0; offset < travel; offset += viewport * .65) {
          position().jumpTo(offset);
          await resolve('prepare $offset');
          await derivativesReady('prepare $offset');
        }
        position().jumpTo(travel);
        await resolve('prepare end');
        await derivativesReady('prepare end');
        position().jumpTo(0);
        await resolve('prepare return');
      });
      final beforeWarm = await fixture.stats();
      await measure('warm-fast-scroll-down-and-back', () async {
        await position().animateTo(
          travel,
          duration: const Duration(milliseconds: 1200),
          curve: Curves.linear,
        );
        await position().animateTo(
          0,
          duration: const Duration(milliseconds: 1200),
          curve: Curves.linear,
        );
        await resolve('warm scroll end');
      });
      final afterWarm = await fixture.stats();
      expect(
        afterWarm['gets'],
        beforeWarm['gets'],
        reason: 'Warm strip uses disk/decoded thumbnails without source re-download',
      );

      final retainedOffset = math.min(travel, viewport * 2 + 37.25);
      position().jumpTo(retainedOffset);
      await resolve('viewer origin');
      await derivativesReady('viewer origin');
      final viewportRect = tester.getRect(wall);
      Finder visiblePhoto({bool last = false}) {
        final matches = find.byElementPredicate((element) {
          if (element.widget is! AlbumThumbnail) return false;
          final object = element.renderObject;
          if (object is! RenderBox || !object.hasSize) return false;
          final rect = object.localToGlobal(Offset.zero) & object.size;
          return viewportRect.contains(rect.topLeft + const Offset(1, 1)) &&
              viewportRect.contains(rect.bottomRight - const Offset(1, 1));
        });
        return last ? matches.last : matches.first;
      }

      final beforeViewers = await fixture.stats();
      if (!_workingSetOnly) {
        await measure('three-viewer-open-and-back-cycles', () async {
          for (var round = 0; round < 3; round++) {
            final before = position().pixels;
            final visibleBefore = _visibleImages(tester, wallElement).paths;
            final watch = Stopwatch()..start();
            await tester.tap(visiblePhoto());
            await _waitFor(
              () => find.byType(AlbumViewer).evaluate().isNotEmpty,
              'viewer route',
            );
            await _waitFor(
              () => tester
                  .widgetList<RawImage>(
                    find.descendant(
                      of: find.byType(AlbumViewer),
                      matching: find.byType(RawImage),
                    ),
                  )
                  .any((image) => image.image != null),
              'viewer image',
            );
            final opened = watch.elapsedMicroseconds / 1000;
            final previewSourceCounts = await fixture.stats();
            // Immediate pixels may be the warm wall preview. Let the requested
            // full image and bounded adjacent prefetch complete before asserting
            // cross-session cache reuse, rather than canceling them immediately.
            await _waitFor(
              viewerImageReady,
              'viewer full image decoded and adjacent prefetch cached',
            );
            final fullReady = watch.elapsedMicroseconds / 1000;
            final sourceCounts = await fixture.stats();
            await _waitFor(
              () =>
                  ModalRoute.of(tester.element(find.byType(AlbumViewer)))!
                      .animation!
                      .isCompleted,
              'viewer enter slide completed',
            );
            await tester.tap(
              find.descendant(
                of: find.byType(AlbumViewer),
                matching: find.byType(BackButton),
              ),
            );
            await _waitFor(
              () => find.byType(AlbumViewer).evaluate().isEmpty,
              'viewer pop',
            );
            final returnFrame = _visibleImages(tester, wallElement);
            expect(returnFrame.visible, greaterThan(0));
            expect(
              returnFrame.missing,
              0,
              reason: 'Retain wall pixels on return',
            );
            await resolve('viewer return $round');
            expect(
              position().pixels,
              closeTo(before, .01),
              reason: 'Viewer return must retain fractional row offset',
            );
            expect(_visibleImages(tester, wallElement).paths, visibleBefore);
            returns.add({
              'round': round + 1,
              'openToViewerPixelsMs': opened,
              'openToPreviewPixelsMs': opened,
              'openToFullImageAndPrefetchCachedMs': fullReady,
              'sourceGetsAtPreview': previewSourceCounts['gets'],
              'beforeOffset': before,
              'afterOffset': position().pixels,
              'absoluteOffsetError': (position().pixels - before).abs(),
              'sourceGetsAfterOpen': sourceCounts['gets'],
              'visibleThumbnailsAtReturn': returnFrame.visible,
              'missingThumbnailsAtReturn': returnFrame.missing,
            });
          }
        });
      }
      final afterViewers = await fixture.stats();
      if (!_workingSetOnly) {
        expect(
          returns[1]['sourceGetsAfterOpen'],
          returns[2]['sourceGetsAfterOpen'],
          reason: 'Repeated full-view image is cached across viewer sessions',
        );
        await measure('held-half-page-drag-between-warm-photos', () async {
          await tester.tap(visiblePhoto());
          await _waitFor(
            () => find.byType(AlbumViewer).evaluate().isNotEmpty,
            'held-drag viewer',
          );
          await _waitFor(viewerImageReady, 'held-drag images decoded');
          await _waitFor(
            () =>
                ModalRoute.of(tester.element(find.byType(AlbumViewer)))!
                    .animation!
                    .isCompleted,
            'held-drag route settled',
          );
          final canvas = find.byKey(const ValueKey('album-photo-canvas'));
          final canvasBounds = tester.getRect(canvas);
          final beforePath = selectedPhoto().entry.path;
          final beforeNetwork = await fixture.stats();
          final gesture = await tester.startGesture(tester.getCenter(canvas));
          await gesture.moveBy(
            Offset(-canvasBounds.width / 2, 0),
            timeStamp: const Duration(milliseconds: 500),
          );
          final current = find.byKey(const ValueKey('album-current-page'));
          final adjacent = find.byKey(const ValueKey('album-other-page'));
          Rect pageBounds(Finder page) => tester.getRect(
            find.byWidget(tester.widget<FractionalTranslation>(page).child!),
          );
          await _waitFor(
            () =>
                adjacent.evaluate().length == 1 &&
                _decodedImages(tester, current).isNotEmpty &&
                _decodedImages(tester, adjacent).isNotEmpty &&
                (pageBounds(current).left -
                            (canvasBounds.left - canvasBounds.width / 2))
                        .abs() <
                    .01,
            'both held pages rendered at half width',
          );
          final currentBounds = pageBounds(current);
          final adjacentBounds = pageBounds(adjacent);
          final gap = adjacentBounds.left - currentBounds.right;
          expect(gap, closeTo(12, .01));
          expect(currentBounds.intersect(canvasBounds).width, greaterThan(0));
          expect(adjacentBounds.intersect(canvasBounds).width, greaterThan(0));
          expect(selectedPhoto().entry.path, beforePath);
          expect(
            find.byKey(const ValueKey('album-image-loading')),
            findsNothing,
          );
          final held = Stopwatch()..start();
          await Future<void>.delayed(const Duration(milliseconds: 250));
          expect(pageBounds(current), currentBounds);
          expect(pageBounds(adjacent), adjacentBounds);
          expect(selectedPhoto().entry.path, beforePath);
          await screenshot('album-viewer-held-half-page.png');
          held.stop();
          heldSwipe = {
            'selectedBeforeDrag': beforePath,
            'selectedWhileHeld': selectedPhoto().entry.path,
            'selectedUnchangedWhileHeld': true,
            'currentDecodedImages': _decodedImages(tester, current).length,
            'adjacentDecodedImages': _decodedImages(tester, adjacent).length,
            'gapLogicalPixels': gap,
            'heldDurationMs': held.elapsedMicroseconds / 1000,
            'canvasBounds': _rectValues(canvasBounds),
            'currentBounds': _rectValues(currentBounds),
            'adjacentBounds': _rectValues(adjacentBounds),
            'loadingVisibleWhileHeld': false,
            'sourceGetsBefore': beforeNetwork['gets'],
            'screenshot': 'album-viewer-held-half-page.png',
          };
          await gesture.up(timeStamp: const Duration(milliseconds: 1000));
          await _waitFor(
            () => selectedPhoto().entry.path != beforePath,
            'held drag advances after release',
          );
          await _waitFor(viewerImageReady, 'released page decoded');
          heldSwipe!['selectedAfterRelease'] = selectedPhoto().entry.path;
          heldSwipe!['sourceGetsAfterRelease'] = (await fixture
              .stats())['gets'];
          await tester.tap(
            find.descendant(
              of: find.byType(AlbumViewer),
              matching: find.byType(BackButton),
            ),
          );
          await _waitFor(
            () => find.byType(AlbumViewer).evaluate().isEmpty,
            'held-drag viewer return',
          );
          final returned = _visibleImages(tester, wallElement);
          expect(returned.missing, 0);
          expect(position().pixels, closeTo(retainedOffset, .01));
          heldSwipe!['missingThumbnailsAtReturn'] = returned.missing;
        });
      }
      var swipePeakPending = 0, swipePeakActive = 0;
      final swipedPaths = <String>[];
      // Start beyond the six warmed viewports and open its last visible photo.
      // Advance beyond the wall's warm/cache extent into cold files.
      final coldSwipeOffset = _workingSetOnly
          ? retainedOffset
          : position().maxScrollExtent * .7 + .25;
      if (!_workingSetOnly) {
        position().jumpTo(coldSwipeOffset);
        await resolve('cold swipe origin');
      }
      final beforeRapidSwipes = await fixture.stats();
      if (!_workingSetOnly) {
        await measure(
          'sixteen-rapid-viewer-swipes-during-image-loading',
          () async {
            await tester.tap(visiblePhoto(last: true));
            await _waitFor(
              () => find.byType(AlbumViewer).evaluate().isNotEmpty,
              'swipe viewer',
            );
            await _waitFor(
              () =>
                  ModalRoute.of(tester.element(find.byType(AlbumViewer)))!
                      .animation!
                      .isCompleted,
              'swipe viewer enter slide completed',
            );
            for (var swipe = 0; swipe < _rapidSwipeCount; swipe++) {
              final beforePath = selectedPhoto().entry.path;
              final canvas = find.byKey(const ValueKey('album-photo-canvas'));
              await tester.drag(
                canvas,
                Offset(-tester.getSize(canvas).width * .4, 0),
              );
              await _waitFor(
                () => selectedPhoto().entry.path != beforePath,
                'swipe ${swipe + 1} selected another photo',
              );
              swipedPaths.add(selectedPhoto().entry.path);
              final service = selectedPhoto().service;
              swipePeakPending = math.max(
                swipePeakPending,
                service.pendingCount,
              );
              swipePeakActive = math.max(swipePeakActive, service.activeCount);
              expect(
                service.pendingCount,
                lessThanOrEqualTo(AlbumImageService.maxPending),
              );
              expect(
                service.activeCount,
                lessThanOrEqualTo(service.maxConcurrentRequests),
              );
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            await _waitFor(
              viewerImageReady,
              'last swipe has decoded pixels and settled image/decode queues',
            );
            await tester.tap(
              find.descendant(
                of: find.byType(AlbumViewer),
                matching: find.byType(BackButton),
              ),
            );
            await _waitFor(
              () => find.byType(AlbumViewer).evaluate().isEmpty,
              'swipe viewer return',
            );
            await resolve('rapid swipe return');
            expect(position().pixels, closeTo(coldSwipeOffset, .01));
          },
        );
      }
      final afterRapidSwipes = await fixture.stats();
      if (!_workingSetOnly) {
        expect(
          afterRapidSwipes['gets'],
          greaterThan(beforeRapidSwipes['gets'] as int),
        );
      }
      if (_settledSwipeCount > 0) {
        final count = math.min(_settledSwipeCount, groups ~/ 8);
        final samples = <Map<String, Object?>>[];
        final selectedPaths = <String>[];
        final beforeOffset = position().pixels;
        final beforePaths = _visibleImages(tester, wallElement).paths;
        final origin = tester.widget<AlbumThumbnail>(visiblePhoto());
        final before = await fixture.stats();
        Map<String, Object?>? pausedSample;

        Future<void> swipe(bool forward, int index) async {
          final path = selectedPhoto().entry.path;
          final canvas = find.byKey(const ValueKey('album-photo-canvas'));
          await tester.drag(
            canvas,
            Offset(tester.getSize(canvas).width * (forward ? -.4 : .4), 0),
          );
          await _waitFor(
            () => selectedPhoto().entry.path != path,
            'settled ${forward ? 'forward' : 'reverse'} swipe $index',
          );
          await _waitFor(
            viewerImageReady,
            'settled photo $index fully decoded',
          );
          final service = selectedPhoto().service;
          expect(service.activeCount, 0);
          expect(service.pendingCount, 0);
          if (forward) selectedPaths.add(selectedPhoto().entry.path);
          if (index % 8 == 0 || index == count) {
            samples.add(
              _cacheSample('${forward ? 'forward' : 'reverse'}-$index'),
            );
          }
        }

        await measure('long-settled-viewer-browse-forward', () async {
          await tester.tap(visiblePhoto());
          await _waitFor(viewerImageReady, 'long-browse initial image');
          await _waitFor(
            () =>
                ModalRoute.of(tester.element(find.byType(AlbumViewer)))!
                    .animation!
                    .isCompleted,
            'long-browse route settled',
          );
          samples.add(_cacheSample('before-forward'));
          for (var index = 1; index <= count; index++) {
            await swipe(true, index);
          }
        });
        final afterForward = await fixture.stats();
        final originalDiskAfterForward = await compute(
          _originalCacheStats,
          fixture.root,
        );
        final beforeShortReversal = await fixture.stats();
        await measure('long-browse-nearby-direction-reversal', () async {
          await swipe(false, 1);
          await swipe(true, 1);
        });
        final afterShortReversal = await fixture.stats();
        expect(
          afterShortReversal['gets'],
          beforeShortReversal['gets'],
          reason: 'The immediately adjacent pages stay in the original window',
        );
        await measure('long-browse-background-without-pump', () async {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          // Deliberately no pump/endOfFrame while paused. Lifecycle listeners
          // must stop admission even on devices that draw no background frames.
          final paused = await fixture.stats();
          final derivativesPaused = wallImages!.derivativePendingCount;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final afterPause = await fixture.stats();
          expect(afterPause['gets'], paused['gets']);
          expect(selectedPhoto().service.active, isFalse);
          expect(ArtworkDecodeQueue.instance.activeCount, 0);
          expect(ArtworkDecodeQueue.instance.pendingCount, 0);
          expect(wallImages!.derivativePendingCount, derivativesPaused);
          expect(wallImages!.derivativeActiveCount, 0);
          pausedSample = {
            'forcedPumpsWhilePaused': 0,
            'sourceGetsBefore': paused['gets'],
            'sourceGetsAfter': afterPause['gets'],
            'wallDerivativePendingBefore': derivativesPaused,
            'wallDerivativePendingAfter': wallImages!.derivativePendingCount,
            'wallDerivativeActiveWhilePaused':
                wallImages!.derivativeActiveCount,
            ..._cacheSample('paused'),
          };
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await _waitFor(viewerImageReady, 'long-browse resumed pixels');
        }, requireFrames: false);
        await measure('long-settled-viewer-browse-reverse', () async {
          for (var index = 1; index <= count; index++) {
            await swipe(false, index);
          }
          expect(selectedPhoto().entry.path, origin.entry.path);
        });
        final afterReverse = await fixture.stats();
        final reverseGets =
            (afterReverse['gets'] as int) - (afterForward['gets'] as int);
        // Original retention is a nearby window plus a bounded recent tail.
        // A distant reverse traversal may reread sources even when the total
        // album would fit the configured byte ceiling; thumbnails stay separate.
        final jpegBytes = (afterReverse['jpegBytes'] as List).cast<int>();
        final upperSourceBytes = (count + 5) * jpegBytes.reduce(math.max);
        final fitsBudget =
            upperSourceBytes < wallImages!.maxCacheBytes * .8 &&
            (count + 5) * 4 < wallImages!.maxCacheFiles;
        final returnWatch = Stopwatch();
        await measure('long-browse-return-to-retained-wall', () async {
          final viewerContext = tester.element(find.byType(AlbumViewer));
          final viewerRoute = ModalRoute.of(viewerContext)!;
          returnWatch.start();
          await Navigator.of(viewerContext).maybePop();
          await _waitFor(
            () => viewerRoute.animation?.status == AnimationStatus.reverse,
            'long-browse viewer reverse animation started',
          );
          expect(
            wallImages!.active,
            isFalse,
            reason: 'Wall background work stays paused during viewer reverse animation',
          );
          await _waitFor(
            () => find.byType(AlbumViewer).evaluate().isEmpty,
            'long-browse viewer removed',
          );
          returnWatch.stop();
          final returned = _visibleImages(tester, wallElement);
          expect(
            returned.missing,
            0,
            reason: 'Returning after many full decodes retains wall pixels',
          );
          expect(returned.paths, beforePaths);
          expect(position().pixels, closeTo(beforeOffset, .01));
          await resolve('long-browse retained wall');
          expect(wallImages!.active, isTrue);
          samples.add(_cacheSample('after-wall-return'));
        });
        final beforeReopen = await fixture.stats();
        await measure('long-browse-warm-reopen', () async {
          await tester.tap(visiblePhoto());
          await _waitFor(viewerImageReady, 'long-browse warm reopen decoded');
          expect(selectedPhoto().entry.path, origin.entry.path);
        });
        final afterReopen = await fixture.stats();
        if (fitsBudget) {
          expect(afterReopen['gets'], beforeReopen['gets']);
        }
        await Navigator.of(tester.element(find.byType(AlbumViewer))).maybePop();
        await _waitFor(
          () => find.byType(AlbumViewer).evaluate().isEmpty,
          'long-browse reopen returned',
        );
        await resolve('long-browse final wall');
        longBrowse = {
          'fullyDecodedForwardSwipes': count,
          'fullyDecodedReverseSwipes': count,
          'distinctForwardPhotos': selectedPaths.toSet().length,
          'sourceGetsBefore': before['gets'],
          'sourceGetsAfterForward': afterForward['gets'],
          'sourceGetsAfterReverse': afterReverse['gets'],
          'reverseSourceGets': reverseGets,
          'nearbyReversalSourceGets':
              (afterShortReversal['gets'] as int) -
              (beforeShortReversal['gets'] as int),
          'originalDiskAfterForward': originalDiskAfterForward,
          'sourceGetsBeforeReopen': beforeReopen['gets'],
          'sourceGetsAfterReopen': afterReopen['gets'],
          'allVisitedSourcesFitByteCeiling': fitsBudget,
          'originalRetentionPolicy': 'At most five nearby protected entries plus eight recent originals within min(original budget / 4, 128 MiB); a distant revisit may reread the source.',
          'wallReturnMs': returnWatch.elapsedMicroseconds / 1000,
          'wallReturnMissingThumbnails': 0,
          'retainedOffset': beforeOffset,
          'cacheSamples': samples,
          'background': pausedSample,
          'memoryScope': 'Flutter cache accounting excludes live image textures and native GPU allocations; RSS includes every isolate and the generated fixture. These samples detect growth and cache pressure, not device memory or battery guarantees.',
        };
      }
      if (_workingSetOnly) {
        expect(longBrowse, isNotNull);
        await screenshot('album-working-set-return.png');
        binding.reportData = await compute(_writeReport, <String, Object?>{
          'harnessRevision': 14,
          'runStatus': 'complete',
          'workingSetOnly': true,
          'mode': kProfileMode
              ? 'profile'
              : (kReleaseMode ? 'release' : 'debug'),
          'platform': Platform.operatingSystem,
          'fixture': {
            'photoGroups': groups,
            'listedFiles': fixture.files,
            'jpegWidth': _jpegWidth,
            'jpegHeight': _jpegHeight,
            'jpegNoise': _jpegNoise,
            'minimumJpegBytesIncludingPostEoiPadding': _minimumJpegBytes,
          },
          'scope': 'Actual AlbumPage/AlbumViewer, separate-isolate loopback WebDAV, durable thumbnail warm scrolling and bounded original working set. Linux software rendering and padded JPEGs do not establish phone/TV FPS, network latency or battery use.',
          'startup': latency,
          'initialDerivedCache': initialDerivedCache,
          'network': {
            'afterCold': afterVisible,
            'afterIdle': afterIdle,
            'beforeWarmScroll': beforeWarm,
            'afterWarmScroll': afterWarm,
          },
          'warmScrollDistanceEachWay': travel,
          'longSettledBrowse': longBrowse,
          'queue': {
            'peakObservedPending': peakPendingJobs,
            'peakObservedActive': peakActiveJobs,
            'peakObservedDerivativePending': peakPendingDerivatives,
            'peakObservedDerivativeActive': peakActiveDerivatives,
          },
          'phases': phases,
        });
        return;
      }
      await measure('missing-prepared-image-recovers-after-remount', () async {
        final beforeOffset = position().pixels;
        final cell = tester.element(visiblePhoto());
        final thumbnail = cell.widget as AlbumThumbnail;
        final prepared = thumbnail.service.peek(thumbnail.entry)!;
        final failedPath = prepared.path!;
        expect(
          p.isWithin(root.path, failedPath) &&
              p
                  .relative(failedPath, from: root.path)
                  .startsWith('album-images-v'),
          isTrue,
          reason: 'Only the disposable prepared cache may be removed.',
        );
        final before = await fixture.stats();
        // Dispose this cell, then drop its decoded cache so a retained Image
        // cannot hide the removed file. Production image reads still run via
        // their actual native decode and bounded worker recovery paths.
        position().jumpTo(0);
        await resolve('cache recovery away');
        expect(
          cell.mounted,
          isFalse,
          reason:
              'The missing-file check must not pass using a retained old cell.',
        );
        await _waitFor(
          () =>
              ArtworkDecodeQueue.instance.activeCount == 0 &&
              ArtworkDecodeQueue.instance.pendingCount == 0,
          'away native decodes settled',
        );
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await compute(_removePreparedImage, failedPath);
        expect(
          thumbnail.service.peek(thumbnail.entry)?.path,
          failedPath,
          reason: 'Reproduce a stale in-memory path after another cache owner prunes it.',
        );
        final watch = Stopwatch()..start();
        position().jumpTo(beforeOffset);
        await resolve('missing cache recovery');
        final firstVisibleMs = watch.elapsedMicroseconds / 1000;
        await _waitFor(() {
          final current = thumbnail.service.peek(thumbnail.entry);
          return current?.path != null &&
              !identical(current, prepared) &&
              !thumbnail.service.wasEvicted(current!.path!);
        }, 'new worker-prepared cache result');
        final repairedPath = thumbnail.service.peek(thumbnail.entry)!.path!;
        final restored = await compute(_preparedImageLength, repairedPath);
        await resolve('repaired cache pixels');
        expect(restored, greaterThan(0));
        expect(_visibleImages(tester, wallElement).missing, 0);
        recoveredImage = {
          'sourcePath': thumbnail.entry.path,
          'repairedPathChanged': repairedPath != failedPath,
          'recoveredBytes': restored,
          'returnToVisiblePixelsMs': firstVisibleMs,
          'returnToRestoredCacheAndPixelsMs': watch.elapsedMicroseconds / 1000,
          'missingThumbnailsAfterRecovery': 0,
          'sourceGetsBefore': before['gets'],
          'sourceGetsAfter': (await fixture.stats())['gets'],
        };
      });
      // Preserve completed cache measurements if the subsequent UI smoke check
      // fails. The complete report below replaces this explicit checkpoint.
      await compute(_writeReport, <String, Object?>{
        'harnessRevision': 14,
        'runStatus': 'partial: cache scenarios passed, slideshow check pending',
        'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
        'platform': Platform.operatingSystem,
        'startup': latency,
        'initialDerivedCache': initialDerivedCache,
        'longSettledBrowse': longBrowse,
        'missingPreparedImageRecovery': recoveredImage,
        'phases': phases,
      });
      await measure('slideshow-toolbar-and-settings', () async {
        await tester.tap(visiblePhoto());
        await _waitFor(viewerImageReady, 'settings viewer decoded');
        await _waitFor(
          () =>
              ModalRoute.of(tester.element(find.byType(AlbumViewer)))!
                  .animation!
                  .isCompleted,
          'settings viewer route',
        );
        await tester.tap(find.byTooltip('更多选项'));
        await _waitFor(
          () => find.text('开始幻灯片').evaluate().isNotEmpty,
          'start slideshow menu',
        );
        await _waitFor(
          () =>
              ModalRoute.of(tester.element(find.text('开始幻灯片')))
                  ?.animation
                  ?.isCompleted ==
              true,
          'start slideshow menu settled',
        );
        await tester.tap(find.text('开始幻灯片'));
        await _waitFor(
          () => find
              .byKey(const ValueKey('album-viewer-toolbar'))
              .evaluate()
              .isEmpty,
          'slideshow begins with hidden controls',
        );
        await tester.drag(
          find.byKey(const ValueKey('album-photo-canvas')),
          const Offset(0, 180),
        );
        await _waitFor(
          () => find.byTooltip('幻灯片').evaluate().isNotEmpty,
          'slideshow settings button',
        );
        await tester.tap(find.byTooltip('幻灯片'));
        await _waitFor(
          () => find.text('幻灯片设置').evaluate().isNotEmpty,
          'slideshow settings sheet',
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await screenshot('album-slideshow-settings.png');
        await tester.tap(find.text('退出幻灯片模式'));
        await _waitFor(
          () => find.text('幻灯片设置').evaluate().isEmpty,
          'exit slideshow',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlbumViewer),
            matching: find.byType(BackButton),
          ),
        );
        await _waitFor(
          () => find.byType(AlbumViewer).evaluate().isEmpty,
          'settings viewer return',
        );
      });
      expect(peakPendingJobs, lessThanOrEqualTo(AlbumImageService.maxPending));
      expect(
        peakActiveJobs,
        lessThanOrEqualTo(wallImages!.maxConcurrentRequests),
      );
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'harnessRevision': 14,
        'runStatus': 'complete',
        'longSettledBrowse': longBrowse,
        'missingPreparedImageRecovery': recoveredImage,
        'sort': 'name-ascending',
        'automaticCaptureIndex': false,
        'heldHalfPageDrag': heldSwipe,
        'rapidSwipes': {
          'count': _rapidSwipeCount,
          'distinctSelectedPhotos': swipedPaths.toSet().length,
          'sourceGetsBefore': beforeRapidSwipes['gets'],
          'sourceGetsAfter': afterRapidSwipes['gets'],
          'peakObservedPending': swipePeakPending,
          'peakObservedActive': swipePeakActive,
        },
        'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
        'platform': Platform.operatingSystem,
        'scope': 'Actual AlbumPage and AlbumViewer, production catalog/image workers, real loopback WebDAV on a separate isolate. Generated JPEG patterns with RAW/XMP grouping companions; dimensions and noise are recorded below. Warm strip spans six viewports, not the entire album. Linux Xvfb software rendering; no TV/phone frame-rate, NAS/WAN throughput or power claim.',
        'coldDefinition': 'Fresh application thumbnail directory and empty Flutter decoded-image cache. Origin JPEG bytes are prepared in the fixture worker before measurement; no WAN or disk-origin latency is simulated.',
        'credentialScope': 'FlutterSecureStorage test credential channel returns empty credentials. Model, source adapter, WebDAV parsing, catalog worker and image pipeline are production implementations.',
        'viewerDefinition': 'Immediate pixels can be the warm wall preview. Full readiness requires the selected page to expose a prepared image path and non-null RawImage pixels, with both its image worker and the shared native decode queue drained. Delayed loading visibility is never used as a decoded-image readiness signal. The held half-page phase verifies two decoded photographs, a 12px page gap, and an unchanged selection until release.',
        'firstThumbnailDefinition': 'First visible RawImage with decoded pixels, plus its next frame boundary. Engine frame timings and the initial full viewport PNG are recorded separately.',
        'fixture': {
          'photoGroups': groups,
          'listedFiles': fixture.files,
          'isolateId': fixture.isolateId,
          'jpegWidth': _jpegWidth,
          'jpegHeight': _jpegHeight,
          'jpegNoise': _jpegNoise,
          'minimumJpegBytesIncludingPostEoiPadding': _minimumJpegBytes,
        },
        'viewport': {
          'width':
              tester.view.physicalSize.width / tester.view.devicePixelRatio,
          'height':
              tester.view.physicalSize.height / tester.view.devicePixelRatio,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'startup': latency,
        'initialDerivedCache': initialDerivedCache,
        'network': {
          'afterCold': afterCold,
          'afterIdle': afterIdle,
          'idleSamples': idleSamples,
          'beforeWarm': beforeWarm,
          'afterWarm': afterWarm,
          'beforeViewers': beforeViewers,
          'afterViewers': afterViewers,
        },
        'queue': {
          'scope': 'Observed wall-session queue on scheduled app frames and visible-image waits; viewer has its own bounded image worker.',
          'peakObservedPending': peakPendingJobs,
          'pendingLimit': AlbumImageService.maxPending,
          'peakObservedActive': peakActiveJobs,
          'peakObservedDerivativePending': peakPendingDerivatives,
          'peakObservedDerivativeActive': peakActiveDerivatives,
          'activeLimit': wallImages!.maxConcurrentRequests,
        },
        'maxObservedWallDecodedEdge': maxDecodedEdge,
        'warmScrollDistanceEachWay': travel,
        'viewerReturns': returns,
        'phases': phases,
      };
      binding.reportData = await compute(_writeReport, report);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Map<String, Object?> _cacheSample(String phase) {
  final cache = PaintingBinding.instance.imageCache;
  return {
    'phase': phase,
    'keepAliveImages': cache.currentSize,
    'keepAliveBytes': cache.currentSizeBytes,
    'maximumKeepAliveBytes': cache.maximumSizeBytes,
    'liveImages': cache.liveImageCount,
    'pendingImages': cache.pendingImageCount,
    'decodeQueueActive': ArtworkDecodeQueue.instance.activeCount,
    'decodeQueuePending': ArtworkDecodeQueue.instance.pendingCount,
    'processRssBytes': ProcessInfo.currentRss,
  };
}

Future<void> _waitFor(bool Function() condition, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
    // fullyLive observes the app's own frame scheduling; no forced idle frames.
    await Future<void>.delayed(const Duration(milliseconds: 8));
  }
}

void _removePreparedImage(String path) => File(path).deleteSync();

int _preparedImageLength(String path) => File(path).lengthSync();

Map<String, Object?> _derivedCacheStats(String root) {
  final directory = Directory(
    p.join(root, 'album-images-v1', 'album-thumbnails-v1'),
  );
  var files = 0, bytes = 0;
  if (directory.existsSync()) {
    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.jpg')) continue;
      files++;
      bytes += file.lengthSync();
    }
  }
  return {'files': files, 'bytes': bytes};
}

Map<String, Object?> _originalCacheStats(String root) {
  final directory = Directory(
    p.join(root, 'album-images-v1', 'album-images-v2'),
  );
  var originals = 0, bytes = 0;
  if (directory.existsSync()) {
    for (final file in directory.listSync().whereType<File>()) {
      if (file.path.endsWith('.jpg')) originals++;
      bytes += file.lengthSync();
    }
  }
  return {'originals': originals, 'bytesIncludingSidecars': bytes};
}

List<ui.Image> _decodedImages(WidgetTester tester, Finder scope) => tester
    .widgetList<RawImage>(
      find.descendant(of: scope, matching: find.byType(RawImage)),
    )
    .map((raw) => raw.image)
    .nonNulls
    .toList(growable: false);

List<double> _rectValues(Rect rect) => [
  rect.left,
  rect.top,
  rect.right,
  rect.bottom,
];

({int visible, int decoded, int missing, int maxEdge, List<String> paths})
_visibleImages(WidgetTester tester, Element? wall) {
  final render = wall?.findRenderObject();
  if (render is! RenderBox || !render.hasSize) {
    return (visible: 0, decoded: 0, missing: 0, maxEdge: 0, paths: []);
  }
  final viewport = (render.localToGlobal(Offset.zero) & render.size).intersect(
    Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
  );
  final paths = <String>[];
  var decoded = 0, maxEdge = 0;
  void visit(Element element) {
    if (element.widget case final AlbumThumbnail thumbnail) {
      final box = element.findRenderObject();
      if (box is! RenderBox ||
          !box.hasSize ||
          !(box.localToGlobal(Offset.zero) & box.size).overlaps(viewport)) {
        return;
      }
      paths.add(thumbnail.entry.path);
      ui.Image? decodedImage;
      void imageChild(Element child) {
        if (child.widget case RawImage(image: final image?)) {
          decodedImage = image;
        } else {
          child.visitChildren(imageChild);
        }
      }

      element.visitChildren(imageChild);
      if (decodedImage case final image?) {
        decoded++;
        maxEdge = math.max(maxEdge, math.max(image.width, image.height));
      }
      return;
    }
    element.visitChildren(visit);
  }

  wall!.visitChildren(visit);
  return (
    visible: paths.length,
    decoded: decoded,
    missing: paths.length - decoded,
    maxEdge: maxEdge,
    paths: paths,
  );
}

class _AlbumFixture {
  final Isolate worker;
  final ReceivePort replies;
  final SendPort commands;
  final String root;
  final Map<String, dynamic> source;
  final int files, isolateId;
  Completer<Map<String, Object?>>? pending;
  Completer<void>? stopped;
  _AlbumFixture(
    this.worker,
    this.replies,
    this.commands,
    this.root,
    this.source,
    this.files,
    this.isolateId,
  );

  static Future<_AlbumFixture> start(int groups) async {
    final replies = ReceivePort();
    final ready = Completer<List<dynamic>>();
    _AlbumFixture? fixture;
    replies.listen((message) {
      final row = message as List;
      if (row[0] == 'ready') {
        ready.complete(row);
      } else if (row[0] == 'stats') {
        fixture!.pending?.complete(Map<String, Object?>.from(row[1] as Map));
        fixture.pending = null;
      } else if (row[0] == 'closed') {
        fixture!.stopped?.complete();
      } else if (row[0] == 'error') {
        if (!ready.isCompleted) ready.completeError(StateError('${row[1]}'));
      }
    });
    final worker = await Isolate.spawn(_serveAlbum, (replies.sendPort, groups));
    final row = await ready.future;
    fixture = _AlbumFixture(
      worker,
      replies,
      row[1] as SendPort,
      row[2] as String,
      Map<String, dynamic>.from(row[3] as Map),
      row[4] as int,
      row[5] as int,
    );
    return fixture;
  }

  Future<Map<String, Object?>> stats() {
    if (pending != null) throw StateError('Only one fixture request at a time');
    pending = Completer<Map<String, Object?>>();
    commands.send('stats');
    return pending!.future;
  }

  Future<void> close() async {
    stopped = Completer<void>();
    commands.send('close');
    await stopped!.future;
    replies.close();
    worker.kill();
  }
}

Future<void> _serveAlbum((SendPort, int) args) async {
  final (reply, groups) = args;
  final commands = ReceivePort();
  Directory? root;
  HttpServer? server;
  try {
    root = Directory.systemTemp.createTempSync('album-page-profile-');
    final patterns = List.generate(_jpegNoise ? 3 : 8, (index) {
      final image = img.Image(width: _jpegWidth, height: _jpegHeight);
      var random = index + 31;
      for (final pixel in image) {
        if (_jpegNoise) {
          random = (random * 1664525 + 1013904223) & 0xffffffff;
          pixel.setRgb(
            (random >> 24) & 255,
            (random >> 16) & 255,
            (random >> 8) & 255,
          );
        } else {
          pixel.setRgb(
            (pixel.x ~/ 3 + index * 31) % 256,
            (pixel.y ~/ 2 + index * 17) % 256,
            ((pixel.x + pixel.y) ~/ 4 + index * 7) % 256,
          );
        }
      }
      final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 80));
      if (_minimumJpegBytes <= jpeg.length) return jpeg;
      return Uint8List(_minimumJpegBytes)..setRange(0, jpeg.length, jpeg);
    });
    if (_exportSourceJpegs) {
      const output = String.fromEnvironment(
        'ALBUM_PROFILE_ARTIFACT_DIR',
        defaultValue: '../artifacts',
      );
      final directory = Directory('$output/source-jpegs')
        ..createSync(recursive: true);
      for (var index = 0; index < patterns.length; index++) {
        File('${directory.path}/fixture-$index.jpg')
            .writeAsBytesSync(patterns[index]);
      }
    }
    final files = <String, Uint8List>{};
    for (var index = 0; index < groups; index++) {
      final stem = 'photo-${index.toString().padLeft(5, '0')}';
      files['/dav/album/$stem.jpg'] = patterns[index % patterns.length];
      if (index % 3 == 0) {
        // RAW companions exercise grouping. Their embedded-JPEG fallback is
        // not measured here: the production grid prefers each paired JPEG.
        files['/dav/album/$stem.arw'] = patterns[index % patterns.length];
        files['/dav/album/$stem.xmp'] = Uint8List.fromList(
          utf8.encode('<xmp/>'),
        );
      }
    }
    const modified = 'Sun, 01 Nov 2026 12:00:00 GMT';
    final listing = StringBuffer('<d:multistatus xmlns:d="DAV:">');
    for (final path in ['/dav/album/', ...files.keys]) {
      listing.write(
        '<d:response><d:href>$path</d:href><d:propstat><d:prop><d:resourcetype>${path.endsWith('/') ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>${files[path]?.length ?? 0}</d:getcontentlength><d:getlastmodified>$modified</d:getlastmodified></d:prop></d:propstat></d:response>',
      );
    }
    listing.write('</d:multistatus>');
    final xml = utf8.encode('$listing');
    var gets = 0, heads = 0, propfinds = 0, sent = 0, active = 0, peak = 0;
    final uniqueGets = <String>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      active++;
      peak = math.max(peak, active);
      try {
        if (request.method == 'PROPFIND' && request.uri.path == '/dav/album/') {
          propfinds++;
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.add(xml);
          sent += xml.length;
        } else if (files[request.uri.path] case final bytes?) {
          request.response.headers.set('last-modified', modified);
          request.response.headers.set('accept-ranges', 'bytes');
          if (request.method == 'HEAD') {
            heads++;
            request.response.contentLength = bytes.length;
          } else if (request.method == 'GET') {
            gets++;
            uniqueGets.add(request.uri.path);
            final range = RegExp(r'^bytes=(\d+)-(\d+)$')
                .firstMatch(request.headers.value('range') ?? '');
            final start = range == null ? 0 : int.parse(range[1]!);
            final end = math.min(
              bytes.length - 1,
              range == null ? bytes.length - 1 : int.parse(range[2]!),
            );
            if (range != null) {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            request.response.contentLength = end - start + 1;
            request.response.add(Uint8List.sublistView(bytes, start, end + 1));
            sent += end - start + 1;
          } else {
            request.response.statusCode = 405;
          }
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      } on HttpException {
        // Route cancellation can close a bounded in-flight request.
      } on SocketException {
        // Same cancellation path; no timer or retry loop in the fixture.
      } finally {
        active--;
      }
    });
    final source = <String, dynamic>{
      'id': 'album-profile',
      'kind': 'webdav',
      'label': 'Profile album',
      'url': 'http://127.0.0.1:${server.port}/dav/',
    };
    final store = AppStore('${root.path}/library.db');
    store.setLocal('settings', {
      'autoIdentifyOnFolderOpen': false,
      'autoDiscover': false,
    });
    store.setLocal('sources', [source]);
    store.dispose();
    reply.send([
      'ready',
      commands.sendPort,
      root.path,
      source,
      files.length,
      Isolate.current.hashCode,
    ]);
    await for (final command in commands) {
      if (command == 'close') break;
      if (command == 'stats') {
        reply.send([
          'stats',
          {
            'gets': gets,
            'heads': heads,
            'propfinds': propfinds,
            'bytesSent': sent,
            'uniqueImageGets': uniqueGets.length,
            'jpegBytes': patterns.map((bytes) => bytes.length).toList(),
            'peakConcurrentRequests': peak,
          },
        ]);
      }
    }
  } catch (error, stack) {
    reply.send(['error', '$error\n$stack']);
  } finally {
    await server?.close(force: true);
    commands.close();
    if (root != null) {
      // Page workers are disposed before fixture teardown is requested.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
    reply.send(['closed']);
  }
}

Map<String, Object?> _writeReport(Map<String, Object?> report) {
  for (final phase in report['phases'] as List) {
    for (final prefix in ['build', 'raster', 'totalSpan']) {
      final values = (phase.remove('${prefix}Us') as List).cast<int>()..sort();
      phase['${prefix}Ms'] = values.isEmpty
          ? {'count': 0}
          : {
              'count': values.length,
              'p50': values[(values.length * .50).ceil() - 1] / 1000,
              'p95': values[(values.length * .95).ceil() - 1] / 1000,
              'max': values.last / 1000,
              'over16_67ms': values
                  .where((value) => value > 1000000 / 60)
                  .length,
              'over33_33ms': values
                  .where((value) => value > 1000000 / 30)
                  .length,
            };
    }
  }
  const output = String.fromEnvironment(
    'ALBUM_PROFILE_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  Directory(output).createSync(recursive: true);
  File('$output/album-browsing-performance.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  return report;
}

void _writeScreenshot((String, Uint8List) capture) {
  const output = String.fromEnvironment(
    'ALBUM_PROFILE_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  Directory(output).createSync(recursive: true);
  File('$output/${capture.$1}').writeAsBytesSync(capture.$2);
}
