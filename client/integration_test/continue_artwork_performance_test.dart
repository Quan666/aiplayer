import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

// Run with flutter drive --profile on Linux in an isolated checkout. Uses the
// real app and image pipeline, controlled disk thumbnails and a bounded writer
// on another isolate. Software rendering is not a mobile/device FPS estimate.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile continue carousel and expanded history covers', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('continue-artwork-');
    await _seedInBackground(root.path);
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _Model(store, root);
    final writer = await _BackgroundWriter.open(store.path, model.changed);
    final reports = <Map<String, Object?>>[];
    final returns = <Map<String, Object?>>[];
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    final history = find.byKey(const PageStorageKey('library-history-grid'));
    ScrollPosition position(Finder list) => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;

    Future<void> ready(Finder list) => _wait(() {
      final visible = _visible(list);
      return visible.isNotEmpty && visible.values.every((value) => value);
    });

    Future<void> measure(String scenario, Finder list) async {
      await ready(list);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final direction in ['forward', 'reverse']) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final initial = _visible(list).keys.toSet();
        final observations = <String, ({int first, int? ready})>{};
        final frames = <ui.FrameTiming>[];
        final heartbeats = <double>[];
        final watch = Stopwatch()..start();
        var observing = true;
        var previousHeartbeat = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 8), (_) {
          final now = watch.elapsedMicroseconds;
          heartbeats.add((now - previousHeartbeat) / 1000);
          previousHeartbeat = now;
        });
        void sample(Duration _) {
          if (!observing) return;
          final now = watch.elapsedMicroseconds;
          for (final entry in _visible(list).entries) {
            if (initial.contains(entry.key)) continue;
            final previous = observations[entry.key];
            observations[entry.key] = (
              first: previous?.first ?? now,
              ready: previous?.ready ?? (entry.value ? now : null),
            );
          }
          WidgetsBinding.instance.addPostFrameCallback(sample);
        }

        void collect(List<ui.FrameTiming> values) => frames.addAll(values);
        WidgetsBinding.instance.addTimingsCallback(collect);
        WidgetsBinding.instance.addPostFrameCallback(sample);
        final startCommits = writer.commits;
        writer.start();
        final target = direction == 'forward'
            ? position(list).maxScrollExtent
            : 0.0;
        final startOffset = position(list).pixels;
        final distance = (target - startOffset).abs();
        await position(list).animateTo(
          target,
          duration: Duration(milliseconds: (distance / 600 * 1000).round()),
          curve: Curves.linear,
        );
        await tester.pump();
        observing = false;
        heartbeat.cancel();
        watch.stop();
        await writer.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        WidgetsBinding.instance.removeTimingsCallback(collect);
        expect(observations.length, greaterThan(3));
        expect(frames, isNotEmpty);
        reports.add({
          'scenario': scenario,
          'direction': direction,
          'requestedDistancePixels': distance,
          'distancePixels': (position(list).pixels - startOffset).abs(),
          'elapsedMs': watch.elapsedMilliseconds,
          'newVisibleCovers': observations.length,
          'readyOnFirstVisibleFrame': observations.values
              .where((value) => value.ready == value.first)
              .length,
          'unresolved': observations.values
              .where((value) => value.ready == null)
              .length,
          'backgroundCommits': writer.commits - startCommits,
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
          'mainIsolateHeartbeatIntervalMs': _distribution(heartbeats),
        });
        debugPrint('CONTINUE PROFILE ${reports.last}');
        await ready(list);
      }
    }

    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(AIPlayerApp(model: model));
      await _wait(() => carousel.evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await measure('continue-carousel', carousel);
      writer.start();
      for (var round = 0; round < 3; round++) {
        final before = position(carousel).maxScrollExtent * (round + 1) / 4;
        position(carousel).jumpTo(before);
        await ready(carousel);
        for (final page in [1, 2, 0]) {
          await tester.tap(find.byKey(ValueKey('nav-item-$page')));
          await tester.pumpAndSettle();
        }
        expect(position(carousel).pixels, closeTo(before, 1));
        final status = _visible(carousel);
        returns.add({
          'round': round,
          'scrollOffset': position(carousel).pixels,
          'visible': status.length,
          'readyOnReturn': status.values.where((value) => value).length,
        });
        expect(status.values, everyElement(isTrue));
      }
      await writer.stop();
      await tester.tap(find.text('继续观看'));
      await _wait(() => history.evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await measure('expanded-history', history);
      expect(writer.commits, greaterThan(0));
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'scope':
            'Full AIPlayerApp with 1200 media records, 60 history records and 10 carousel cards; unique 640x360 JPEG disk paths; fixture image encoding/file IO/SQLite writes on a background isolate; 600 pixels/second continuous forward/reverse scroll; bounded independent-connection progress writer and 9 tab switches. Linux Xvfb software rendering, controlled thumbnails, no network downloads or video capture; not mobile/device FPS and no before-change comparison.',
        'latencyDefinition':
            'First frame with any cover area visible to first RawImage pixels; initially visible covers excluded. 0ms means prepared before entry, not zero IO/decode time. Flutter decoded cache cleared initially; OS filesystem cache not cleared.',
        'viewport': {
          'width':
              tester.view.physicalSize.width / tester.view.devicePixelRatio,
          'height':
              tester.view.physicalSize.height / tester.view.devicePixelRatio,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'backgroundCommitsAndNotifications': writer.commits,
        'navigationSwitches': 9,
        'navigationReturns': returns,
        'scenarios': reports,
      };
      final artifactPath = const String.fromEnvironment(
        'CONTINUE_ARTWORK_ARTIFACT_DIR',
        defaultValue: '../artifacts/continue-artwork',
      );
      await _writeReportInBackground(artifactPath, report);
      binding.reportData = report;
    } finally {
      await writer.close();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _wait(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Covers did not become ready.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, bool> _visible(Finder list) {
  final root = list.evaluate().firstOrNull;
  if (root == null) return {};
  final viewport = root.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return {};
  final clip = (viewport.localToGlobal(Offset.zero) & viewport.size).intersect(
    Offset.zero & MediaQuery.sizeOf(root),
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
    if (element.widget case MediaArtwork(:final poster, :final thumbnail)) {
      final key = thumbnail ?? poster;
      final box = element.findRenderObject();
      if (key.isNotEmpty &&
          box is RenderBox &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(clip)) {
        result[key] = decoded(element);
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
        if (index < 60) {
          File('$path/$id.jpg').writeAsBytesSync(bytes);
          final request = MediaPreviewRequest(
            id,
            'local',
            '$path/$id.mp4',
            1024 + index,
            position: 120.0 + index,
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
    });
  } finally {
    store.dispose();
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  @override
  void ensureMediaPreview(String id) {}
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
    '$path/continue-artwork-performance.json',
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
