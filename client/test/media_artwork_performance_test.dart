import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _RecordingPosterCache extends PosterCache {
  final requested = <String>[];

  _RecordingPosterCache() : super(directory: Directory.systemTemp);

  @override
  Future<File?> load(String url) async {
    requested.add(url);
    return null;
  }
}

class _DelayedPosterCache extends PosterCache {
  final result = Completer<File?>();
  int requests = 0;

  _DelayedPosterCache() : super(directory: Directory.systemTemp);

  @override
  Future<File?> load(String url) {
    requests++;
    return result.future;
  }
}

class _RepairingPosterCache extends PosterCache {
  int requests = 0, invalidations = 0;
  final repair = Completer<void>();
  final File broken;

  _RepairingPosterCache(this.broken) : super(directory: Directory.systemTemp);

  @override
  Future<File?> load(String url) {
    requests++;
    return SynchronousFuture(broken);
  }

  @override
  Future<void> invalidate(
    String url, {
    File? failedFile,
    bool retryImmediately = false,
  }) {
    expect(failedFile, same(broken));
    expect(retryImmediately, isTrue);
    invalidations++;
    return repair.future;
  }
}

class _FullPosterCache extends _RecordingPosterCache {
  bool full = true;
  final available = ChangeNotifier();

  @override
  Listenable get capacity => available;

  @override
  Future<File?>? loadVisible(String url) => full ? null : load(url);

  void release() {
    full = false;
    available.notifyListeners();
  }

  @override
  void close() {
    available.dispose();
    super.close();
  }
}

class _DeferredPhysics extends ScrollPhysics {
  final bool Function() defer;
  const _DeferredPhysics(this.defer, {super.parent});

  @override
  _DeferredPhysics applyTo(ScrollPhysics? ancestor) =>
      _DeferredPhysics(defer, parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => defer();
}

class _TransformProbe extends SingleChildRenderObjectWidget {
  final VoidCallback onTransform;

  const _TransformProbe({required this.onTransform, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTransformProbe(onTransform);
}

class _RenderTransformProbe extends RenderProxyBox {
  final VoidCallback onTransform;

  _RenderTransformProbe(this.onTransform);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    onTransform();
    super.applyPaintTransform(child, transform);
  }
}

void main() {
  testWidgets('paused without a frame ignores poster capacity until resume', (
    tester,
  ) async {
    final cache = _FullPosterCache();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 150,
              child: MediaArtwork(poster: 'paused-cover', cache: cache),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.requested, isEmpty);
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      cache.release();
      cache.fileChanged('paused-cover');
      await tester.idle();
      expect(cache.requested, isEmpty);
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(cache.requested, ['paused-cover']);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      cache.close();
    }
  });

  void endScroll(WidgetTester tester) {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position
        .drag(DragStartDetails(), () {})
        .end(DragEndDetails(primaryVelocity: 0));
  }

  testWidgets('deferred covers wait for scroll events without retry timers', (
    tester,
  ) async {
    final cache = _RecordingPosterCache();
    var defer = true, retries = 0;
    await runZoned(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: ListView(
              physics: _DeferredPhysics(() => defer),
              children: [
                SizedBox(
                  height: 100,
                  child: MediaArtwork(poster: 'deferred', cache: cache),
                ),
              ],
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 3));
        expect(cache.requested, isEmpty);
        expect(retries, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        defer = false;
        endScroll(tester);
        await tester.pump();
        expect(cache.requested, ['deferred']);
        await tester.pumpWidget(const SizedBox());
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(milliseconds: 80)) retries++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    cache.close();
  });

  testWidgets('same-path replacement refreshes mounted and new covers', (
    tester,
  ) async {
    late Directory directory;
    late PosterCache cache;
    const poster = 'https://example.com/replaced-cover.png';
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('artwork-generation-');
      cache = PosterCache(directory: directory);
      await cache.restore(
        poster,
        images.encodePng(images.Image(width: 20, height: 30)),
      );
    });
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    Widget cover(Key key) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 80,
          height: 120,
          child: MediaArtwork(key: key, poster: poster, cache: cache),
        ),
      ),
    );
    Future<void> expectWidth(int width) async {
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image?.width == width)) {
          return;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      fail('The current file generation did not render at width $width.');
    }

    try {
      await tester.pumpWidget(cover(const ValueKey('mounted')));
      await expectWidth(20);
      final first = tester.widget<Image>(find.byType(Image)).image;
      await tester.runAsync(() async {
        await cache.restore(
          poster,
          images.encodePng(images.Image(width: 40, height: 60)),
          replace: true,
        );
      });
      await expectWidth(40);
      expect(tester.widget<Image>(find.byType(Image)).image, isNot(first));
      // A worker's atomic same-path replacement also invalidates old pixels.
      await tester.runAsync(() async {
        await cache
            .cachedFile(poster)
            .writeAsBytes(
              images.encodePng(images.Image(width: 60, height: 90)),
            );
      });
      cache.fileChanged(poster);
      await expectWidth(60);
      final newest = tester.widget<Image>(find.byType(Image)).image;
      await tester.pumpWidget(cover(const ValueKey('new-detail')));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image?.width, 60);
      expect(tester.widget<Image>(find.byType(Image)).image, same(newest));
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets(
    'card, smaller details and larger viewer share the resident first frame',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigator = GlobalKey<NavigatorState>();
      late Directory directory;
      late PosterCache cache;
      var downloads = 0;
      const poster = 'https://example.com/shared-cover.png';
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('artwork-shared-');
        cache = PosterCache(
          directory: directory,
          createClient: () {
            downloads++;
            throw StateError('The local poster must be reused');
          },
        );
        await cache.restore(
          poster,
          await File('assets/branding/app_icon.png').readAsBytes(),
        );
      });
      addTearDown(() async {
        cache.close();
        await directory.delete(recursive: true);
      });
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      Widget cover(String name, double edge, {int maxEdge = 640}) => Center(
        child: SizedBox(
          width: edge,
          height: edge,
          child: MediaArtwork(
            key: ValueKey(name),
            poster: poster,
            cache: cache,
            maxDecodeEdge: maxEdge,
            fit: BoxFit.contain,
          ),
        ),
      );
      Image image(String name) => tester.widget<Image>(
        find.descendant(
          of: find.byKey(ValueKey(name), skipOffstage: false),
          matching: find.byType(Image, skipOffstage: false),
          skipOffstage: false,
        ),
      );
      RawImage raw(String name) => tester.widget<RawImage>(
        find.descendant(
          of: find.byKey(ValueKey(name), skipOffstage: false),
          matching: find.byType(RawImage, skipOffstage: false),
          skipOffstage: false,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(body: cover('card', 256)),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 30 && raw('card').image == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final cardProvider = image('card').image;
      final cardPixels = raw('card').image!;
      final decodedCount = imageCache.currentSize;
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(body: cover('details', 112)),
        ),
      );
      // No settled transition or async file work is needed for this frame.
      await tester.pump();
      expect(raw('details').image, isNotNull);
      expect(raw('details').image!.isCloneOf(cardPixels), isTrue);
      expect(image('details').image, same(cardProvider));
      expect(imageCache.pendingImageCount, 0);
      expect(imageCache.currentSize, decodedCount);
      await tester.pumpAndSettle();

      final detailPixels = raw('details').image!;
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(body: cover('viewer', 800, maxEdge: 2048)),
        ),
      );
      await tester.pump();
      expect(raw('viewer').image, isNotNull);
      expect(raw('viewer').image!.isCloneOf(detailPixels), isTrue);
      expect(image('viewer').image, same(cardProvider));
      await tester.pump();
      final viewerProvider = image('viewer').image as ResizeImage;
      expect(viewerProvider.width, 832);
      expect(viewerProvider.height, 832);
      // The lower-resolution cover stays visible during the larger decode.
      expect(raw('viewer').image, isNotNull);
      expect(downloads, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      imageCache.clear();
    },
  );

  testWidgets('an evicted texture is not retained by the variant index', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    const path = 'assets/branding/app_icon.png';
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(
      () => precacheImage(
        artworkImage(File(path), 256),
        tester.element(find.byType(SizedBox).last),
      ),
    );
    await tester.pump();
    imageCache.clear();
    expect(imageCache.currentSize, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: _DeferredPhysics(() => true),
          children: const [
            SizedBox(height: 100, child: MediaArtwork(thumbnail: path)),
          ],
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
  });

  testWidgets('a full queue wakes visible artwork without timers or rebuilds', (
    tester,
  ) async {
    final cache = _FullPosterCache();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 150,
            child: MediaArtwork(poster: 'deferred', cache: cache),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cache.requested, isEmpty);
    cache.release();
    await tester.pumpAndSettle();
    expect(cache.requested, ['deferred']);
    await tester.pumpWidget(const SizedBox());
    cache.close();
  });

  testWidgets('leaving a full queue removes its pending capacity listener', (
    tester,
  ) async {
    final cache = _FullPosterCache();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaArtwork(poster: 'disposed', cache: cache),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    cache.release();
    await tester.pumpAndSettle();
    expect(cache.requested, isEmpty);
    expect(tester.takeException(), isNull);
    cache.close();
  });

  for (final leaveBeforeRepair in [false, true]) {
    testWidgets(
      'a failed disk cover ${leaveBeforeRepair ? 'does not reload after disposal' : 'repairs without reopening details'}',
      (tester) async {
        late Directory directory;
        late File file;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp('artwork-repair-');
          file = await File(
            '${directory.path}/poster.image',
          ).writeAsString('broken image');
        });
        addTearDown(() => directory.delete(recursive: true));
        final cache = _RepairingPosterCache(file);
        final imageCache = PaintingBinding.instance.imageCache;
        imageCache.clear();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 100,
                height: 150,
                child: MediaArtwork(poster: 'repair', cache: cache),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 20 && cache.invalidations == 0; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(cache.invalidations, 1);
        expect(cache.requests, 1);
        if (leaveBeforeRepair) await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await file.writeAsBytes(
            await File('assets/branding/app_icon.png').readAsBytes(),
          );
        });
        cache.repair.complete();
        await tester.pumpAndSettle();
        expect(cache.requests, leaveBeforeRepair ? 1 : 2);
        expect(cache.invalidations, 1);
        if (!leaveBeforeRepair) {
          bool decoded() => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null);
          for (var i = 0; i < 20 && !decoded(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(
            decoded(),
            isTrue,
            reason:
                'The repaired image uses the same file path and must replace its old failed ImageStream.',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        imageCache.clear();
        cache.close();
      },
    );
  }

  testWidgets('busy artwork skips viewport transforms until the scope idles', (
    tester,
  ) async {
    final controller = ScrollController();
    final cache = _RecordingPosterCache();
    late StateSetter update;
    var showArtwork = false, transforms = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ListView(
                controller: controller,
                children: [
                  if (showArtwork)
                    _TransformProbe(
                      onTransform: () => transforms++,
                      child: SizedBox(
                        height: 100,
                        child: MediaArtwork(poster: 'new-poster', cache: cache),
                      ),
                    ),
                  const SizedBox(height: 4000),
                ],
              );
            },
          ),
        ),
      ),
    );
    final drag = controller.position.drag(DragStartDetails(), () {});
    update(() => showArtwork = true);
    await tester.pump();
    expect(cache.requested, isEmpty);
    expect(transforms, 0);
    drag.end(DragEndDetails(primaryVelocity: 0));
    await tester.pump(const Duration(milliseconds: 120));
    expect(cache.requested, ['new-poster']);
    expect(transforms, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    cache.close();
  });

  testWidgets('rebuilding a decoded cover skips viewport transforms', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const path = 'assets/branding/app_icon.png';
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(
      () => precacheImage(
        artworkImage(File(path), 128),
        tester.element(find.byType(SizedBox).last),
      ),
    );
    late StateSetter update;
    var transforms = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: _TransformProbe(
                onTransform: () => transforms++,
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: MediaArtwork(thumbnail: path),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    transforms = 0;
    update(() {});
    // Exclude the accessibility pass, which legitimately transforms geometry.
    await tester.pump(null, EnginePhase.paint);
    expect(transforms, 0);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
  });

  testWidgets('opening details starts cache lookup during the transition', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final cache = _RecordingPosterCache();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 150,
              child: MediaArtwork(poster: 'details', cache: cache),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(cache.requested, ['details']);
    await tester.pumpAndSettle();
    expect(cache.requested, ['details']);
    await tester.pumpWidget(const SizedBox());
    cache.close();
  });

  testWidgets('wheel bursts defer newly visible posters and previews', (
    tester,
  ) async {
    final cache = _RecordingPosterCache();
    final previews = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: ListView.builder(
                physics: const ClampingScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                itemExtent: 100,
                itemCount: 20,
                itemBuilder: (_, index) => MediaArtwork(
                  poster: 'poster-$index',
                  cache: cache,
                  onRequestPreview: () => previews.add(index),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(cache.requested, ['poster-0', 'poster-1']);
    expect(previews, [0, 1]);
    Future<void> wheel(double delta) => tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: Offset(0, delta),
      ),
    );
    await wheel(300);
    await tester.pump(const Duration(milliseconds: 90));
    expect(cache.requested, hasLength(2));
    await wheel(100);
    await tester.pump(const Duration(milliseconds: 119));
    expect(cache.requested, hasLength(2));
    expect(previews, [0, 1]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(cache.requested, ['poster-0', 'poster-1', 'poster-4', 'poster-5']);
    expect(previews, [0, 1, 4, 5]);
    await tester.pumpWidget(const SizedBox());
    cache.close();
  });

  testWidgets('a poster arriving between wheel events waits for idle', (
    tester,
  ) async {
    final cache = _DelayedPosterCache();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: ListView(
            physics: const ClampingScrollPhysics(),
            children: [
              SizedBox(
                height: 100,
                child: MediaArtwork(poster: 'late-poster', cache: cache),
              ),
              const SizedBox(height: 4000),
            ],
          ),
        ),
      ),
    );
    expect(cache.requests, 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: const Offset(0, 20),
      ),
    );
    cache.result.complete(File('assets/branding/app_icon.png'));
    await tester.pump(const Duration(milliseconds: 119));
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(cache.requests, 1);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
    cache.close();
  });

  testWidgets('a poster arriving during a fling waits before decoding', (
    tester,
  ) async {
    final cache = _DelayedPosterCache();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    var defer = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: _DeferredPhysics(() => defer),
          children: [
            SizedBox(
              height: 100,
              child: MediaArtwork(poster: 'late-poster', cache: cache),
            ),
          ],
        ),
      ),
    );
    expect(cache.requests, 1);
    defer = true;
    cache.result.complete(File('assets/branding/app_icon.png'));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byType(Image), findsNothing);

    defer = false;
    endScroll(tester);
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(cache.requests, 1);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
    cache.close();
  });

  testWidgets('an offscreen poster result waits until its card is visible', (
    tester,
  ) async {
    final cache = _DelayedPosterCache();
    final controller = ScrollController();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 200,
            child: ListView(
              controller: controller,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
              children: [
                SizedBox(
                  height: 100,
                  child: MediaArtwork(poster: 'late-poster', cache: cache),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      ),
    );
    expect(cache.requests, 1);
    controller.jumpTo(300);
    await tester.pump();
    cache.result.complete(File('assets/branding/app_icon.png'));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    controller.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(cache.requests, 1);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    imageCache.clear();
    cache.close();
  });

  testWidgets('decoded covers reappear immediately during a fling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const path = 'assets/branding/app_icon.png';
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).last);
    await tester.runAsync(
      () => precacheImage(artworkImage(File(path), 128), context),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: _DeferredPhysics(() => true),
          children: const [
            Align(
              child: SizedBox(
                width: 100,
                height: 100,
                child: MediaArtwork(thumbnail: path),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
  });

  testWidgets('small covers use smaller textures at the device pixel ratio', (
    tester,
  ) async {
    Future<void> mount(Size size) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 3),
          child: Center(
            child: SizedBox.fromSize(
              size: size,
              child: const MediaArtwork(
                thumbnail: 'assets/branding/app_icon.png',
              ),
            ),
          ),
        ),
      ),
    );

    await mount(const Size(64, 42));
    await tester.pump();
    var provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 192);
    await mount(const Size(65, 42));
    provider = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 256);
    await mount(const Size(80, 42));
    provider = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 256);
    await mount(const Size(400, 600));
    provider = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 640);
    expect(provider.height, 640);
    expect(provider.policy, ResizeImagePolicy.fit);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'cached offscreen cards and covered routes do not request artwork',
    (tester) async {
      final controller = ScrollController();
      final navigator = GlobalKey<NavigatorState>();
      final cache = _RecordingPosterCache();
      final previews = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: ListView.builder(
                controller: controller,
                scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                itemExtent: 100,
                itemCount: 20,
                itemBuilder: (_, index) => MediaArtwork(
                  poster: 'poster-$index',
                  cache: cache,
                  onRequestPreview: () => previews.add(index),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.requested, ['poster-0', 'poster-1']);
      expect(previews, [0, 1]);
      controller.jumpTo(300);
      await tester.pumpAndSettle();
      expect(cache.requested, ['poster-0', 'poster-1', 'poster-3', 'poster-4']);
      expect(previews, [0, 1, 3, 4]);

      navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(600);
      await tester.pumpAndSettle();
      expect(cache.requested, hasLength(4));
      expect(previews, hasLength(4));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(cache.requested, [
        'poster-0',
        'poster-1',
        'poster-3',
        'poster-4',
        'poster-6',
        'poster-7',
      ]);
      expect(previews, [0, 1, 3, 4, 6, 7]);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      cache.close();
    },
  );

  testWidgets('fling defers poster requests and settled cards load once', (
    tester,
  ) async {
    final cache = _RecordingPosterCache();
    var defer = true;
    Widget surface(String poster) => MaterialApp(
      home: ListView(
        physics: _DeferredPhysics(() => defer),
        children: [
          SizedBox(
            height: 100,
            child: MediaArtwork(poster: poster, cache: cache),
          ),
        ],
      ),
    );

    await tester.pumpWidget(surface('first'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(cache.requested, isEmpty);
    await tester.pumpWidget(surface('current'));
    defer = false;
    endScroll(tester);
    await tester.pump();
    expect(cache.requested, ['current']);
    await tester.pumpWidget(surface('current'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(cache.requested, ['current']);
    await tester.pumpWidget(surface('next'));
    expect(cache.requested, ['current', 'next']);
    await tester.pumpWidget(const SizedBox());
    cache.close();
  });

  testWidgets('leaving a flinging cover cancels its deferred request', (
    tester,
  ) async {
    final cache = _RecordingPosterCache();
    var defer = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: _DeferredPhysics(() => defer),
          children: [
            SizedBox(
              height: 100,
              child: MediaArtwork(poster: 'offscreen', cache: cache),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    defer = false;
    await tester.pump(const Duration(milliseconds: 160));
    expect(cache.requested, isEmpty);
    cache.close();
  });

  testWidgets('stationary carousel respects its flinging outer page', (
    tester,
  ) async {
    final cache = _RecordingPosterCache();
    var defer = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          physics: _DeferredPhysics(() => defer),
          children: [
            SizedBox(
              height: 100,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  SizedBox(
                    width: 100,
                    child: MediaArtwork(poster: 'nested', cache: cache),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(cache.requested, isEmpty);
    defer = false;
    endScroll(tester);
    await tester.pump();
    expect(cache.requested, ['nested']);
    await tester.pumpWidget(const SizedBox());
    cache.close();
  });

  testWidgets('video previews wait for scrolling and retry after updates', (
    tester,
  ) async {
    var defer = true;
    final requested = <String>[];
    Widget surface(String id) => MaterialApp(
      home: ListView(
        physics: _DeferredPhysics(() => defer),
        children: [
          SizedBox(
            height: 100,
            child: MediaArtwork(onRequestPreview: () => requested.add(id)),
          ),
        ],
      ),
    );

    await tester.pumpWidget(surface('old'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(requested, isEmpty);
    await tester.pumpWidget(surface('visible'));
    defer = false;
    endScroll(tester);
    await tester.pump();
    expect(requested, ['visible']);
    await tester.pump(const Duration(milliseconds: 160));
    expect(requested, ['visible']);

    // Decoder queues can be full on the first attempt; a model update allows
    // a still-visible card to try again without leaving a recurring timer.
    await tester.pumpWidget(surface('visible'));
    expect(requested, ['visible', 'visible']);
    defer = true;
    await tester.pumpWidget(surface('offscreen'));
    await tester.pumpWidget(const SizedBox());
    defer = false;
    await tester.pump(const Duration(milliseconds: 160));
    expect(requested, ['visible', 'visible']);
  });
}
