import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Run with flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/folder_library_performance_test.dart
// --dart-define=FOLDER_LIBRARY_ARTIFACT_DIR=/absolute/artifact/path
// Real application and disk workers; the source is deliberately offline.
// Software rendering measurements do not establish users' device frame rates.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile cached series completion and repeated page navigation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp(
      'folder-library-profile-',
    );
    final store = AppStore('${root.path}/library.db');
    final model = _ProfileModel(store, root);
    const unrelatedVideos = 3000, seriesEpisodes = 800;
    final directory = '${root.path}/Profile Series';
    final entries = [
      for (var episode = 1; episode <= seriesEpisodes; episode++)
        SourceEntry(
          name: 'Profile Series S01E${episode.toString().padLeft(3, '0')}.mkv',
          path: '$directory/$episode.mkv',
          size: episode + 100,
        ),
    ];
    // Fixture creation, including persistent recognized-directory metadata,
    // is outside the measurement. Only one series episode has been imported.
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      store.save('media', '000-series', {
        'title': entries.first.name,
        'series': 'Profile Series',
        'season': '1',
        'episode': '1',
        'size': entries.first.size,
        ...subjectMediaFields(_ProfileCatalog.subject),
      });
      store.setLocal('location:000-series', {
        'id': '000-series',
        'source': 'local',
        'path': entries.first.path,
        'size': entries.first.size,
      });
      for (var index = 0; index < unrelatedVideos; index++) {
        store.save('media', 'fixture-$index', {
          'title': '视频 $index.mp4',
          'series': '未分类',
          'size': index + 1,
        });
      }
    });
    await model.catalog.inspect('local', directory, entries);
    expect(
      model.catalog.directoryPreview('local', directory)?.collection,
      isNotNull,
    );

    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    final phases = <Map<String, Object?>>[];
    Future<void> waitFor(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for UI');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        await tester.pump();
      }
    }

    Future<void> measure(String name, Future<void> Function() operation) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      frames.clear();
      WidgetsBinding.instance.addTimingsCallback(collect);
      try {
        await operation();
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      expect(frames, isNotEmpty);
      phases.add({
        'phase': name,
        'frames': frames.length,
        'buildMs': _distribution(frames.map((frame) => frame.buildDuration)),
        'rasterMs': _distribution(frames.map((frame) => frame.rasterDuration)),
      });
    }

    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await waitFor(
        () => find
            .byKey(const ValueKey('details:000-series'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pumpAndSettle();
      await measure('cached-series-details-import', () async {
        await tester.tap(find.byKey(const ValueKey('details:000-series')));
        await waitFor(
          () => find.textContaining('已收录 800 集').evaluate().isNotEmpty,
        );
      });
      expect(model.importDurations, isNotEmpty);
      expect(model.workerHeartbeatIntervals, isNotEmpty);
      expect(find.textContaining('第 1 集'), findsWidgets);
      expect(find.textContaining('Episode title 1'), findsWidgets);
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.media.length, unrelatedVideos + seriesEpisodes);
      expect(
        snapshot.series['bangumi:7001:1']?.every(
          (record) => '${record.data['episodeTitle'] ?? ''}'.isNotEmpty,
        ),
        true,
      );
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      await measure('repeated-page-navigation', () async {
        for (var round = 0; round < 4; round++) {
          for (final page in [1, 2, 0]) {
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
          }
        }
      });
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'unrelatedVideos': unrelatedVideos,
        'cachedSeriesEpisodes': seriesEpisodes,
        'newlyImportedEpisodes': seriesEpisodes - 1,
        'navigationSwitches': 12,
        'scope':
            'full app; disk SQLite; cached directory imported by background '
            'worker when opening library details; deliberately offline source; '
            'no artwork downloads or video playback; software desktop rendering',
        'workerImportMs': _distribution(model.importDurations),
        'mainIsolateHeartbeatDuringImport': {
          'requestedPeriodMs': 4,
          'callbacks': model.workerHeartbeatIntervals.length,
          'intervalMs': _distribution(model.workerHeartbeatIntervals),
        },
        'phases': phases,
      };
      final artifacts = Directory(
        const String.fromEnvironment(
          'FOLDER_LIBRARY_ARTIFACT_DIR',
          defaultValue: '../artifacts',
        ),
      );
      await artifacts.create(recursive: true);
      await File(
        '${artifacts.path}/folder-library-performance.json',
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

class _ProfileModel extends AppModel {
  _ProfileModel(super.store, super.documents) : super(backgroundWork: false);
  late final _fixtureCatalog = _ProfileCatalog(store);
  @override
  LibraryCatalog get catalog => _fixtureCatalog;
  final importDurations = <Duration>[];
  final workerHeartbeatIntervals = <Duration>[];

  @override
  Future<SourceAdapter> adapter(String id) async =>
      throw const AppFailure('Fixture source is offline');

  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final watch = Stopwatch()..start();
    var previous = Duration.zero;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = watch.elapsed;
      workerHeartbeatIntervals.add(now - previous);
      previous = now;
    });
    try {
      return await super.synchronizeCollectionInBackground(
        sourceId,
        value,
        importMissing: importMissing,
        anchorId: anchorId,
        cancel: cancel,
      );
    } finally {
      heartbeat.cancel();
      importDurations.add(watch.elapsed);
    }
  }
}

class _ProfileCatalog extends LibraryCatalog {
  _ProfileCatalog(super.store) : super(strategy: () => 'conservative');
  static const subject = {
    'id': 7001,
    'name': 'Profile Series',
    'name_cn': 'Profile Series',
    'summary': 'Offline cached series used for integration profiling.',
    'total_episodes': 800,
  };
  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async => subject;
  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async => {
    for (var episode = 1; episode <= 800; episode++)
      '$episode': 'Episode title $episode',
  };
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
