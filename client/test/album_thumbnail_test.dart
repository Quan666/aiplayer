import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

class _CachedImages extends AlbumImageService {
  final String path;
  final bool encodedSource;
  final String? largerPath;
  final requested = <String>{};
  final requestedEdges = <int>[];
  _CachedImages(this.path, {this.encodedSource = false, this.largerPath})
    : super(
        cacheDirectory: '/unused',
        sourceId: 'test',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );
  @override
  AlbumImageHandle load(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    bool metadataOnly = false,
    SourceEntry? cover,
    int priority = 0,
  }) {
    requested.add(entry.path);
    requestedEdges.add(targetEdge);
    return AlbumImageHandle(
      SynchronousFuture(
        AlbumImageResult(
          path: targetEdge > 64 ? largerPath ?? path : path,
          sourcePath: entry.path,
          encodedSource: encodedSource,
        ),
      ),
      () {},
    );
  }
}

class _PendingImages extends AlbumImageService {
  _PendingImages()
    : super(
        cacheDirectory: '/unused',
        sourceId: 'test',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );
  final requests = <String, Completer<AlbumImageResult>>{};
  final cancelled = <String>{};

  @override
  AlbumImageHandle load(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    bool metadataOnly = false,
    SourceEntry? cover,
    int priority = 0,
  }) {
    final result = requests.putIfAbsent(
      entry.path,
      Completer<AlbumImageResult>.new,
    );
    return AlbumImageHandle(result.future, () => cancelled.add(entry.path));
  }
}

class _PreparedImages extends _CachedImages {
  _PreparedImages(super.path);

  @override
  AlbumImageResult? peek(SourceEntry entry) =>
      AlbumImageResult(path: path, encodedSource: true, sourcePath: entry.path);
}

class _HeldDecode extends ImageProvider<_HeldDecode> {
  final _completer = _HeldDecodeCompleter();
  bool started = false, released = false;

  @override
  Future<_HeldDecode> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_HeldDecode key, ImageDecoderCallback decode) {
    started = true;
    return _completer;
  }

  void release() {
    if (!started || released) return;
    released = true;
    _completer.release();
  }
}

class _HeldDecodeCompleter extends ImageStreamCompleter {
  void release() => reportError(
    context: ErrorDescription('release occupied test decode slot'),
    exception: StateError('test decode slot released'),
    stack: StackTrace.current,
    silent: true,
  );
}

void main() {
  testWidgets(
    'an evicted initial preview falls through to the newer prepared path',
    (tester) async {
      final images = _PreparedImages('/album-current-preview.jpg');
      const entry = SourceEntry(name: 'photo.jpg', path: 'photo.jpg');
      images.invalidatePrepared(
        entry,
        failedPath: '/album-evicted-preview.jpg',
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumThumbnail(
              service: images,
              entry: entry,
              initialResult: const AlbumImageResult(
                path: '/album-evicted-preview.jpg',
                encodedSource: true,
              ),
            ),
          ),
        );
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
          images.path,
        );
        expect(images.requested, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.idle();
      }
    },
  );

  testWidgets(
    'independent missing prepared files automatically recover after each real decoded success',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'album-auto-repair-',
        );
        await File('${directory.path}/photo.jpg').writeAsBytes(
          raster.encodeJpg(raster.Image(width: 1000, height: 500)),
        );
        return directory;
      }))!;
      final service = AlbumImageService(
        cacheDirectory: '${directory.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
      );
      final entry = SourceEntry(
        name: 'photo.jpg',
        path: '${directory.path}/photo.jpg',
        size: 0,
        modified: 1,
      );
      final prepared = (await tester.runAsync(
        () => service.load(entry, targetEdge: 128).future,
      ))!;
      try {
        for (final edge in [128, 192, 256, 384]) {
          await tester.runAsync(() => File(prepared.path!).delete());
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox.square(
                  dimension: edge.toDouble(),
                  child: AlbumThumbnail(
                    service: service,
                    entry: entry,
                    edge: edge,
                    initialResult: prepared,
                    showLoading: true,
                  ),
                ),
              ),
            ),
          );
          for (var index = 0; index < 150; index++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 25));
            if (tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((image) => image.image?.width == edge)) {
              break;
            }
          }
          expect(
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((image) => image.image?.width == edge),
            isTrue,
            reason: 'A real decoded success must restore the retry budget before the next independent deletion.',
          );
          expect(
            await tester.runAsync(() => File(prepared.path!).exists()),
            isTrue,
          );
          expect(service.wasEvicted(prepared.path!), isFalse);
          expect(
            find.byKey(const ValueKey('album-image-loading')),
            findsNothing,
          );
          await tester.idle();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await directory.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'failed-file retry pauses without a frame and stops after two attempts',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final images = _CachedImages('/missing-album-image/retry.jpg');
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumThumbnail(
              service: images,
              entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
            ),
          ),
        );
        for (
          var index = 0;
          index < 100 && !images.wasEvicted(images.path);
          index++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(images.wasEvicted(images.path), isTrue);
        expect(images.requestedEdges, hasLength(1));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // No frame while paused: the delayed retry must be cancelled directly.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        expect(images.requestedEdges, hasLength(1));
        expect(tester.binding.transientCallbackCount, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        for (var index = 0; index < 100; index++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(images.requestedEdges, hasLength(3));
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(seconds: 5));
        expect(images.requestedEdges, hasLength(3));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  testWidgets(
    'prepared preview paints on the first remounted frame and equivalent filter sets retain its element',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'album-resident-preview-',
        );
        await File(
          '${directory.path}/photo.jpg',
        ).writeAsBytes(raster.encodeJpg(raster.Image(width: 128, height: 64)));
        return directory;
      }))!;
      final images = _CachedImages('${directory.path}/photo.jpg');
      final preview = AlbumImageResult(
        path: images.path,
        encodedSource: true,
        sourcePath: 'photo.jpg',
      );
      var loaded = 0;
      Future<void> mount(Set<String> extensions) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox.square(
            dimension: 128,
            child: AlbumThumbnail(
              service: images,
              entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
              initialResult: preview,
              edge: 128,
              extensions: extensions,
              showLoading: true,
              onLoaded: (_) => loaded++,
            ),
          ),
        ),
      );
      try {
        await mount({'.jpg', '.png'});
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null) {
            break;
          }
        }
        final pixels = tester.widget<RawImage>(find.byType(RawImage)).image!;
        final element = tester.element(find.byType(Image));
        await mount({'.png', '.jpg'});
        expect(tester.element(find.byType(Image)), same(element));
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(pixels),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        await mount({'.jpg', '.png'});
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
          images.path,
        );
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(pixels),
          isTrue,
        );
        expect(images.requested, isEmpty);
        expect(
          loaded,
          2,
          reason: 'Each new owner receives its seeded metadata once.',
        );
        expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'short waits stay quiet and backgrounding cancels the loading delay without a frame',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final images = _PendingImages();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumThumbnail(
              service: images,
              entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
              showLoading: true,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.idle();
        expect(tester.binding.transientCallbackCount, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 179));
        expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        expect(
          find.byKey(const ValueKey('album-image-loading')),
          findsOneWidget,
        );
        images.setActive(false);
        expect(tester.binding.transientCallbackCount, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
      }
    },
  );

  testWidgets('reduced motion keeps a static photo loading indicator', (
    tester,
  ) async {
    final images = _PendingImages();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: MotionScope(
            enabled: false,
            child: AlbumThumbnail(
              service: images,
              entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
              showLoading: true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      final animation =
          tester
                  .widget<RotationTransition>(
                    find.byKey(const ValueKey('album-image-loading')),
                  )
                  .turns
              as AnimationController;
      expect(animation.isAnimating, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      images.dispose();
    }
  });

  testWidgets(
    'cleared media cannot return as a new thumbnail waits to decode',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'artwork-cleared-media-',
        );
        await File(
          '${directory.path}/first.png',
        ).writeAsBytes(raster.encodePng(raster.Image(width: 64, height: 32)));
        await File(
          '${directory.path}/second.png',
        ).writeAsBytes(raster.encodePng(raster.Image(width: 64, height: 48)));
        return directory;
      }))!;
      final queue = ArtworkDecodeQueue.instance;
      final held = [_HeldDecode(), _HeldDecode()];
      final requests = <ArtworkDecodeRequest>[];
      Future<void> mount(String? path) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 64,
              child: MediaArtwork(
                thumbnail: path,
                fit: BoxFit.contain,
                maxDecodeEdge: 64,
                loadWhileScrolling: true,
                placeholder: const Text('empty media'),
              ),
            ),
          ),
        ),
      );
      Iterable<RawImage> pixels() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null);
      try {
        await mount('${directory.path}/first.png');
        for (var i = 0; i < 100 && pixels().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(pixels().single.image!.height, 32);
        for (final provider in held) {
          requests.add(
            queue.request(
              provider,
              canStart: () => true,
              onStart: () {},
              onError: (_, _) {},
            )!,
          );
        }
        await tester.pump();
        expect(queue.activeCount, 2);
        await mount(null);
        expect(pixels(), isEmpty);
        await mount('${directory.path}/second.png');
        await tester.pump();
        expect(queue.pendingCount, 1);
        expect(
          pixels(),
          isEmpty,
          reason: 'A new media item must not inherit the cleared cover.',
        );
        expect(find.text('empty media'), findsOneWidget);
        for (final provider in held) {
          provider.release();
        }
        for (var i = 0; i < 100 && pixels().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(pixels().single.image!.height, 48);
        expect(tester.takeException(), isNull);
      } finally {
        for (final request in requests) {
          request.cancel();
        }
        for (final provider in held) {
          provider.release();
        }
        await tester.pumpWidget(const SizedBox());
        await tester.idle();
        PaintingBinding.instance.imageCache.clear();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  for (final separatePath in [false, true]) {
    testWidgets(
      '${separatePath ? 'generated-file' : 'same-path'} warm preview remains visible without loading during a larger decode',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final directory = (await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'album-upgrade-',
          );
          await File('${directory.path}/photo.jpg').writeAsBytes(
            raster.encodeJpg(raster.Image(width: 1000, height: 500)),
          );
          if (separatePath) {
            await File('${directory.path}/photo.jpg')
                .copy('${directory.path}/larger.jpg');
          }
          return directory;
        }))!;
        final images = _CachedImages(
          '${directory.path}/photo.jpg',
          largerPath: separatePath ? '${directory.path}/larger.jpg' : null,
        );
        final queue = ArtworkDecodeQueue.instance;
        final held = [_HeldDecode(), _HeldDecode()];
        final requests = <ArtworkDecodeRequest>[];
        Future<void> mount(int edge) => tester.pumpWidget(
          MaterialApp(
            home: AlbumThumbnail(
              service: images,
              edge: edge,
              fit: BoxFit.contain,
              showLoading: true,
              entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
            ),
          ),
        );
        try {
          await mount(64);
          for (var i = 0; i < 100; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 16));
            if (find.byType(RawImage).evaluate().isNotEmpty &&
                tester.widget<RawImage>(find.byType(RawImage)).image != null) {
              break;
            }
          }
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image!.width,
            64,
          );
          expect(
            find.byKey(const ValueKey('album-image-loading')),
            findsNothing,
          );
          final paintedElement = tester.element(find.byType(Image));
          for (final provider in held) {
            requests.add(
              queue.request(
                provider,
                canStart: () => true,
                onStart: () {},
                onError: (_, _) {},
              )!,
            );
          }
          await tester.pump();
          expect(queue.activeCount, 2);
          await mount(512);
          await tester.pump();
          await tester.pump();
          // Both native slots are occupied. Keep the resident small frame
          // without flashing a loading treatment over a visible photograph.
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image!.width,
            64,
          );
          expect(tester.element(find.byType(Image)), same(paintedElement));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(const ValueKey('album-image-loading')),
            findsNothing,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          // No frame after pause: releasing native slots cannot admit queued
          // image work in background or remove the resident frame.
          for (final provider in held) {
            provider.release();
          }
          await tester.idle();
          expect(queue.activeCount, 0);
          expect(queue.pendingCount, 0);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          for (var i = 0; i < 100; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 16));
            if (find.byType(RawImage).evaluate().isNotEmpty &&
                tester.widget<RawImage>(find.byType(RawImage)).image?.width ==
                    512) {
              break;
            }
          }
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image!.width,
            512,
          );
          expect(
            find.byKey(const ValueKey('album-image-loading')),
            findsNothing,
          );
          expect(tester.element(find.byType(Image)), same(paintedElement));
        } finally {
          await tester.pumpWidget(const SizedBox());
          for (final request in requests) {
            request.cancel();
          }
          for (final provider in held) {
            provider.release();
          }
          await tester.pump();
          images.dispose();
          await tester.runAsync(() => directory.delete(recursive: true));
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      },
    );
  }

  testWidgets(
    'covered wall resizing retains its pixels and prepared JPEG path',
    (tester) async {
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'album-hidden-resize-',
        );
        await File('${directory.path}/photo.jpg').writeAsBytes(
          raster.encodeJpg(raster.Image(width: 1000, height: 500)),
        );
        return directory;
      }))!;
      final images = _CachedImages(
        '${directory.path}/photo.jpg',
        encodedSource: true,
      );
      Future<void> mount(bool active, int edge, double extent) =>
          tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: TickerMode(
                  enabled: active,
                  child: SizedBox.square(
                    dimension: extent,
                    child: AlbumThumbnail(
                      service: images,
                      edge: edge,
                      entry: const SourceEntry(
                        name: 'photo.jpg',
                        path: 'photo.jpg',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
      try {
        await mount(true, 256, 200);
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null) {
            break;
          }
        }
        final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
        final element = tester.element(find.byType(Image));
        expect(images.requestedEdges, [256]);
        images.setActive(false);
        await mount(false, 1024, 400);
        expect(tester.element(find.byType(Image)), same(element));
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(image),
          isTrue,
        );
        expect(images.requestedEdges, [256]);
        images.setActive(true);
        await mount(true, 256, 200);
        expect(tester.element(find.byType(Image)), same(element));
        expect(
          tester
              .widget<RawImage>(find.byType(RawImage))
              .image!
              .isCloneOf(image),
          isTrue,
        );
        expect(images.requestedEdges, [256]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets('native cache read failure removes loading animation', (
    tester,
  ) async {
    final images = _CachedImages('/missing-album-image/invalid.jpg');
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumThumbnail(
            service: images,
            showLoading: true,
            entry: const SourceEntry(name: 'bad.jpg', path: 'bad.jpg'),
          ),
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        if (images.requestedEdges.length == 3 &&
            find.byIcon(Icons.image_outlined).evaluate().isNotEmpty &&
            tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail !=
                null &&
            ArtworkDecodeQueue.instance.activeCount == 0 &&
            ArtworkDecodeQueue.instance.pendingCount == 0) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      images.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'viewer loading ticker stops on pause without a frame and on hiding or failure',
    (tester) async {
      final images = _PendingImages();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumThumbnail(
            service: images,
            showLoading: true,
            loadingPlaceholder: const ColoredBox(
              key: ValueKey('warm-image-preview'),
              color: Colors.grey,
            ),
            entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final animation =
          tester
                  .widget<RotationTransition>(
                    find.byKey(const ValueKey('album-image-loading')),
                  )
                  .turns
              as AnimationController;
      expect(animation.isAnimating, isTrue);
      expect(find.byKey(const ValueKey('warm-image-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-image-loading')), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No pump: the lifecycle signal cancels the scheduled ticker immediately.
      expect(animation.isAnimating, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(animation.isAnimating, isTrue);
      images.setActive(false);
      expect(animation.isAnimating, isFalse);
      images.setActive(true);
      expect(animation.isAnimating, isTrue);
      images.requests['photo.jpg']!.complete(
        const AlbumImageResult(error: 'unsupported'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      images.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful native image frame removes viewer loading animation',
    (tester) async {
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'album-spinner-',
        );
        await File(
          '${directory.path}/image.jpg',
        ).writeAsBytes(raster.encodeJpg(raster.Image(width: 40, height: 20)));
        return directory;
      }))!;
      final images = _CachedImages('${directory.path}/image.jpg');
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumThumbnail(
              service: images,
              showLoading: true,
              entry: const SourceEntry(name: 'image.jpg', path: 'image.jpg'),
            ),
          ),
        );
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null) {
            break;
          }
        }
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        images.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'newly visible cached album cells display while a scroll is still held',
    (tester) async {
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'album-warm-scroll-',
        );
        await File(
          '${directory.path}/thumb.jpg',
        ).writeAsBytes(raster.encodeJpg(raster.Image(width: 100, height: 100)));
        return directory;
      }))!;
      final images = _CachedImages('${directory.path}/thumb.jpg');
      final snapshot = AlbumIndex(
        [
          for (var index = 0; index < 100; index++)
            SourceEntry(
              name: '${index.toString().padLeft(3, '0')}.jpg',
              path: '$index.jpg',
            ),
        ],
        sourceId: 'test',
        directory: '/',
      ).filter(AlbumOptions());
      var scrolling = false;
      final scroll = ScrollController();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: ArtworkScrollScope(
                  onActivityChanged: (value) {
                    scrolling = value;
                    images.setScrolling(value);
                  },
                  child: AlbumWall(
                    controller: scroll,
                    snapshot: snapshot,
                    onOpen: (_) {},
                    thumbnail: (_, item, edge) => AlbumThumbnail(
                      service: images,
                      edge: edge,
                      entry: item.preferred,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (
          var n = 0;
          n < 80 &&
              !tester
                  .widgetList<RawImage>(find.byType(RawImage))
                  .any((image) => image.image != null);
          n++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          isTrue,
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(GridView)),
        );
        await gesture.moveBy(const Offset(0, -900));
        await tester.pump();
        expect(scrolling, isTrue);
        for (var n = 0; n < 20; n++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(scrolling, isTrue);
        expect(images.requested, contains('36.jpg'));
        final cell = find.byKey(ValueKey(snapshot.items[36].id));
        expect(
          tester
              .widgetList<RawImage>(
                find.descendant(of: cell, matching: find.byType(RawImage)),
              )
              .any((image) => image.image != null),
          isTrue,
        );
        await gesture.up();
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        images.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'filter or member changes cancel old demand and discard its late result',
    (tester) async {
      final images = _PendingImages();
      final loaded = <String?>[];
      Widget view(String path) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: AlbumThumbnail(
              service: images,
              entry: SourceEntry(name: path, path: path),
              onLoaded: (result) => loaded.add(result.sourcePath),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view('001.arw'));
      await tester.pumpAndSettle();
      expect(images.requests.keys, ['001.arw']);
      await tester.pumpWidget(view('001.jpg'));
      await tester.pumpAndSettle();
      expect(images.cancelled, contains('001.arw'));
      expect(images.requests.keys, contains('001.jpg'));
      images.requests['001.arw']!.complete(
        const AlbumImageResult(sourcePath: '001.arw', error: 'old'),
      );
      images.requests['001.jpg']!.complete(
        const AlbumImageResult(sourcePath: '001.jpg', error: 'new'),
      );
      await tester.pumpAndSettle();
      expect(loaded, ['001.jpg']);
      await tester.pumpWidget(const SizedBox());
      images.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the page releases demand before a late decoder finishes',
    (tester) async {
      final images = _PendingImages();
      var loaded = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: AlbumThumbnail(
                service: images,
                entry: const SourceEntry(name: 'photo.jpg', path: 'photo.jpg'),
                onLoaded: (_) => loaded++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(images.requests, contains('photo.jpg'));
      await tester.pumpWidget(const SizedBox());
      expect(images.cancelled, contains('photo.jpg'));
      images.dispose();
      images.requests['photo.jpg']!.complete(
        const AlbumImageResult(error: 'late'),
      );
      await tester.pumpAndSettle();
      expect(loaded, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
