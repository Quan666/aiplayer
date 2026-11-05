import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

class _MissingPosterCache extends PosterCache {
  final File file;
  final List<int> bytes;
  int repairs = 0;

  _MissingPosterCache(this.file, this.bytes) : super(directory: file.parent);

  @override
  Future<File?> load(String url) => SynchronousFuture(file);

  @override
  Future<void> invalidate(
    String url, {
    File? failedFile,
    bool retryImmediately = false,
  }) async {
    repairs++;
    await file.writeAsBytes(bytes);
  }
}

class _ThumbnailChanges extends ChangeNotifier {
  int revision = 0;
  bool get listening => hasListeners;
  void publish({bool changed = true}) {
    if (changed) revision++;
    notifyListeners();
  }
}

bool _decoded() => find
    .byType(RawImage)
    .evaluate()
    .any((element) => (element.widget as RawImage).image != null);

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 100 && !ready(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  for (final queued in [false, true]) {
    testWidgets(
      '${queued ? 'queued native' : 'Image'} failure notifies once and same-path regeneration replaces its failed stream',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('missing-thumbnail-'),
        ))!;
        final file = File('${directory.path}/missing.png');
        final revision = ValueNotifier(0);
        final failures = <Object>[];
        final ready = <String>[];
        var edgeRevision = 0;
        var width = 128.0;
        Widget artwork() => MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: width,
              child: ValueListenableBuilder<int>(
                valueListenable: revision,
                builder: (_, generation, _) => MediaArtwork(
                  key: const ValueKey('retained-thumbnail'),
                  thumbnail: file.path,
                  thumbnailRevision: generation,
                  loadWhileScrolling: queued,
                  previewRevision: (generation, edgeRevision),
                  onThumbnailError: (path, error) {
                    expect(path, file.path);
                    expect(
                      SchedulerBinding.instance.schedulerPhase,
                      isNot(SchedulerPhase.persistentCallbacks),
                    );
                    failures.add(error);
                  },
                  onThumbnailReady: (path) {
                    expect(
                      SchedulerBinding.instance.schedulerPhase,
                      isNot(SchedulerPhase.persistentCallbacks),
                    );
                    ready.add(path);
                  },
                ),
              ),
            ),
          ),
        );
        try {
          await tester.pumpWidget(artwork());
          await _waitFor(tester, () => failures.isNotEmpty);
          expect(failures.single, isA<FileSystemException>());
          expect(ready, isEmpty);
          for (var frame = 0; frame < 5; frame++) {
            await tester.pumpWidget(artwork());
          }
          expect(failures, hasLength(1));
          edgeRevision++;
          await tester.pumpWidget(artwork());
          await tester.pump();
          expect(
            failures,
            hasLength(1),
            reason: 'A size update must not retry the same failed file.',
          );
          await tester.runAsync(
            () => file.writeAsBytes(
              raster.encodePng(raster.Image(width: 128, height: 64)),
            ),
          );
          revision.value++;
          await _waitFor(tester, () => _decoded() && ready.length == 1);
          expect(failures, hasLength(1));
          for (var frame = 0; frame < 5; frame++) {
            await tester.pumpWidget(artwork());
          }
          expect(ready, [file.path]);

          // A later disk deletion is a separate incident. Retained pixels from
          // the earlier stream must not report success for its failed upgrade.
          await tester.runAsync(file.delete);
          width = 256;
          await tester.pumpWidget(artwork());
          await _waitFor(tester, () => failures.length == 2);
          expect(ready, [file.path]);
          for (var frame = 0; frame < 5; frame++) {
            await tester.pumpWidget(artwork());
          }
          expect(failures, hasLength(2));
          expect(ready, [file.path]);
          await tester.runAsync(
            () => file.writeAsBytes(
              raster.encodePng(raster.Image(width: 128, height: 64)),
            ),
          );
          revision.value++;
          await _waitFor(tester, () => _decoded() && ready.length == 2);
          expect(ready, [file.path, file.path]);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          revision.dispose();
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          await tester.runAsync(() => directory.delete(recursive: true));
        }
      },
    );
  }

  testWidgets(
    'thumbnail repair signals bypass unchanged parent snapshots and defer paused decoding',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final fixtures = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'repair-signal-',
        );
        final bytes = raster.encodePng(raster.Image(width: 128, height: 64));
        return (directory, bytes);
      }))!;
      final file = File('${fixtures.$1.path}/repaired.png');
      final first = _ThumbnailChanges(), replacement = _ThumbnailChanges();
      var failures = 0, ready = 0;
      Widget artwork(_ThumbnailChanges changes) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 128,
            height: 128,
            child: MediaArtwork(
              thumbnail: file.path,
              thumbnailChanges: changes,
              thumbnailRevisionOf: () => changes.revision,
              loadWhileScrolling: true,
              onThumbnailError: (path, error) => failures++,
              onThumbnailReady: (path) => ready++,
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(artwork(first));
        final resident = tester.widget<MediaArtwork>(find.byType(MediaArtwork));
        await _waitFor(tester, () => failures == 1);
        await tester.pumpAndSettle();
        first.publish(changed: false);
        expect(tester.binding.hasScheduledFrame, isFalse);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.runAsync(() => file.writeAsBytes(fixtures.$2));
        first.publish();
        // No pump after pause or the repair signal. The affected image records
        // one dirty revision but cannot enqueue native decoding in background.
        await tester.idle();
        expect(ArtworkDecodeQueue.instance.activeCount, 0);
        expect(ArtworkDecodeQueue.instance.pendingCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(ready, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _waitFor(tester, () => _decoded() && ready == 1);
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)),
          same(resident),
        );
        await tester.pumpAndSettle();
        first.publish(changed: false);
        expect(tester.binding.hasScheduledFrame, isFalse);

        await tester.pumpWidget(artwork(replacement));
        await _waitFor(tester, () => _decoded() && ready == 2);
        expect(first.listening, isFalse);
        expect(replacement.listening, isTrue);
        await tester.pumpAndSettle();
        first.publish();
        replacement.publish(changed: false);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox());
        expect(replacement.listening, isFalse);
        replacement.publish();
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        first.dispose();
        replacement.dispose();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => fixtures.$1.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'same-path restoration before the owner probe clears the failed stream without removing metadata',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final fixtures = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'restored-race-',
        );
        final bytes = raster.encodePng(raster.Image(width: 128, height: 64));
        return (directory, bytes);
      }))!;
      final file = File('${fixtures.$1.path}/restored.png');
      final revision = ValueNotifier(0);
      var failures = 0, ready = 0;
      Future<void>? repair;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 128,
                height: 128,
                child: ValueListenableBuilder<int>(
                  valueListenable: revision,
                  builder: (_, generation, _) => MediaArtwork(
                    thumbnail: file.path,
                    thumbnailRevision: generation,
                    loadWhileScrolling: true,
                    onThumbnailError: (path, error) {
                      failures++;
                      repair = () async {
                        // Another bounded worker restores the same file before
                        // the owner's missing-file probe can remove metadata.
                        await file.writeAsBytes(fixtures.$2);
                        expect(await file.exists(), isTrue);
                        revision.value++;
                      }();
                    },
                    onThumbnailReady: (path) => ready++,
                  ),
                ),
              ),
            ),
          ),
        );
        final resident = tester.state(find.byType(MediaArtwork));
        await _waitFor(tester, () => _decoded() && ready == 1);
        await repair;
        expect(failures, 1);
        expect(tester.state(find.byType(MediaArtwork)), same(resident));
        expect(
          tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
          file.path,
        );
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump();
        }
        expect(ready, 1);
        expect(failures, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        revision.dispose();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => fixtures.$1.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'downloaded poster repairs a missing file again after an earlier repair succeeded',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('missing-poster-'),
      ))!;
      final file = File('${directory.path}/poster.image');
      final bytes = (await tester.runAsync(
        () async => raster.encodePng(raster.Image(width: 512, height: 256)),
      ))!;
      final cache = _MissingPosterCache(file, bytes);
      Future<void> mount(double width) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: width,
              child: MediaArtwork(
                poster: 'missing-poster',
                cache: cache,
                loadWhileScrolling: true,
              ),
            ),
          ),
        ),
      );
      try {
        await mount(128);
        await _waitFor(tester, () => cache.repairs == 1 && _decoded());
        await tester.runAsync(file.delete);
        await mount(256);
        await _waitFor(tester, () => cache.repairs == 2);
        await _waitFor(
          tester,
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image?.width == 512),
        );
        expect(cache.repairs, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        cache.close();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
