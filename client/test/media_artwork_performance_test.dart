import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
    await tester.pump(const Duration(milliseconds: 80));
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
    await tester.pump(const Duration(milliseconds: 80));
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
    await tester.pump(const Duration(milliseconds: 80));
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
    await tester.pump(const Duration(milliseconds: 80));
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
