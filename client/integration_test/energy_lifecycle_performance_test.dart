import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as images;
import 'package:integration_test/integration_test.dart';

// Full-app lifecycle/idle workload, not a battery or mobile FPS measurement.
// flutter drive --profile -d linux --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/energy_lifecycle_performance_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile idle and background library work', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('energy-profile-');
    await _seed(root.path);
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _Model(store, root);
    final writer = await _BackgroundWriter.open(store.path, model.changed);
    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    final report = <String, Object?>{
      'mode': kProfileMode ? 'profile' : 'debug',
      'platform': Platform.operatingSystem,
      'historyRecords': 100,
      'scope':
          'Full AIPlayerApp, 3000 media records, disk database, independent '
          'bounded background progress writer, idle/lifecycle/scroll/9 tab switches. '
          '12 cached posters, non-playback video-preview request counter. '
          'Linux Xvfb software rendering; no media decoding, real server '
          'sync or mobile battery measurement; no before-change comparison.',
    };
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await _wait(() => find.text('3000').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      WidgetsBinding.instance.addTimingsCallback(collect);
      final idleReads = model.reads;
      await Future<void>.delayed(const Duration(seconds: 3));
      report['idle'] = {
        'durationMs': 3000,
        'frames': frames.length,
        'libraryReads': model.reads - idleReads,
      };
      expect(frames, isEmpty);
      expect(model.reads, idleReads);

      // Use inactive to keep the engine capable of rendering: zero background
      // work must result from app gating, not from the engine disabling vsync.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      frames.clear();
      final hiddenReads = model.reads, startCommits = writer.commits;
      writer.start();
      await Future<void>.delayed(const Duration(seconds: 3));
      await writer.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      report['background'] = {
        'durationMs': 3000,
        'frames': frames.length,
        'libraryReads': model.reads - hiddenReads,
        'commits': writer.commits - startCommits,
      };
      expect(writer.commits - startCommits, greaterThan(10));
      expect(model.reads, hiddenReads);
      expect(frames, isEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _wait(() => model.reads > hiddenReads);
      await tester.pumpAndSettle();
      report['resumeLibraryReads'] = model.reads - hiddenReads;
      expect(model.reads, hiddenReads + 1);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      frames.clear();
      final heartbeatIntervals = <double>[];
      final watch = Stopwatch()..start();
      var lastBeat = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 8), (_) {
        final now = watch.elapsedMicroseconds;
        heartbeatIntervals.add((now - lastBeat) / 1000);
        lastBeat = now;
      });
      final beforeInteractionCommits = writer.commits;
      writer.start();
      try {
        final library = find.byKey(const PageStorageKey('library-scroll'));
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: library, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        await position.animateTo(
          position.maxScrollExtent.clamp(0, 1600),
          duration: const Duration(seconds: 2),
          curve: Curves.linear,
        );
        for (var round = 0; round < 3; round++) {
          for (final page in [1, 2, 0]) {
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
          }
        }
      } finally {
        heartbeat.cancel();
        await writer.stop();
      }
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      report['scrollAndNavigation'] = {
        'tabSwitches': 9,
        'backgroundCommits': writer.commits - beforeInteractionCommits,
        'buildMs': _distribution(
          frames.map((f) => f.buildDuration.inMicroseconds / 1000),
        ),
        'rasterMs': _distribution(
          frames.map((f) => f.rasterDuration.inMicroseconds / 1000),
        ),
        'mainIsolateHeartbeatMs': _distribution(heartbeatIntervals),
      };

      final libraryScroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('library-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      libraryScroll.jumpTo(0);
      await tester.pumpAndSettle();
      await _wait(() => find.text('继续观看').evaluate().isNotEmpty);
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('library-history-grid')),
        findsOneWidget,
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      frames.clear();
      final historyReads = model.reads, historyCommits = writer.commits;
      writer.start();
      await Future<void>.delayed(const Duration(seconds: 3));
      await writer.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      report['historyBackground'] = {
        'frames': frames.length,
        'libraryReads': model.reads - historyReads,
        'commits': writer.commits - historyCommits,
      };
      expect(model.reads, historyReads);
      expect(frames, isEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _wait(() => model.reads > historyReads);
      await tester.pumpAndSettle();
      report['historyResumeLibraryReads'] = model.reads - historyReads;
      expect(model.reads, historyReads + 1);
      report['unnecessaryVideoPreviewRequests'] = model.previewRequests;
      expect(model.previewRequests, 0);
      expect(tester.takeException(), isNull);
      binding.reportData = report;
      debugPrint(jsonEncode(report));
      await _writeReport(report);
    } finally {
      WidgetsBinding.instance.removeTimingsCallback(collect);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await writer.close();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  int reads = 0;
  int previewRequests = 0;
  @override
  void ensureMediaPreview(String id) {
    // Continue-watching covers intentionally prefer a progress screenshot.
    // Count only poster cards without a playback position to capture.
    if ((int.tryParse(id) ?? 0) >= 100) previewRequests++;
    super.ensureMediaPreview(id);
  }

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    reads++;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
  }
}

Future<void> _wait(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for app');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _seed(String path) => Isolate.run(() {
  final posters = Directory('$path/poster-cache-v1')
    ..createSync(recursive: true);
  for (var i = 0; i < 12; i++) {
    final image = images.Image(width: 320, height: 180)
      ..clear(images.ColorRgb8(40 + i * 15, 90, 160));
    images.fillRect(
      image,
      x1: 40,
      y1: 30,
      x2: 180,
      y2: 140,
      color: images.ColorRgb8(220, 180 - i * 8, 80),
    );
    final name = sha256.convert(utf8.encode('https://artwork.invalid/$i.jpg'));
    File(
      '${posters.path}/$name.image',
    ).writeAsBytesSync(images.encodeJpg(image));
  }
  final store = AppStore('$path/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var i = 0; i < 3000; i++) {
        store.save('media', '$i', {
          'title': '视频 $i.mp4',
          'series': '未分类',
          'size': i + 1,
          'poster': 'https://artwork.invalid/${i % 12}.jpg',
        });
      }
      for (var i = 0; i < 100; i++) {
        store.save('progress', '$i:${i + 1}', {
          'position': 10,
          'duration': 1000,
          'updatedAt': '2026-10-23T00:00:00Z',
        });
      }
    });
  } finally {
    store.dispose();
  }
});

Future<void> _writeReport(Map<String, Object?> report) => Isolate.run(() {
  const path = String.fromEnvironment(
    'ENERGY_ARTIFACT_DIR',
    defaultValue: '../artifacts/energy-20261023',
  );
  Directory(path).createSync(recursive: true);
  File(
    '$path/energy-lifecycle-profile.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
});

Map<String, Object> _distribution(Iterable<double> samples) {
  final values = samples.toList()..sort();
  if (values.isEmpty) return {'count': 0};
  return {
    'count': values.length,
    'p50': values[(values.length * .5).ceil() - 1],
    'p95': values[(values.length * .95).ceil() - 1],
    'max': values.last,
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
      final record = store.get('progress', '0:1')!;
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
