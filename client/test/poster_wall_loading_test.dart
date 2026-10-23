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

class _DelayedLocalCache extends PosterCache {
  _DelayedLocalCache(Directory directory) : super(directory: directory);

  final ready = Completer<File?>();
  final requested = <String>[];

  @override
  Future<File?> load(String url) {
    requested.add(url);
    return ready.future;
  }
}

class _ObservedPosterCache extends PosterCache {
  _ObservedPosterCache(Directory directory, {super.createClient})
    : super(directory: directory);

  final requested = <String>[];
  final nearby = <String, Future<File?>>{};

  @override
  Future<File?> load(String url) {
    requested.add(url);
    return super.load(url);
  }

  @override
  Future<File?>? loadNearby(String url, {required bool Function() canStart}) {
    final result = super.loadNearby(url, canStart: canStart);
    if (result != null) nearby[url] = result;
    return result;
  }
}

class _RealHttp extends HttpOverrides {}

Future<Directory> _fixtures(WidgetTester tester, {int count = 1}) async {
  late Directory directory;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('poster-wall-');
    final png = images.encodePng(images.Image(width: 64, height: 96));
    for (var i = 0; i < count; i++) {
      await File('${directory.path}/$i.png').writeAsBytes(png);
    }
  });
  return directory;
}

bool _decoded(WidgetTester tester, Finder within, {int width = 64}) => tester
    .widgetList<RawImage>(
      find.descendant(
        of: within,
        matching: find.byType(RawImage, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .any((raw) => raw.image?.width == width);

Future<void> _waitForImage(WidgetTester tester, Finder within) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump();
    if (_decoded(tester, within)) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('The visible poster never produced a decoded frame.');
}

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('adjacent posters have pixels before their first visible frame', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await _fixtures(tester);
    final cache = _ObservedPosterCache(directory);
    final addresses = [
      for (var i = 0; i < 10; i++) 'https://example.com/adjacent-$i.png',
    ];
    await tester.runAsync(() async {
      final png = await File('${directory.path}/0.png').readAsBytes();
      for (final address in addresses) {
        await cache.cachedFile(address).writeAsBytes(png);
      }
    });
    final previews = <int>[];
    Finder card(int index) =>
        find.byKey(ValueKey('adjacent-$index'), skipOffstage: false);
    try {
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
                  itemCount: addresses.length,
                  itemExtent: 100,
                  itemBuilder: (_, index) => MediaArtwork(
                    key: ValueKey('adjacent-$index'),
                    poster: addresses[index],
                    cache: cache,
                    loadWhileScrolling: true,
                    onRequestPreview: () => previews.add(index),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitForImage(tester, card(2));
      await _waitForImage(tester, card(3));
      expect(
        tester.getRect(card(2)).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(ListView)).bottom),
      );
      expect(previews, [0, 1]);
      expect(cache.nearby.keys, containsAll([addresses[2], addresses[3]]));
      expect(cache.requested, isNot(contains(addresses[4])));
      expect(cache.requested, isNot(contains(addresses[6])));
      expect(_decoded(tester, card(4)), isFalse);
      expect(_decoded(tester, card(6)), isFalse);
      expect(cache.resolvedFile(addresses[6]), isNull);

      final location = tester.getCenter(find.byType(ListView));
      final gesture = await tester.startGesture(
        location,
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomUpdate(location, pan: const Offset(0, -200));
      // One layout/paint only: no idle delay or real IO wait after entering.
      await tester.pump();
      expect(
        tester.getRect(card(2)).overlaps(tester.getRect(find.byType(ListView))),
        isTrue,
      );
      expect(_decoded(tester, card(2)), isTrue);
      expect(_decoded(tester, card(3)), isTrue);
      expect(previews, [0, 1]);
      await gesture.panZoomEnd();
      await tester.pump(const Duration(milliseconds: 120));
      expect(previews, containsAll([2, 3]));
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets(
    'hidden pages cancel queued nearby transfers and retry on return',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await _fixtures(tester);
      final gate = Completer<void>();
      final networkPaths = <String>[];
      late HttpServer server;
      late _ObservedPosterCache cache;
      late List<String> addresses;
      late List<Future<File?>> foreground;
      await tester.runAsync(() async {
        final png = await File('${directory.path}/0.png').readAsBytes();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          networkPaths.add(request.uri.path);
          if (request.uri.path.startsWith('/busy-')) await gate.future;
          request.response.add(png);
          await request.response.close();
        });
        cache = _ObservedPosterCache(
          directory,
          createClient: () =>
              HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()),
        );
        addresses = [
          for (var i = 0; i < 8; i++)
            'http://127.0.0.1:${server.port}/nearby-$i',
        ];
        for (final address in addresses.take(2)) {
          await cache.cachedFile(address).writeAsBytes(png);
        }
        foreground = [
          for (var i = 0; i < 4; i++)
            cache.loadVisible('http://127.0.0.1:${server.port}/busy-$i')!,
        ];
        await Future.doWhile(() async {
          if (networkPaths.length == 4) return false;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return true;
        }).timeout(const Duration(seconds: 2));
      });
      var active = true;
      late StateSetter update;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return TickerMode(
                  enabled: active,
                  child: ArtworkScrollScope(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 200,
                        height: 200,
                        child: ListView.builder(
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            1000,
                          ),
                          itemCount: addresses.length,
                          itemExtent: 100,
                          itemBuilder: (_, index) => MediaArtwork(
                            key: ValueKey('queued-nearby-$index'),
                            poster: addresses[index],
                            cache: cache,
                            loadWhileScrolling: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        expect(cache.nearby.keys, containsAll([addresses[2], addresses[3]]));
        update(() => active = false);
        await tester.pump();
        final canceled = <File?>[];
        for (final address in addresses.skip(2).take(2)) {
          cache.nearby[address]!.then(canceled.add);
        }
        await tester.runAsync(() async {
          gate.complete();
          await Future.wait(foreground);
        });
        await tester.pump();
        expect(canceled, [null, null]);
        expect(networkPaths, hasLength(4));
        expect(cache.resolvedFile(addresses[2]), isNull);
        expect(cache.resolvedFile(addresses[3]), isNull);

        update(() => active = true);
        await tester.pump();
        await _waitForImage(
          tester,
          find.byKey(const ValueKey('queued-nearby-2'), skipOffstage: false),
        );
        expect(networkPaths.where((path) => path == '/nearby-2'), hasLength(1));
        expect(networkPaths, isNot(contains('/nearby-4')));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!gate.isCompleted) gate.complete();
        cache.close();
        PaintingBinding.instance.imageCache.clear();
        await tester.runAsync(() async {
          await server.close(force: true);
          await directory.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'visible wall posters progress during a held gesture and cached rows wake on the shared pulse',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await _fixtures(tester, count: 12);
      final previews = <int>[];
      final builds = <int, int>{};
      late ValueListenable<bool> activity;
      Finder card(int index) =>
          find.byKey(ValueKey('card-$index'), skipOffstage: false);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ArtworkScrollScope(
              child: Builder(
                builder: (context) {
                  activity = ArtworkScrollScope.maybeOf(context)!;
                  return Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: ListView.builder(
                        physics: const ClampingScrollPhysics(),
                        scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                        itemCount: 12,
                        itemExtent: 100,
                        itemBuilder: (_, index) {
                          builds.update(
                            index,
                            (count) => count + 1,
                            ifAbsent: () => 1,
                          );
                          return MediaArtwork(
                            key: ValueKey('card-$index'),
                            thumbnail: '${directory.path}/$index.png',
                            loadWhileScrolling: true,
                            onRequestPreview: () => previews.add(index),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await _waitForImage(tester, card(0));
        await _waitForImage(tester, card(1));
        expect(previews, [0, 1]);
        expect(card(6), findsOneWidget);
        expect(_decoded(tester, card(6)), isFalse);
        final cachedRowBuilds = builds[6];

        final location = tester.getCenter(find.byType(ListView));
        final gesture = await tester.startGesture(
          location,
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomUpdate(location, pan: const Offset(0, -300));
        await _waitForImage(tester, card(3));
        await _waitForImage(tester, card(4));
        expect(activity.value, isTrue);
        expect(previews, [0, 1]);

        // These children were already built outside the viewport. The activity
        // remains true, so only its shared viewport pulse can wake them.
        await gesture.panZoomUpdate(location, pan: const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 64));
        await _waitForImage(tester, card(6));
        await _waitForImage(tester, card(7));
        expect(builds[6], cachedRowBuilds);
        expect(activity.value, isTrue);
        expect(previews, [0, 1]);
        await gesture.panZoomEnd();
        await tester.pump(const Duration(milliseconds: 120));
        expect(activity.value, isFalse);
        expect(previews, containsAll([6, 7]));
      } finally {
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets('cold poster decoding keeps its placeholder with a thumbnail', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await _fixtures(tester, count: 2);
    final cache = PosterCache(directory: directory);
    const address = 'https://example.com/cold-poster.png';
    await tester.runAsync(() async {
      await cache.restore(
        address,
        await File('${directory.path}/0.png').readAsBytes(),
      );
    });
    const placeholder = ValueKey('poster-placeholder');
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 80,
              height: 120,
              child: MediaArtwork(
                poster: address,
                cache: cache,
                thumbnail: '${directory.path}/1.png',
                loadWhileScrolling: true,
                placeholder: const ColoredBox(
                  key: placeholder,
                  color: Colors.blueGrey,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(placeholder), findsOneWidget);
      expect(_decoded(tester, find.byType(MediaArtwork)), isFalse);
      await _waitForImage(tester, find.byType(MediaArtwork));
      expect(find.byKey(placeholder), findsNothing);
      final provider =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(
        (provider.imageProvider as FileImage).file.path,
        cache.cachedFile(address).path,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('a recreated warm card has pixels after more than 512 handles', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await _fixtures(tester);
    final cache = PosterCache(directory: directory);
    const address = 'https://example.com/warm-poster.png';
    await tester.runAsync(() async {
      await cache.restore(
        address,
        await File('${directory.path}/0.png').readAsBytes(),
      );
    });
    Widget card(Key key) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 80,
          height: 120,
          child: MediaArtwork(
            key: key,
            poster: address,
            cache: cache,
            loadWhileScrolling: true,
          ),
        ),
      ),
    );
    try {
      await tester.pumpWidget(card(const ValueKey('original')));
      await _waitForImage(tester, find.byType(MediaArtwork));
      final first = tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .clone();
      try {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          for (var i = 0; i < 513; i++) {
            final other = 'https://example.com/churn-$i.png';
            await cache.cachedFile(other).writeAsBytes([1]);
            final file = (await cache.load(other))!;
            artworkImage(file, 128);
          }
        });
        await tester.pumpWidget(card(const ValueKey('recreated')));
        final returned = tester.widget<RawImage>(find.byType(RawImage)).image;
        expect(returned, isNotNull);
        expect(returned!.isCloneOf(first), isTrue);
        expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
      } finally {
        first.dispose();
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('hidden and disposed wall cards do not decode arriving posters', (
    tester,
  ) async {
    final directory = await _fixtures(tester);
    final cache = _DelayedLocalCache(directory);
    final file = File('${directory.path}/0.png');
    var active = true;
    var poster = 'https://example.com/hidden.png';
    late StateSetter update;
    final previews = <String>[];
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return TickerMode(
                enabled: active,
                child: SizedBox(
                  width: 80,
                  height: 120,
                  child: MediaArtwork(
                    poster: poster,
                    cache: cache,
                    loadWhileScrolling: true,
                    onRequestPreview: () => previews.add(poster),
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(cache.requested, [poster]);
      update(() => active = false);
      await tester.pump();
      cache.ready.complete(file);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      update(() => poster = 'https://example.com/changed-while-hidden.png');
      await tester.pump(const Duration(milliseconds: 200));
      expect(cache.requested, hasLength(1));
      expect(previews, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      cache.fileChanged(poster);
      await tester.pump(const Duration(milliseconds: 200));
      expect(cache.requested, hasLength(1));
      expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
