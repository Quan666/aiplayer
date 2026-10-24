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
import 'package:integration_test/integration_test.dart';

// Full-app sorting workload. Software desktop rendering is not mobile FPS.
// flutter drive --profile -d linux --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/library_sort_performance_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile library sorting during progress writes and navigation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('library-sort-profile-');
    await _seed(root.path);
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _Model(store, root);
    final writer = await _BackgroundWriter.open(store.path, model.changed);
    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    final phases = <String, Object?>{};
    final report = <String, Object?>{
      'mode': kProfileMode ? 'profile' : 'debug',
      'platform': Platform.operatingSystem,
      'mediaRecords': 4000,
      'historyRecords': 100,
      'scope':
          'Full AIPlayerApp, disk SQLite, five sort modes, ten scroll movements '
          'and 15 tab switches during independent progress writes with at most '
          'one request in flight. Linux Xvfb software rendering; no artwork, '
          'video decoding, real network synchronization, Android device, '
          'before-change comparison, battery measurement or user-device FPS.',
    };
    Future<void> measure(
      String name,
      Future<void> Function() operation, {
      bool settle = true,
    }) async {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      frames.clear();
      final intervals = <double>[];
      final watch = Stopwatch()..start();
      var lastBeat = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 8), (_) {
        final now = watch.elapsedMicroseconds;
        intervals.add((now - lastBeat) / 1000);
        lastBeat = now;
      });
      final readsBefore = model.reads, commitsBefore = writer.commits;
      WidgetsBinding.instance.addTimingsCallback(collect);
      try {
        await operation();
        if (settle) await tester.pumpAndSettle();
      } finally {
        heartbeat.cancel();
        watch.stop();
        await writer.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      final build = frames
          .map((f) => f.buildDuration.inMicroseconds / 1000)
          .toList();
      final raster = frames
          .map((f) => f.rasterDuration.inMicroseconds / 1000)
          .toList();
      phases[name] = {
        'elapsedMs': watch.elapsedMilliseconds,
        'libraryReads': model.reads - readsBefore,
        'backgroundCommits': writer.commits - commitsBefore,
        ...await _summarize(build, raster, intervals),
      };
    }

    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await _wait(() => find.text('4000').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await measure('sortScrollAndNavigation', () async {
        writer.start();
        for (final entry in const {
          'name': '名称',
          'size': '文件大小',
          'recent': '最近播放',
          'modified': '修改时间',
          'updated': '更新时间',
        }.entries) {
          await tester.tap(find.byKey(const ValueKey('library-sort')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(CheckedPopupMenuItem<String>, entry.value),
          );
          debugPrint('Selected ${entry.key}; waiting for sorted snapshot');
          await _wait(
            () => model.completedSort == entry.key,
            diagnostics: () =>
                'expected=${entry.key} settings=${model.librarySorting.field} '
                'completed=${model.completedSort} reads=${model.reads} '
                'commits=${writer.commits}',
          );
          await tester.pumpAndSettle();
          expect(model.librarySorting.field, entry.key);
          final library = find.byKey(const PageStorageKey('library-scroll'));
          final position = tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: library,
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is Scrollable &&
                            widget.axisDirection == AxisDirection.down,
                      ),
                    )
                    .first,
              )
              .position;
          await position.animateTo(
            position.maxScrollExtent.clamp(0, 1600),
            duration: const Duration(milliseconds: 700),
            curve: Curves.linear,
          );
          await position.animateTo(
            0,
            duration: const Duration(milliseconds: 700),
            curve: Curves.linear,
          );
          for (final page in [1, 2, 0]) {
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
          }
          expect(model.librarySorting.field, entry.key);
        }
      });
      expect(writer.commits, greaterThan(10));
      expect(model.completedSort, 'updated');
      expect(
        model.preparationIsolates,
        isNot(contains(Isolate.current.hashCode)),
      );
      final idleReads = model.reads;
      await measure(
        'settledIdle',
        () async => Future<void>.delayed(const Duration(seconds: 3)),
        settle: false,
      );
      expect(model.reads, idleReads);
      expect(tester.takeException(), isNull);
      report['phases'] = phases;
      report['snapshotLoads'] = {
        'started': model.reads,
        'completed': model.completedReads,
        'cancelled': model.cancelledReads,
        'preparedOutsideMainIsolate': !model.preparationIsolates.contains(
          Isolate.current.hashCode,
        ),
      };
      binding.reportData = report;
      await _writeReport(report);
      debugPrint(jsonEncode(report));
    } finally {
      WidgetsBinding.instance.removeTimingsCallback(collect);
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
  String? completedSort;
  int completedReads = 0, cancelledReads = 0;
  final preparationIsolates = <int>{};
  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    reads++;
    try {
      final value = await super.loadLibrarySnapshot(
        query: query,
        cancel: cancel,
      );
      completedSort = value.sort.field;
      completedReads++;
      preparationIsolates.add(value.preparationIsolate);
      return value;
    } on Cancelled {
      cancelledReads++;
      rethrow;
    }
  }
}

Future<void> _wait(
  bool Function() ready, {
  String Function()? diagnostics,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for app: ${diagnostics?.call() ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _seed(String path) => Isolate.run(() {
  final store = AppStore('$path/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var i = 0; i < 4000; i++) {
        store.save('media', '$i', {
          'title': '视频 $i.mp4',
          'series': '未分类',
          'size': i + 1,
          'modified':
              '2026-10-23T00:${(i % 60).toString().padLeft(2, '0')}:00Z',
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
    'LIBRARY_SORT_ARTIFACT_DIR',
    defaultValue: '../artifacts/library-sort-20261024',
  );
  Directory(path).createSync(recursive: true);
  File(
    '$path/library-sort-profile.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
});

// Keep the isolate closure outside the app fixture's lexical context. Only
// numeric timing samples may cross, never the model or writer's ReceivePort.
Future<Map<String, Object>> _summarize(
  List<double> build,
  List<double> raster,
  List<double> intervals,
) => Isolate.run(
  () => {
    'buildMs': _distribution(build),
    'rasterMs': _distribution(raster),
    'mainIsolateHeartbeatMs': _distribution(intervals),
  },
);

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
      final sequence = request as int;
      final index = sequence % 100;
      final record = store.get('progress', '$index:${index + 1}')!;
      store.save('progress', record.id, {
        ...record.data,
        'position': 120 + sequence,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      events.send('committed');
    }
  } finally {
    store.dispose();
    requests.close();
    events.send('closed');
  }
}
