import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_title_translation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Full-app search workload. Software desktop rendering is not mobile FPS.
// flutter drive --profile -d linux --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/library_search_performance_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile library search during progress writes and navigation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    // Integration binding leaves text input native by default. Register its
    // keyboard service so enterText reaches the real editable and onChanged.
    binding.testTextInput.register();
    final root = await Directory.systemTemp.createTemp(
      'library-search-profile-',
    );
    await _seed(root.path);
    final store = _CountingStore('${root.path}/library.db');
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
          'Full AIPlayerApp, disk SQLite, raw/cached/translated title searches, '
          'repeated queries and cancellation, scrolling and tab navigation '
          'during independent 120 ms progress writes (one request in flight), '
          'plus paused without pump and a merged resume refresh. Linux Xvfb '
          'software rendering; no artwork, video decode, network synchronization, '
          'Android device, battery measurement, before-change or user-device FPS.',
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
      store.fullReads = 0;
      await tester.tap(find.byTooltip('搜索作品或文件名'));
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '搜索作品或文件名',
      );
      expect(search, findsOneWidget);
      await measure('searchScrollAndNavigation', () async {
        writer.start();
        for (final query in const [
          'Video',
          'Cached episode ninety',
          '九十号影片',
          'Video 9',
          'Video',
          'Cached episode ninety',
          '九十号影片',
        ]) {
          final cancel = CancelToken();
          final cancelled = expectLater(
            model.loadLibrarySnapshot(
              query: 'unused query ${model.cancelledReads}',
              cancel: cancel,
            ),
            throwsA(isA<Cancelled>()),
          );
          cancel.cancel();
          await cancelled;
          await tester.enterText(search, query);
          await tester.pump();
          expect(tester.widget<TextField>(search).controller!.text, query);
          FocusManager.instance.primaryFocus?.unfocus();
          await _wait(
            () => model.completedQuery == query.toLowerCase(),
            diagnostics: () =>
                'query=$query completed=${model.completedQuery} '
                'reads=${model.reads} commits=${writer.commits} '
                'requested=${model.requestedQueries}',
          );
          expect(
            model.lastSnapshot!.searchRecent.any((record) => record.id == '90'),
            isTrue,
          );
          await tester.pumpAndSettle();
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
            position.maxScrollExtent.clamp(0, 1000),
            duration: const Duration(milliseconds: 500),
            curve: Curves.linear,
          );
          await position.animateTo(
            0,
            duration: const Duration(milliseconds: 500),
            curve: Curves.linear,
          );
          expect(
            search,
            findsOneWidget,
            reason: 'Search survives offscreen scrolling',
          );
          expect(tester.widget<TextField>(search).controller!.text, query);
          for (final page in [1, 2, 0]) {
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
          }
          expect(tester.widget<TextField>(search).controller!.text, query);
        }
      });
      expect(writer.commits, greaterThan(10));
      expect(model.cancelledReads, greaterThanOrEqualTo(7));
      expect(model.completedQuery, '九十号影片');
      expect(store.fullReads, 0);
      expect(
        model.preparationIsolates,
        isNot(contains(Isolate.current.hashCode)),
      );

      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final pausedReads = model.reads, pausedCommits = writer.commits;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Deliberately no pump or frame-dependent pause after this event.
      writer.start();
      await Future<void>.delayed(const Duration(seconds: 3));
      await writer.stop();
      phases['pausedWithoutPump'] = {
        'durationMs': 3000,
        'libraryReads': model.reads - pausedReads,
        'backgroundCommits': writer.commits - pausedCommits,
      };
      expect(model.reads, pausedReads);
      expect(writer.commits - pausedCommits, greaterThan(10));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _wait(() => model.reads > pausedReads);
      await tester.pumpAndSettle();
      phases['resumeReads'] = model.reads - pausedReads;
      expect(model.reads, pausedReads + 1);
      expect(model.lastSnapshot!.searchRecent.single.id, '90');
      expect(store.fullReads, 0);
      final idleReads = model.reads;
      await measure(
        'settledIdle',
        () async => Future<void>.delayed(const Duration(seconds: 3)),
        settle: false,
      );
      expect(model.reads, idleReads);
      expect(tester.takeException(), isNull);
      report['phases'] = phases;
      report['uiFullScans'] = store.fullReads;
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
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await writer.close();
      await tester.pumpWidget(const SizedBox());
      binding.testTextInput.unregister();
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _CountingStore extends AppStore {
  _CountingStore(super.path) : super.openExisting();
  int fullReads = 0;
  @override
  List<SyncRecord> all(String kind) {
    fullReads++;
    return super.all(kind);
  }

  @override
  List<SyncRecord> records(String kind) {
    fullReads++;
    return super.records(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    fullReads++;
    return super.localEntries(prefix);
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  int reads = 0;
  String? completedQuery;
  LibrarySnapshot? lastSnapshot;
  int completedReads = 0, cancelledReads = 0;
  final requestedQueries = <String, int>{};
  final preparationIsolates = <int>{};
  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    reads++;
    requestedQueries.update(query, (count) => count + 1, ifAbsent: () => 1);
    try {
      final value = await super.loadLibrarySnapshot(
        query: query,
        cancel: cancel,
      );
      completedQuery = value.query;
      lastSnapshot = value;
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
          'title': 'Video $i.mp4',
          'series': '未分类',
          'size': i + 1,
          'modified':
              '2026-10-23T00:${(i % 60).toString().padLeft(2, '0')}:00Z',
        });
      }
      store.setLocal('episodeTitle:90', 'Cached episode ninety');
      store.setLocal(
        MediaTitleTranslations.stateKeyFor(
          'file:90',
          MediaTitleTranslations.profileFor({}),
        ),
        {
          'visible': true,
          'titles': {'Video 90.mp4': '九十号影片'},
        },
      );
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
    'LIBRARY_SEARCH_ARTIFACT_DIR',
    defaultValue: '../artifacts/library-search-20261024',
  );
  Directory(path).createSync(recursive: true);
  File(
    '$path/library-search-profile.json',
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
