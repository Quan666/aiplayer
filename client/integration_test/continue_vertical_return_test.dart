import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/continue_watching_presentation.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/continue_watching_content.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

// Native profile regression for returning vertically to the already viewed
// carousel. Unlike horizontal prefetch tests, the header leaves the sliver's
// cache area while the wall decodes enough distinct images to evict LRU entries.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('continue covers survive vertical departure and first return', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('continue-vertical-');
    await _seedInBackground(root.path);
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _Model(store, root);
    final writer = await _BackgroundWriter.open(store.path, model.changed);
    final cache = PaintingBinding.instance.imageCache;
    final oldSize = cache.maximumSize, oldBytes = cache.maximumSizeBytes;
    cache
      ..clear()
      ..clearLiveImages()
      ..maximumSize = 8
      ..maximumSizeBytes = 6 * 1024 * 1024;
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    final library = find.byKey(const PageStorageKey('library-scroll'));
    final content = find.byType(ContinueWatchingContent, skipOffstage: false);
    ScrollPosition position(Finder list) {
      final element =
          find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .evaluate()
                  .first
              as StatefulElement;
      return (element.state as ScrollableState).position;
    }

    Future<void> ready() => _wait(() {
      final cards = _visibleCards(carousel);
      return cards.isNotEmpty && cards.values.every((value) => value);
    });
    final reports = <Map<String, Object?>>[];
    const allowReturnFlash = bool.fromEnvironment('ALLOW_RETURN_FLASH');
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await _wait(() => carousel.evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await ready();
      for (var round = 0; round < 3; round++) {
        final horizontalTarget = [
          1050.0,
          1400.0,
          700.0,
        ][round].clamp(0.0, position(carousel).maxScrollExtent);
        await position(carousel).animateTo(
          horizontalTarget,
          duration: const Duration(milliseconds: 900),
          curve: Curves.linear,
        );
        await ready();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final initialElement = content.evaluate().single;
        final initialCards = _visibleCards(carousel).keys.toSet();
        final initialImages = _cardImages(carousel);
        final beforeCommits = writer.commits;
        final frames = <ui.FrameTiming>[];
        final wallPaths = <String>{};
        var observeWall = true;
        void wallSample(Duration _) {
          if (!observeWall) return;
          wallPaths.addAll(_readyWallPaths(library));
          WidgetsBinding.instance.addPostFrameCallback(wallSample);
        }

        void collect(List<ui.FrameTiming> values) => frames.addAll(values);
        WidgetsBinding.instance.addTimingsCallback(collect);
        WidgetsBinding.instance.addPostFrameCallback(wallSample);
        final watch = Stopwatch()..start();
        writer.start();
        final farOffset = 4200.0.clamp(0.0, position(library).maxScrollExtent);
        await position(library).animateTo(
          farOffset,
          duration: const Duration(milliseconds: 3500),
          curve: Curves.linear,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(_visibleCards(carousel), isEmpty);
        final retainedWhileAway = content.evaluate().any(
          (value) => identical(value, initialElement),
        );
        final awayPresentations = model.presentations;
        final awayPreviews = model.previews;
        final awayLibrarySnapshots = model.librarySnapshots;
        final awayStartCommits = writer.commits;
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final awayReads = model.presentations - awayPresentations;
        final awayPreviewCalls = model.previews - awayPreviews;
        final awayStructuralReads =
            model.librarySnapshots - awayLibrarySnapshots;
        final awayCommits = writer.commits - awayStartCommits;
        await writer.stop();
        final presentationsBeforeReturn = model.presentations;
        final observations = <String, ({int first, int? ready})>{};
        final returnFrames = <Map<String, Object?>>[];
        var observeReturn = true;
        void returnSample(Duration _) {
          if (!observeReturn) return;
          final visible = _visibleCards(carousel);
          if (visible.isNotEmpty) {
            final now = watch.elapsedMicroseconds;
            for (final card in visible.entries) {
              final previous = observations[card.key];
              observations[card.key] = (
                first: previous?.first ?? now,
                ready: previous?.ready ?? (card.value ? now : null),
              );
            }
            returnFrames.add({
              'elapsedMs': now / 1000,
              'verticalOffset': position(library).pixels,
              'horizontalOffset': position(carousel).pixels,
              'visibleCards': visible.length,
              'withPixels': visible.values.where((value) => value).length,
              'scrolling': position(library).isScrollingNotifier.value,
            });
          }
          WidgetsBinding.instance.addPostFrameCallback(returnSample);
        }

        WidgetsBinding.instance.addPostFrameCallback(returnSample);
        await position(library).animateTo(
          0,
          duration: const Duration(milliseconds: 5000),
          curve: Curves.linear,
        );
        await ready();
        await tester.pump();
        observeReturn = false;
        observeWall = false;
        watch.stop();
        final endingCards = _visibleCards(carousel);
        final endingImages = _cardImages(carousel);
        final horizontalActual = position(carousel).pixels;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        WidgetsBinding.instance.removeTimingsCallback(collect);
        final report = <String, Object?>{
          'round': round,
          'verticalDeparturePixels': farOffset,
          'horizontalOffsetBefore': horizontalTarget,
          'horizontalOffsetAfter': horizontalActual,
          'carouselElementRetainedWhileAway': retainedWhileAway,
          'carouselElementRetainedOnReturn': identical(
            content.evaluate().single,
            initialElement,
          ),
          'initialCards': initialCards.toList(),
          'endingCards': endingCards.keys.toList(),
          'sameDecodedImagesOnReturn': initialImages.entries
              .where((value) => identical(value.value, endingImages[value.key]))
              .length,
          'firstReturnVisibleCards': observations.length,
          'readyOnFirstVisibleFrame': observations.values
              .where((value) => value.first == value.ready)
              .length,
          'unresolvedCards': observations.values
              .where((value) => value.ready == null)
              .length,
          'returnFramesWithPlaceholder': returnFrames
              .where((value) => value['visibleCards'] != value['withPixels'])
              .length,
          'returnFramesWhileScrolling': returnFrames
              .where((value) => value['scrolling'] == true)
              .length,
          'offscreenObservationMs': 900,
          'offscreenProgressCommits': awayCommits,
          'offscreenPresentationLoadCalls': awayReads,
          'offscreenPreviewCallbacks': awayPreviewCalls,
          'offscreenStructuralSnapshotCalls': awayStructuralReads,
          'presentationLoadCallsOnReturn':
              model.presentations - presentationsBeforeReturn,
          'backgroundCommits': writer.commits - beforeCommits,
          'uniqueDecodedWallImages': wallPaths.length,
          'flutterImageCacheEntriesAfter': cache.currentSize,
          'flutterLiveImageEntriesAfter': cache.liveImageCount,
          'visibleToPixelsMs': _distribution(
            observations.values
                .where((value) => value.ready != null)
                .map((value) => (value.ready! - value.first) / 1000),
          ),
          'frameBuildMs': _distribution(
            frames.map((frame) => frame.buildDuration.inMicroseconds / 1000),
          ),
          'frameRasterMs': _distribution(
            frames.map((frame) => frame.rasterDuration.inMicroseconds / 1000),
          ),
          'returnFrames': returnFrames,
        };
        reports.add(report);
        debugPrint(
          'CONTINUE VERTICAL RETURN ${Map.of(report)..remove('returnFrames')}',
        );
        expect(observations, isNotEmpty);
        expect(returnFrames.any((frame) => frame['scrolling'] == true), isTrue);
        expect(wallPaths.length, greaterThan(8));
        expect(horizontalActual, closeTo(horizontalTarget, 1));
      }
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'scope':
            'Actual AIPlayerApp/LibraryPage; 1200 media records with unique on-disk 640x360 JPEG previews and valid fingerprints, 60 progress records, bounded 10-card carousel, three vertical 4200px departures/returns with nonzero horizontal positions; 8-entry/6-MiB decoded LRU cache pressure. Fixture encoding/file IO/SQL seeding and concurrent progress writes use separate isolates. Automatic video capture is disabled and callbacks counted; no network requests or video decoding. Linux/Xvfb software rendering, not Android/device FPS.',
        'latencyDefinition':
            'First painted frame with any card area visible to first RawImage pixels, keyed by history card IDs even when the thumbnail has not arrived. Zero means the previously viewed decoded image was retained, not zero IO/decode time. Each return is observed while vertical scrolling remains active.',
        'viewport': {
          'width':
              tester.view.physicalSize.width / tester.view.devicePixelRatio,
          'height':
              tester.view.physicalSize.height / tester.view.devicePixelRatio,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'imageCacheMaximumEntries': 8,
        'imageCacheMaximumBytes': 6 * 1024 * 1024,
        'backgroundCommitsAndNotifications': writer.commits,
        'baselineAllowsReturnFlash': allowReturnFlash,
        'scenarios': reports,
      };
      await _writeReportInBackground(
        const String.fromEnvironment(
          'CONTINUE_VERTICAL_ARTIFACT_DIR',
          defaultValue: '../artifacts/continue-vertical-return-20261023',
        ),
        report,
      );
      binding.reportData = report;
      if (!allowReturnFlash) {
        for (final round in reports) {
          expect(
            round['readyOnFirstVisibleFrame'],
            round['firstReturnVisibleCards'],
          );
          expect(round['returnFramesWithPlaceholder'], 0);
          expect(round['carouselElementRetainedWhileAway'], isTrue);
          expect(round['carouselElementRetainedOnReturn'], isTrue);
          expect(round['offscreenPresentationLoadCalls'], 0);
          expect(round['offscreenPreviewCallbacks'], 0);
        }
      }
      expect(tester.takeException(), isNull);
    } finally {
      await writer.close();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      cache
        ..clear()
        ..clearLiveImages()
        ..maximumSize = oldSize
        ..maximumSizeBytes = oldBytes;
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _wait(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Covers did not become ready.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ui.Image? _image(Element element) {
  if (element.widget case RawImage(:final image)) return image;
  ui.Image? found;
  element.visitChildren((child) {
    found ??= _image(child);
  });
  return found;
}

Map<String, ui.Image> _cardImages(Finder carousel) {
  final root = carousel.evaluate().firstOrNull;
  if (root == null) return {};
  final result = <String, ui.Image>{};
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('history:')) {
      final image = _image(element);
      if (image != null) result[key.value] = image;
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return result;
}

Map<String, bool> _visibleCards(Finder carousel) {
  final root = carousel.evaluate().firstOrNull;
  if (root == null) return {};
  final viewport = root.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return {};
  final clip = (viewport.localToGlobal(Offset.zero) & viewport.size).intersect(
    Offset.zero & MediaQuery.sizeOf(root),
  );
  if (clip.isEmpty) return {};
  final result = <String, bool>{};
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('history:')) {
      final box = element.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(clip)) {
        result[key.value] = _image(element) != null;
      }
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return result;
}

Set<String> _readyWallPaths(Finder library) {
  final root = library.evaluate().firstOrNull;
  if (root == null) return {};
  final result = <String>{};
  final screen = Offset.zero & MediaQuery.sizeOf(root);
  void visit(Element element) {
    if (element.widget is ContinueWatchingContent) return;
    if (element.widget case MediaArtwork(:final thumbnail)) {
      final box = element.findRenderObject();
      if (thumbnail != null &&
          box is RenderBox &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(screen) &&
          _image(element) != null) {
        result.add(thumbnail);
      }
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return result;
}

String _id(int index) => index.toString().padLeft(4, '0');
Future<void> _seedInBackground(String path) => Isolate.run(() => _seed(path));
void _seed(String path) {
  final image = img.Image(width: 640, height: 360);
  for (final pixel in image) {
    pixel.setRgb(pixel.x % 256, pixel.y % 256, (pixel.x + pixel.y) % 256);
  }
  final bytes = img.encodeJpg(image, quality: 85);
  final store = AppStore('$path/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var index = 0; index < 1200; index++) {
        final id = _id(index);
        store.save('media', id, {
          'title': 'Video $id.mp4',
          'fileName': 'Video $id.mp4',
          'series': 'Video $id',
          'size': 1024 + index,
          'duration': 3600,
        });
        {
          File('$path/$id.jpg').writeAsBytesSync(bytes);
          final request = MediaPreviewRequest(
            id,
            'local',
            '$path/$id.mp4',
            1024 + index,
            position: index < 60 ? 120.0 + index : null,
          );
          store.setLocal('location:$id', {
            'id': id,
            'source': request.source,
            'path': request.path,
            'size': request.size,
          });
          store.setLocal('preview:$id', {
            'path': '$path/$id.jpg',
            'formatVersion': MediaPreview.formatVersion,
            'fingerprint': request.fingerprint,
            'contentFingerprint': request.contentFingerprint,
          });
          if (index < 60) {
            store.save('progress', '$id:${1024 + index}', {
              'position': 120 + index,
              'duration': 3600,
              'updatedAt': DateTime.utc(
                2026,
                10,
                23,
                0,
                59 - index,
              ).toIso8601String(),
            });
          }
        }
      }
    });
  } finally {
    store.dispose();
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  int presentations = 0, librarySnapshots = 0, previews = 0;
  @override
  Future<Map<String, ContinueWatchingPresentation>>
  loadContinueWatchingPresentations(
    List<SyncRecord> items, {
    CancelToken? cancel,
  }) {
    presentations++;
    return super.loadContinueWatchingPresentations(items, cancel: cancel);
  }

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    librarySnapshots++;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
  }

  @override
  void ensureMediaPreview(String id) {
    previews++;
  }
}

class _BackgroundWriter {
  _BackgroundWriter(this._worker, this._events, this._port, this._notify);
  final Isolate _worker;
  final ReceivePort _events;
  final SendPort _port;
  final VoidCallback _notify;
  Timer? _timer;
  Completer<void>? _pending;
  int commits = 0;

  static Future<_BackgroundWriter> open(
    String path,
    VoidCallback notify,
  ) async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    _BackgroundWriter? result;
    events.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message == 'committed') {
        result!.commits++;
        result._notify();
        result._pending?.complete();
        result._pending = null;
      } else if (message == 'closed') {
        result!._pending?.complete();
        result._pending = null;
      }
    });
    final worker = await Isolate.spawn(_backgroundWriter, (
      path,
      events.sendPort,
    ));
    result = _BackgroundWriter(worker, events, await ready.future, notify);
    return result;
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (_pending != null) return;
      _pending = Completer<void>();
      _port.send(commits);
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _pending?.future;
  }

  Future<void> close() async {
    await stop();
    _pending = Completer<void>();
    _port.send(null);
    await _pending!.future;
    _events.close();
    _worker.kill();
  }
}

void _backgroundWriter((String, SendPort) args) async {
  final (path, events) = args;
  final requests = ReceivePort();
  final store = AppStore.openExisting(path);
  events.send(requests.sendPort);
  try {
    await for (final request in requests) {
      if (request == null) break;
      final record = store.get('progress', '0000:1024')!;
      store.save('progress', record.id, {
        ...record.data,
        'position': 120 + request as int,
      });
      events.send('committed');
    }
  } finally {
    store.dispose();
    requests.close();
    events.send('closed');
  }
}

Future<void> _writeReportInBackground(
  String path,
  Map<String, Object?> report,
) => Isolate.run(() {
  Directory(path).createSync(recursive: true);
  File(
    '$path/continue-vertical-return.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
});

Map<String, Object> _distribution(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return {'count': 0};
  return {
    'count': sorted.length,
    'p50': sorted[(sorted.length * .5).ceil() - 1],
    'p95': sorted[(sorted.length * .95).ceil() - 1],
    'max': sorted.last,
  };
}
