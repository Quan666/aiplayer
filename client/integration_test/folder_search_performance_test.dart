import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Actual local-folder screen with disk SQLite and 4,000 imported videos.
// Run the common artwork_performance_driver.dart with flutter drive --profile.
// Linux software rendering is not an Android frame-rate/battery measurement.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile local folder search, scroll and retained navigation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    binding.testTextInput.register();
    final root = await Directory.systemTemp.createTemp(
      'folder-search-profile-',
    );
    await _seed(root.path);
    final store = _CountingStore('${root.path}/library.db');
    final model = _Model(store, root);
    final frames = <ui.FrameTiming>[];
    final intervals = <double>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    Timer? heartbeat;
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await _wait(() => find.text('4000').evaluate().isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('nav-item-1')));
      await tester.pumpAndSettle();
      await _wait(() => find.text('4000 个视频').evaluate().isNotEmpty);
      await tester.tap(find.text('本地视频'));
      await tester.pumpAndSettle();
      await _wait(
        () => find.textContaining('Video 00000').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('folder-search-field'));
      final readsBefore = store.fullReads;
      final watch = Stopwatch()..start();
      var lastBeat = 0;
      heartbeat = Timer.periodic(const Duration(milliseconds: 8), (_) {
        final now = watch.elapsedMicroseconds;
        intervals.add((now - lastBeat) / 1000);
        lastBeat = now;
      });
      WidgetsBinding.instance.addTimingsCallback(collect);
      for (final query in ['01999', '00123', '03999', '00042']) {
        await tester.enterText(input, query);
        expect(tester.widget<TextField>(input).controller!.text, query);
        await _wait(
          () => find.textContaining('Video $query').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Video 00000'), findsNothing);
        // Tab retention must preserve the query and must not reopen its IME.
        await tester.tap(find.byKey(const ValueKey('nav-item-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-item-1')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, query);
        expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
      }
      await tester.enterText(input, 'Video');
      await _wait(
        () => find.textContaining('Video 00000').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final list = find.descendant(
        of: find.byType(SourcesPage),
        matching: find.byType(ListView),
      );
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      for (var i = 0; i < 3; i++) {
        await position.animateTo(
          1800,
          duration: const Duration(milliseconds: 600),
          curve: Curves.linear,
        );
        await position.animateTo(
          0,
          duration: const Duration(milliseconds: 600),
          curve: Curves.linear,
        );
      }
      expect(tester.widget<TextField>(input).controller!.text, 'Video');
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      // Cancel a just-entered query directly from lifecycle, without pumping a
      // Flutter frame while paused. Resume consumes only its latest text.
      await tester.enterText(input, '02500');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      final pausedReads = store.fullReads;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(store.fullReads, pausedReads);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await _wait(
        () => find.textContaining('Video 02500').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      heartbeat.cancel();
      heartbeat = null;
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      WidgetsBinding.instance.removeTimingsCallback(collect);
      expect(store.fullReads, readsBefore);
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'localVideos': 4000,
        'elapsedMs': watch.elapsedMilliseconds,
        'uiFullScansDuringSearchAndNavigation': store.fullReads - readsBefore,
        'scope':
            'Full AIPlayerApp local-folder page; disk SQLite; 6 searches, '
            '8 tab switches, 6 scroll animations and a no-pump pause/resume. '
            'Previews disabled; no native playback, actual file/network I/O, '
            'Android device, before-change comparison or battery measurement. '
            'Linux Xvfb software rendering is not user-device FPS.',
        ...await _summarize(
          frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
          frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList(),
          intervals,
        ),
      };
      binding.reportData = report;
      await _writeReport(report);
      debugPrint(jsonEncode(report));
    } finally {
      heartbeat?.cancel();
      WidgetsBinding.instance.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox());
      binding.testTextInput.unregister();
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  @override
  void ensureMediaPreview(String id) {}
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

Future<void> _seed(String root) => Isolate.run(() {
  final store = AppStore('$root/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var i = 0; i < 4000; i++) {
        final name = 'Video ${i.toString().padLeft(5, '0')}';
        store.save('media', '$i', {
          'title': name,
          'fileName': '$name.mp4',
          'series': '未分类',
          'size': i + 1,
        });
        store.setLocal('location:$i', {
          'id': '$i',
          'source': 'local',
          'path': '/fixture/$name.mp4',
          'size': i + 1,
        });
      }
    });
  } finally {
    store.dispose();
  }
});

Future<void> _wait(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for folder search');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Map<String, Object>> _summarize(
  List<double> build,
  List<double> raster,
  List<double> beats,
) => Isolate.run(
  () => {
    'buildMs': _distribution(build),
    'rasterMs': _distribution(raster),
    'mainIsolateHeartbeatMs': _distribution(beats),
  },
);
Map<String, Object> _distribution(List<double> values) {
  values.sort();
  if (values.isEmpty) return {'count': 0};
  return {
    'count': values.length,
    'p50': values[(values.length * .5).ceil() - 1],
    'p95': values[(values.length * .95).ceil() - 1],
    'max': values.last,
  };
}

Future<void> _writeReport(Map<String, Object?> report) => Isolate.run(() {
  const path = String.fromEnvironment(
    'FOLDER_SEARCH_ARTIFACT_DIR',
    defaultValue: '../artifacts/folder-search-20261024',
  );
  Directory(path).createSync(recursive: true);
  File(
    '$path/folder-search-profile.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
});
