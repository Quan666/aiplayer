import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

// xvfb-run -a flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/library_artwork_performance_test.dart
// --dart-define=LIBRARY_ARTWORK_ARTIFACT_DIR=/absolute/artifact/path
// Full application, real disk database and local JPEGs. Software rendering
// measurements cannot establish users' hardware frame rates or network latency.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile full library poster traversal and warm returns', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    const count = 640;
    final root = await Directory.systemTemp.createTemp('library-artwork-');
    // Image encoding, hashing, file writes and database creation all run away
    // from the main isolate, even though fixture setup is outside measurement.
    final fixture = await compute(_prepareFixture, (root.path, count));
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _ProfileModel(store, root);
    final writer = await _BackgroundWriter.open(store.path, model.changed);
    final phases = <Map<String, Object?>>[];
    final firstFrames = <Map<String, Object?>>[];
    final visited = <String>{};
    final decodedDuringScrolling = <String>{};
    var activeScrollingSamples = 0;
    final scroll = find.byKey(const PageStorageKey('library-scroll'));
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        )
        .position;

    Future<void> resolve(String stage) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final status = _visibleImages(tester, scroll);
        if (status.visible > 0 && status.missing.isEmpty) {
          visited.addAll(status.posters);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 12));
        await tester.pump();
      }
      final status = _visibleImages(tester, scroll);
      fail(
        '$stage: ${status.missing.length}/${status.visible} unresolved '
        'visible posters: ${status.missing}',
      );
    }

    Future<void> measure(String name, Future<void> Function() action) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final timings = <ui.FrameTiming>[];
      final heartbeat = <Duration>[];
      final watch = Stopwatch()..start();
      var previous = Duration.zero;
      final timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
        final now = watch.elapsed;
        heartbeat.add(now - previous);
        previous = now;
      });
      void collect(List<ui.FrameTiming> frames) => timings.addAll(frames);
      WidgetsBinding.instance.addTimingsCallback(collect);
      try {
        await action();
        await tester.pumpAndSettle();
        watch.stop();
        timer.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        timer.cancel();
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      expect(timings, isNotEmpty);
      phases.add({
        'phase': name,
        'elapsedMs': watch.elapsedMilliseconds,
        'frames': timings.length,
        'buildMs': _distribution(timings.map((f) => f.buildDuration)),
        'rasterMs': _distribution(timings.map((f) => f.rasterDuration)),
        'totalSpanMs': _distribution(timings.map((f) => f.totalSpan)),
        'mainIsolateHeartbeatIntervalMs': _distribution(heartbeat),
        'imageCacheEntries': PaintingBinding.instance.imageCache.currentSize,
        'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      });
    }

    Future<void> warmJump(String name, double target) async {
      position().jumpTo(target);
      await tester.pump();
      final status = _visibleImages(tester, scroll);
      expect(status.visible, greaterThan(0));
      firstFrames.add({
        'stage': name,
        'visible': status.visible,
        'decodedOnFirstFrame': status.visible - status.missing.length,
        'missingOnFirstFrame': status.missing.length,
      });
      if (name == 'near-bottom-return' || name == 'near-top-return') {
        expect(
          status.missing,
          isEmpty,
          reason: 'Recently decoded sliver children must reappear immediately',
        );
      }
      // First-frame completeness is reported rather than assumed: decoded
      // entries may legitimately have been evicted by the large traversal.
      await resolve(name);
    }

    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(AIPlayerApp(model: model));
      await resolve('initial');
      expect(find.text('全部视频'), findsOneWidget);
      await tester.pumpAndSettle();
      final initialImages = _visibleImages(tester, scroll).visible;

      await measure('continuous-scroll-with-background-commits', () async {
        final initial = _visibleImages(tester, scroll).posters.toSet();
        writer.start();
        var completed = false;
        final movement = position()
            .animateTo(
              position().viewportDimension * 4,
              duration: const Duration(seconds: 2),
              curve: Curves.linear,
            )
            .whenComplete(() => completed = true);
        while (!completed) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await tester.pump();
          if (!position().isScrollingNotifier.value) continue;
          activeScrollingSamples++;
          final status = _visibleImages(tester, scroll);
          decodedDuringScrolling.addAll(
            status.posters.where(
              (url) => !initial.contains(url) && !status.missing.contains(url),
            ),
          );
        }
        await movement;
        await writer.stop();
        await resolve('continuous-scroll-settled');
        expect(activeScrollingSamples, greaterThan(0));
        expect(
          decodedDuringScrolling,
          isNotEmpty,
          reason: 'New visible local posters must decode before scrolling ends',
        );
        position().jumpTo(0);
        await tester.pump();
        await resolve('continuous-scroll-return');
      });

      await measure('cold-scroll-to-bottom', () async {
        writer.start();
        var steps = 0;
        while (position().extentAfter > 1) {
          final target = math.min(
            position().maxScrollExtent,
            position().pixels + position().viewportDimension * .72,
          );
          await position().animateTo(
            target,
            duration: const Duration(milliseconds: 100),
            curve: Curves.linear,
          );
          await resolve('down/${steps++}');
        }
        await writer.stop();
      });
      expect(
        visited.length,
        count,
        reason: 'Every distinct poster was decoded',
      );
      final bottom = position().pixels;
      final viewport = position().viewportDimension;

      await measure('warm-scroll-back-to-top', () async {
        await warmJump('near-bottom-return', math.max(0, bottom - viewport));
        var steps = 0;
        while (position().pixels > 1) {
          await position().animateTo(
            math.max(0, position().pixels - viewport * .72),
            duration: const Duration(milliseconds: 100),
            curve: Curves.linear,
          );
          await resolve('up/${steps++}');
        }
        await warmJump('top-revisit-after-full-traversal', 0);
      });

      await measure('warm-recreation', () async {
        // Force disposal of the initial sliver children while retaining the
        // recent decoded cache, then inspect their first rendered return frame.
        await warmJump('near-top-away', viewport * 4);
        await warmJump('near-top-return', 0);
      });

      await measure('navigation-with-background-commits', () async {
        writer.start();
        for (var round = 0; round < 3; round++) {
          await warmJump('navigation-offset-$round', viewport * (round + 1));
          final before = position().pixels;
          for (final page in [1, 2, 0]) {
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
          }
          expect(position().pixels, closeTo(before, 1));
          await resolve('navigation-return-$round');
        }
        await writer.stop();
      });
      expect(writer.commits, greaterThan(0));
      expect(model.networkAttempts, 0);
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
        'platform': Platform.operatingSystem,
        'scope':
            'full AIPlayerApp; 640 distinct poster URLs and disk files; '
            'real SQLite with bounded separate-connection background commits; '
            'all-video wall to bottom/back; repeated tab switches; '
            'offline local images; software desktop rendering; no device or '
            'network performance guarantee',
        'fixture': fixture,
        'viewport': {
          'width':
              tester.view.physicalSize.width / tester.view.devicePixelRatio,
          'height':
              tester.view.physicalSize.height / tester.view.devicePixelRatio,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'uniquePostersDecoded': visited.length,
        'newPostersDecodedWhileScrolling': decodedDuringScrolling.length,
        'activeScrollingSamples': activeScrollingSamples,
        'initialVisibleImages': initialImages,
        'backgroundCommitsAndNotifications': writer.commits,
        'navigationSwitches': 9,
        'networkAttempts': model.networkAttempts,
        'coldDefinition':
            'Flutter image cache empty and fresh PosterCache; '
            'persistent JPEGs exist; OS filesystem cache is not reset',
        'firstFrameReturns': firstFrames,
        'phases': phases,
      };
      final artifacts = Directory(
        const String.fromEnvironment(
          'LIBRARY_ARTWORK_ARTIFACT_DIR',
          defaultValue: '../artifacts',
        ),
      );
      await artifacts.create(recursive: true);
      final output = '${artifacts.path}/library-artwork-performance.json';
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      binding.reportData = report;
      debugPrint('Library artwork report: $output');
    } finally {
      await writer.close();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

({int visible, List<String> posters, List<String> missing}) _visibleImages(
  WidgetTester tester,
  Finder scroll,
) {
  if (scroll.evaluate().isEmpty) return (visible: 0, posters: [], missing: []);
  final nativeViewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  final viewport = tester.getRect(scroll).intersect(nativeViewport);
  final posters = <String>[];
  final missing = <String>[];
  for (final element
      in find
          .descendant(of: scroll, matching: find.byType(MediaArtwork))
          .evaluate()) {
    final finder = find.byElementPredicate(
      (other) => identical(other, element),
    );
    if (!tester.getRect(finder).overlaps(viewport)) continue;
    final artwork = element.widget as MediaArtwork;
    posters.add(artwork.poster);
    final images = tester.widgetList<RawImage>(
      find.descendant(of: finder, matching: find.byType(RawImage)),
    );
    if (!images.any((image) => image.image != null)) {
      missing.add(artwork.poster);
    }
  }
  return (visible: posters.length, posters: posters, missing: missing);
}

class _ProfileModel extends AppModel {
  _ProfileModel(super.store, super.documents) : super(backgroundWork: false);
  int networkAttempts = 0;
  late final _cache = PosterCache(
    directory: Directory('${documents.path}/poster-cache-v1'),
    createClient: () {
      networkAttempts++;
      throw StateError('The profile fixture must remain offline');
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

Map<String, Object> _prepareFixture((String, int) args) {
  final (root, count) = args;
  final directory = Directory('$root/poster-cache-v1')..createSync();
  final cache = PosterCache(directory: directory);
  final store = AppStore('$root/library.db');
  var bytes = 0;
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    // Encode 16 visual patterns; distinct URLs, paths and JPEG comments keep
    // 640 independent cache entries without spending minutes on setup encoding.
    final patterns = List.generate(16, (pattern) {
      final image = img.Image(width: 480, height: 720);
      for (final pixel in image) {
        pixel.setRgb(
          (pixel.x ~/ 2 + pattern * 13) % 256,
          (pixel.y ~/ 3 + pattern * 23) % 256,
          ((pixel.x + pixel.y) ~/ 4 + pattern * 31) % 256,
        );
      }
      return img.encodeJpg(image, quality: 85);
    });
    store.transaction(() {
      for (var index = 0; index < count; index++) {
        final id = index.toString().padLeft(4, '0');
        final url = 'https://library-artwork.invalid/$id.jpg';
        final jpg = patterns[index % patterns.length];
        final comment = utf8.encode('poster-$id');
        final image = <int>[
          ...jpg.take(2),
          0xff,
          0xfe,
          0,
          comment.length + 2,
          ...comment,
          ...jpg.skip(2),
        ];
        cache.cachedFile(url).writeAsBytesSync(image);
        bytes += image.length;
        store.save('media', id, {
          'title': 'Poster $id S01E01.mkv',
          'series': 'Poster $id',
          'metadataTitle': 'Poster $id',
          'metadataProvider': 'bangumi',
          'bangumiId': '${10000 + index}',
          'poster': url,
          'season': '1',
          'episode': '1',
          'size': index + 1,
        });
      }
    });
  } finally {
    store.dispose();
    cache.close();
  }
  return {
    'posters': count,
    'visualPatterns': 16,
    'width': 480,
    'height': 720,
    'totalBytes': bytes,
    'preparationIsolate': Isolate.current.hashCode,
  };
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
      final index = request as int;
      final id = (index % 640).toString().padLeft(4, '0');
      final record = store.get('media', id)!;
      store.save('media', id, {
        ...record.data,
        'summary': 'Background edit $index',
      });
      events.send('committed');
    }
  } finally {
    store.dispose();
    requests.close();
    events.send('closed');
  }
}

Map<String, Object> _distribution(Iterable<Duration> values) {
  final sorted = values.map((value) => value.inMicroseconds / 1000).toList()
    ..sort();
  if (sorted.isEmpty) return {'count': 0};
  return {
    'count': sorted.length,
    'p50': sorted[(sorted.length * .5).ceil() - 1],
    'p95': sorted[(sorted.length * .95).ceil() - 1],
    'max': sorted.last,
    'over16_67ms': sorted.where((value) => value > 1000 / 60).length,
    'over33_33ms': sorted.where((value) => value > 1000 / 30).length,
  };
}
