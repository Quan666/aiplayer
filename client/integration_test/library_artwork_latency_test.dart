import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

// Full-app latency probe. Run through the existing integration driver in
// --profile mode with LIBRARY_ARTWORK_LATENCY_ARTIFACT_DIR set to a directory.
// A rendered RawImage, not a placeholder or completed download, ends the timer.
// Local HTTP delay is controlled; Linux software rendering is not device FPS.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('measure visible-to-real-poster latency during continuous scroll', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final reports = <Map<String, Object?>>[];
    for (final scenario in ['cold-disk', 'http-180ms']) {
      final root = await Directory.systemTemp.createTemp('poster-latency-');
      final fixture = await _Fixture.open(root.path, scenario);
      final store = AppStore.openExisting('${root.path}/library.db');
      final model = AppModel(store, root, backgroundWork: false);
      final scroll = find.byKey(const PageStorageKey('library-scroll'));
      try {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.pumpWidget(AIPlayerApp(model: model));
        Future<void> waitForVisible() async {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (DateTime.now().isBefore(deadline)) {
            final images = _visibleImages(scroll);
            if (images.isNotEmpty && images.values.every((ready) => ready)) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          fail('Visible images did not resolve for $scenario');
        }

        await waitForVisible();
        await tester.pumpAndSettle();
        // Preserve normal near-viewport preparation before the gesture. This
        // short fixed idle interval is identical in baseline and final builds.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: scroll, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        final initiallyVisible = _visibleImages(scroll).keys.toSet();
        final observations = <String, _Observation>{};
        final frameTimings = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> values) =>
            frameTimings.addAll(values);
        final watch = Stopwatch();
        var observing = true;
        var framesObserved = 0;
        void sample(Duration _) {
          if (!observing) return;
          framesObserved++;
          final now = watch.elapsedMicroseconds;
          final visible = _visibleImages(scroll);
          for (final entry in visible.entries) {
            if (initiallyVisible.contains(entry.key)) continue;
            final value = observations.putIfAbsent(
              entry.key,
              () => _Observation(now, entry.value),
            );
            value.lastVisibleUs = now;
            if (entry.value && value.decodedUs == null) {
              value.decodedUs = now;
              value.decodedWhileScrolling = position.isScrollingNotifier.value;
            }
          }
          WidgetsBinding.instance.addPostFrameCallback(sample);
        }

        // Timings arrive in engine batches; drain earlier frames before capture.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        WidgetsBinding.instance.addTimingsCallback(collect);
        watch.start();
        WidgetsBinding.instance.addPostFrameCallback(sample);
        await position.animateTo(
          7200,
          duration: const Duration(seconds: 12),
          curve: Curves.linear,
        );
        final gestureEndUs = watch.elapsedMicroseconds;
        await waitForVisible();
        await tester.pump();
        observing = false;
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        WidgetsBinding.instance.removeTimingsCallback(collect);
        expect(observations.length, greaterThan(40));
        expect(frameTimings, isNotEmpty);
        final resolved = observations.values.where((v) => v.decodedUs != null);
        final unresolved = observations.values.where(
          (v) => v.decodedUs == null,
        );
        final readyFirstFrame = observations.values
            .where((v) => v.readyFirstFrame)
            .length;
        reports.add({
          'scenario': scenario,
          'libraryPosters': 640,
          'scrollPixels': position.pixels,
          'gestureElapsedMs': gestureEndUs / 1000,
          'observedFrames': framesObserved,
          'newVisiblePosters': observations.length,
          'resolvedPosters': resolved.length,
          'unresolvedBeforeLeavingViewport': unresolved.length,
          'decodedWhileScrolling': resolved
              .where((v) => v.decodedWhileScrolling)
              .length,
          'readyOnFirstVisibleFrame': readyFirstFrame,
          'readyOnFirstVisibleFrameFraction':
              readyFirstFrame / observations.length,
          'visibleToActualPixelsMs': _distribution(
            resolved.map((v) => (v.decodedUs! - v.firstVisibleUs) / 1000),
          ),
          'unresolvedVisibleExposureMs': _distribution(
            unresolved.map((v) => (v.lastVisibleUs - v.firstVisibleUs) / 1000),
          ),
          'frameBuildMs': _distribution(
            frameTimings.map((f) => f.buildDuration.inMicroseconds / 1000),
          ),
          'frameRasterMs': _distribution(
            frameTimings.map((f) => f.rasterDuration.inMicroseconds / 1000),
          ),
          'perPoster': [
            for (final entry in observations.entries)
              {
                'poster': Uri.parse(entry.key).path,
                'firstVisibleMs': entry.value.firstVisibleUs / 1000,
                'actualPixelsMs': entry.value.decodedUs == null
                    ? null
                    : entry.value.decodedUs! / 1000,
                'waitMs': entry.value.decodedUs == null
                    ? null
                    : (entry.value.decodedUs! - entry.value.firstVisibleUs) /
                          1000,
                'firstFrameReady': entry.value.readyFirstFrame,
                'decodedWhileScrolling': entry.value.decodedWhileScrolling,
              },
          ],
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await model.sync.dispose();
        store.dispose();
        await fixture.close();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await root.delete(recursive: true);
      }
    }
    final report = <String, Object?>{
      'mode': kProfileMode ? 'profile' : 'debug',
      'scope':
          'Full AIPlayerApp, 640 distinct URLs/files, 480x720 JPEGs; '
          '12 seconds continuous 600 logical pixels/second; separate-isolate '
          'disk/database/image fixture and loopback HTTP server; HTTP responses '
          'delayed 180 ms; frame-by-frame real RawImage observation; '
          'Linux software rendering, not user-device FPS or WAN simulation',
      'latencyDefinition':
          'Elapsed wall-clock time from first rendered frame '
          'with any poster area visible until first rendered RawImage pixels; '
          'frame-quantized; initially visible posters excluded; unresolved '
          'posters reported separately to avoid hiding censored samples',
      'coldDefinition':
          'Fresh AppModel and Flutter decoded cache; disk case '
          'has persistent files with OS cache retained; HTTP case has no files',
      'viewport': {
        'width': tester.view.physicalSize.width / tester.view.devicePixelRatio,
        'height':
            tester.view.physicalSize.height / tester.view.devicePixelRatio,
        'devicePixelRatio': tester.view.devicePixelRatio,
      },
      'scenarios': reports,
    };
    final artifacts = Directory(
      const String.fromEnvironment(
        'LIBRARY_ARTWORK_LATENCY_ARTIFACT_DIR',
        defaultValue: '../artifacts',
      ),
    );
    await artifacts.create(recursive: true);
    final file = File('${artifacts.path}/library-artwork-latency.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    binding.reportData = report;
    debugPrint('Poster latency report: ${file.path}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _Observation {
  _Observation(this.firstVisibleUs, this.readyFirstFrame)
    : lastVisibleUs = firstVisibleUs;
  final int firstVisibleUs;
  final bool readyFirstFrame;
  int lastVisibleUs;
  int? decodedUs;
  bool decodedWhileScrolling = false;
}

Map<String, bool> _visibleImages(Finder scroll) {
  final roots = scroll.evaluate();
  if (roots.isEmpty) return {};
  final root = roots.single;
  final viewport = root.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return {};
  final screen = Offset.zero & MediaQuery.sizeOf(root);
  final clip = (viewport.localToGlobal(Offset.zero) & viewport.size).intersect(
    screen,
  );
  final result = <String, bool>{};
  bool decoded(Element element) {
    if (element.widget case RawImage(:final image)) return image != null;
    var found = false;
    element.visitChildren((child) {
      if (!found) found = decoded(child);
    });
    return found;
  }

  void visit(Element element) {
    if (element.widget case MediaArtwork(:final poster)) {
      final box = element.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(clip)) {
        result[poster] = decoded(element);
      }
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return result;
}

class _Fixture {
  _Fixture(this.worker, this.events, this.port, this.closed);
  final Isolate worker;
  final ReceivePort events;
  final SendPort port;
  final Completer<void> closed;
  static Future<_Fixture> open(String path, String scenario) async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final closed = Completer<void>();
    events.listen((message) {
      if (message is SendPort) ready.complete(message);
      if (message == 'closed') closed.complete();
      if (message is String && !ready.isCompleted) {
        ready.completeError(StateError(message));
      }
    });
    final worker = await Isolate.spawn(_fixtureWorker, (
      path,
      scenario,
      events.sendPort,
    ));
    return _Fixture(worker, events, await ready.future, closed);
  }

  Future<void> close() async {
    port.send(null);
    await closed.future;
    events.close();
    worker.kill();
  }
}

void _fixtureWorker((String, String, SendPort) args) async {
  final (root, scenario, events) = args;
  final requests = ReceivePort();
  HttpServer? server;
  AppStore? store;
  PosterCache? cache;
  try {
    final image = img.Image(width: 480, height: 720);
    for (final pixel in image) {
      pixel.setRgb(
        pixel.x ~/ 2 % 256,
        pixel.y ~/ 3 % 256,
        (pixel.x + pixel.y) ~/ 4 % 256,
      );
    }
    final jpg = img.encodeJpg(image, quality: 85);
    var origin = 'https://poster-latency.invalid';
    if (scenario == 'http-180ms') {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        try {
          request.response
            ..headers.contentType = ContentType('image', 'jpeg')
            ..contentLength = jpg.length
            ..add(jpg);
          await request.response.close();
        } catch (_) {
          // The application may cancel an offscreen request during teardown.
        }
      });
    }
    final directory = Directory('$root/poster-cache-v1')..createSync();
    cache = PosterCache(directory: directory);
    store = AppStore('$root/library.db');
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var index = 0; index < 640; index++) {
        final id = index.toString().padLeft(4, '0');
        final url = '$origin/$id.jpg';
        if (scenario == 'cold-disk') {
          cache!.cachedFile(url).writeAsBytesSync(jpg);
        }
        store!.save('media', id, {
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
    store.dispose();
    store = null;
    events.send(requests.sendPort);
    await requests.first;
  } catch (error, trace) {
    events.send('$error\n$trace');
  } finally {
    store?.dispose();
    cache?.close();
    await server?.close(force: true);
    requests.close();
    events.send('closed');
  }
}

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
