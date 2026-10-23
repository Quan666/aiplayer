import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:integration_test/integration_test.dart';

// Run with flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/navigation_performance_test.dart
// --dart-define=NAVIGATION_ARTIFACT_DIR=/absolute/artifact/path
// Uses the full app and a real disk database. Software desktop rendering is
// diagnostic evidence and cannot establish frame rates on users' devices.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('measure full-app tab navigation with a large disk library', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('navigation-profile-');
    final store = AppStore('${root.path}/library.db');
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    // Fixture generation is outside the measured application workload.
    store.transaction(() {
      for (var i = 0; i < 3000; i++) {
        store.save('media', '$i', {
          'title': '视频 $i.mp4',
          'series': '未分类',
          'size': i + 1,
        });
        store.setLocal('location:$i', {
          'id': '$i',
          'source': 'local',
          'path': '/fixture/video-$i.mp4',
          'size': i + 1,
        });
        if (i < 10) {
          store.save('progress', '$i:${i + 1}', {
            'position': 10,
            'duration': 120,
            'updatedAt': '2026-10-23T00:00:${i.toString().padLeft(2, '0')}Z',
          });
        }
      }
    });
    final model = AppModel(store, root, backgroundWork: false);
    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    final phases = <Map<String, Object?>>[];
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      // Real isolate replies are not driven by fake test time.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (find.text('3000').evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('Library did not load');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      for (final phase in ['first-visits', 'repeated-visits']) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        frames.clear();
        WidgetsBinding.instance.addTimingsCallback(collect);
        final rounds = phase == 'first-visits' ? 1 : 4;
        try {
          for (var round = 0; round < rounds; round++) {
            for (final page in [1, 2, 0]) {
              store.save('progress', '0:1', {
                'position': 20 + round * 3 + page,
                'duration': 120,
                'updatedAt': DateTime.now().toUtc().toIso8601String(),
              });
              model.changed();
              await tester.tap(find.byKey(ValueKey('nav-item-$page')));
              await tester.pumpAndSettle();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 1100));
        } finally {
          WidgetsBinding.instance.removeTimingsCallback(collect);
        }
        expect(frames, isNotEmpty);
        phases.add({
          'phase': phase,
          'switches': rounds * 3,
          'frames': frames.length,
          'buildMs': _distribution(frames.map((frame) => frame.buildDuration)),
          'rasterMs': _distribution(
            frames.map((frame) => frame.rasterDuration),
          ),
        });
      }
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'videos': 3000,
        'scope':
            'full app; disk database; progress updates during tab switches; '
            'offline fixture without artwork or video playback; software desktop rendering',
        'phases': phases,
      };
      final artifacts = Directory(
        const String.fromEnvironment(
          'NAVIGATION_ARTIFACT_DIR',
          defaultValue: '../artifacts',
        ),
      );
      await artifacts.create(recursive: true);
      await File(
        '${artifacts.path}/navigation-performance.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      binding.reportData = report;
      debugPrint(jsonEncode(report));
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Map<String, Object> _distribution(Iterable<Duration> values) {
  final sorted = values.map((value) => value.inMicroseconds / 1000).toList()
    ..sort();
  return {
    'p50': sorted[(sorted.length * .5).ceil() - 1],
    'p95': sorted[(sorted.length * .95).ceil() - 1],
    'max': sorted.last,
    'over16_67ms': sorted.where((value) => value > 1000 / 60).length,
  };
}
