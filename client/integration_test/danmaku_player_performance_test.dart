import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/layout_worker.dart';
import 'package:aiplayer/danmaku/overlay.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// flutter drive --profile -d linux --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/danmaku_player_performance_test.dart
// --dart-define=MEDIA_FIXTURE=/absolute/path/to/local-video.mp4
// --dart-define=DANMAKU_ARTIFACT_DIR=/absolute/path/to/artifacts
// Set DANMAKU_ENVIRONMENT to describe the renderer/device. Linux Xvfb software
// rendering is a controlled host regression measurement, not device FPS.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile dense comments on the actual player page', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    const fixture = String.fromEnvironment(
      'MEDIA_FIXTURE',
      defaultValue: '/tmp/aiplayer-lifecycle-fixture.mp4',
    );
    const artifact = String.fromEnvironment('DANMAKU_ARTIFACT_DIR');
    const commentCount = 30000;
    final root = await Directory.systemTemp.createTemp('danmaku-profile-');
    final store = await AppStore.open('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': false,
      'autoLoadExternalSubtitles': false,
      'danmuVisible': true,
      'danmuArea': 1.0,
      'danmuDensity': 1.0,
      'refreshInterval': 0,
    });
    final id = await model.importFile(fixture);
    final record = store.get('media', id)!;
    await preparePlaybackFonts(root);
    // Fixture allocation and sorting are outside both UI work and timing spans.
    final snapshots = await Isolate.run(
      () => (
        _comments(commentCount, 0),
        _comments(commentCount, 1),
        _comments(commentCount, 2),
      ),
    );
    final samples = <Map<String, Object?>>[];
    final observations = <Map<String, Object?>>[];
    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    WidgetsBinding.instance.addTimingsCallback(collect);
    try {
      for (var round = 0; round < 3; round++) {
        final boundary = GlobalKey();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: boundary,
              child: PlayerPage(model: model, media: record),
            ),
          ),
        );
        final dynamic page = tester.state(find.byType(PlayerPage));
        final session = page.session as PlaybackSession;
        final native = session.player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await _until(() => session.ready || session.error.isNotEmpty);
        expect(session.error, isEmpty);
        await session.video.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
        await _until(() => session.player.state.duration.inSeconds >= 30);
        // A paused mpv seek need not publish a position event immediately.
        // Start the real clock before establishing the benchmark's seek point.
        await session.setPlaying(true);
        await session.player.seek(const Duration(seconds: 4));
        await _until(() => session.position.value.inMilliseconds >= 3500);
        final comments = DanmakuSession(
          store,
          DanmuApiClient('https://offline.invalid', 'fixture'),
          id,
        )..comments = snapshots.$1;
        session.danmaku = comments;
        _refresh(session, snapshots.$1);
        await session.setPlaying(true);
        await _until(() => session.player.state.playing);
        // Warm native decoding, text/shader caches, and control fade-out.
        await Future<void>.delayed(const Duration(seconds: 4));
        final steady = await _measure(
          'round-$round-steady',
          frames,
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
        samples.add(steady);
        samples.add(
          await _measure('round-$round-refresh', frames, () async {
            _refresh(session, snapshots.$2);
            await Future<void>.delayed(const Duration(milliseconds: 900));
            _refresh(session, snapshots.$3);
            await Future<void>.delayed(const Duration(milliseconds: 900));
            _refresh(session, snapshots.$1);
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }),
        );

        await session.setPlaying(false);
        await _until(() => !session.player.state.playing);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        final pausePosition = double.parse(
          await native.getProperty('time-pos'),
        );
        final paused = await _measure(
          'round-$round-paused',
          frames,
          () => Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        samples.add(paused);
        final pauseDelta =
            double.parse(await native.getProperty('time-pos')) - pausePosition;
        expect(pauseDelta, closeTo(0, .08));
        expect(await native.getProperty('pause'), 'yes');

        final dynamic overlay = tester.state(find.byType(DanmakuOverlay));
        final worker = overlay.debugLayoutWorker as DanmakuLayoutWorker;
        final completionsBeforePause = worker.completions;
        // Enqueue a full refresh, then background synchronously before its
        // worker can reply. Resume must retry that cancelled preparation.
        _refresh(session, snapshots.$2);
        expect(worker.pendingCount, greaterThan(0));
        // No pump after paused. Late snapshots must not restart the ticker.
        // fullyLive itself requests an engine frame after every draw, even
        // while framesEnabled is false. Disable those harness draws here to
        // reproduce Android's lack of subsequent frames; no test pump follows.
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(binding.framesEnabled, isFalse);
        final backgroundStarts = worker.starts;
        final backgroundTransfers = worker.sourceTransfers;
        expect(worker.pendingCount, 0);
        final backgroundStart = developer.Timeline.now;
        _refresh(session, snapshots.$2);
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        final hiddenFrames = frames
            .where(
              (frame) =>
                  frame.timestampInMicroseconds(ui.FramePhase.buildStart) >
                  backgroundStart,
            )
            .length;
        expect(hiddenFrames, 0);
        expect(binding.transientCallbackCount, 0);
        expect(worker.pendingCount, 0);
        expect(worker.starts, backgroundStarts);
        expect(worker.sourceTransfers, backgroundTransfers);
        final hiddenStarts = worker.starts - backgroundStarts;
        final hiddenTransfers = worker.sourceTransfers - backgroundTransfers;
        expect(await native.getProperty('pause'), 'yes');
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await (overlay.debugLayoutReady as Future<void>);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(await native.getProperty('pause'), 'yes');
        expect(worker.pendingCount, 0);
        expect(worker.completions, greaterThan(completionsBeforePause));
        observations.add({
          'round': round,
          'pausedPositionDeltaSeconds': pauseDelta,
          'backgroundFrames': hiddenFrames,
          'backgroundLateRefreshes': 1,
          'cancelledPendingRefreshResumed': true,
          'resumeKeptManualPause': true,
          'backgroundWorkerStarts': hiddenStarts,
          'backgroundSourceTransfers': hiddenTransfers,
        });

        if (round == 0) {
          await _checkLoading(tester, session, native, boundary, artifact);
        }
        await session.setPlaying(true);
        samples.add(
          await _measure(
            'round-$round-resumed',
            frames,
            () => Future<void>.delayed(const Duration(seconds: 2)),
          ),
        );
        expect(session.error, isEmpty);
        expect(worker.preparationIsolate, isNotNull);
        expect(worker.preparationIsolate, isNot(Isolate.current.hashCode));
        observations.last.addAll({
          'workerStarts': worker.starts,
          'workerCompletions': worker.completions,
          'sourceTransfers': worker.sourceTransfers,
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await PlayerPage.waitForDisposals();
        expect(session.closed, isTrue);
      }
      final view = tester.view;
      final report = <String, Object?>{
        'mode': kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        'platform': Platform.operatingSystem,
        'environment': const String.fromEnvironment(
          'DANMAKU_ENVIRONMENT',
          defaultValue: 'Actual PlayerPage; local H264; software video decode',
        ),
        'limitation':
            'Host measurement only; not Android hardware frame rates '
            'or battery use. Loading and snapshots are controlled test injections.',
        'frameHarness':
            'fullyLive drives measured foreground frames even when manually '
            'paused; onlyPumps suppresses harness drawing during background '
            'checks, with no pump after the lifecycle event.',
        'physicalSize':
            '${view.physicalSize.width}x${view.physicalSize.height}',
        'devicePixelRatio': view.devicePixelRatio,
        'comments': commentCount,
        'commentsPerSecond': 50,
        'reopens': 3,
        'phases': samples,
        'observations': observations,
        'loadingVerified': true,
      };
      binding.reportData = report;
      await _writeReport(report, artifact);
      debugPrint('DANMAKU_PLAYER ${jsonEncode(report)}');
    } finally {
      WidgetsBinding.instance.removeTimingsCallback(collect);
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _writeReport(Map<String, Object?> report, String artifact) =>
    Isolate.run(() async {
      final json = const JsonEncoder.withIndent('  ').convert(report);
      if (artifact.isNotEmpty) {
        await Directory(artifact).create(recursive: true);
        await File('$artifact/danmaku-player.json').writeAsString(json);
      }
    });

List<DanmakuComment> _comments(int count, int revision) => List.unmodifiable(
  List.generate(
    count,
    (index) => DanmakuComment(
      index / 50,
      '流畅弹幕 $index · 快速播放时也要清晰稳定 ${index % 7 == 0 ? '长一点的字幕内容' : ''} · $revision',
      const [0xffffff, 0xa7d7ff, 0xffe08a][index % 3],
      index % 19 == 0
          ? 1
          : index % 23 == 0
          ? 2
          : 0,
    ),
  ),
);

void _refresh(PlaybackSession session, List<DanmakuComment> comments) {
  session.danmaku!.comments = comments;
  // Mirrors the session notification after an offline API snapshot arrives.
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  session.notifyListeners();
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Player readiness timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Map<String, Object?>> _measure(
  String phase,
  List<ui.FrameTiming> frames,
  Future<void> Function() action,
) async {
  final start = developer.Timeline.now;
  final heartbeat = <double>[];
  var previous = start;
  final probe = Timer.periodic(const Duration(milliseconds: 8), (_) {
    final now = developer.Timeline.now;
    heartbeat.add((now - previous) / 1000);
    previous = now;
  });
  try {
    await action();
  } finally {
    probe.cancel();
  }
  final end = developer.Timeline.now;
  // Frame callbacks arrive in batches; timestamps exclude the delivery grace.
  await Future<void>.delayed(const Duration(milliseconds: 1100));
  final measured = frames.where((frame) {
    final timestamp = frame.timestampInMicroseconds(ui.FramePhase.buildStart);
    return timestamp >= start && timestamp <= end;
  }).toList();
  final builds = measured
      .map((f) => f.buildDuration.inMicroseconds / 1000)
      .toList();
  final rasters = measured
      .map((f) => f.rasterDuration.inMicroseconds / 1000)
      .toList();
  final timestamps = measured
      .map((f) => f.timestampInMicroseconds(ui.FramePhase.vsyncStart))
      .toList();
  final result = await Isolate.run(
    () => <String, Object?>{
      'phase': phase,
      'durationMs': (end - start) / 1000,
      'frames': builds.length,
      'buildMs': _distribution(builds),
      'rasterMs': _distribution(rasters),
      'mainIsolateHeartbeatMs': _distribution(heartbeat),
      'vsyncGapMs': _distribution([
        for (var i = 1; i < timestamps.length; i++)
          (timestamps[i] - timestamps[i - 1]) / 1000,
      ]),
      'buildOver16ms': builds.where((v) => v > 16.667).length,
      'rasterOver16ms': rasters.where((v) => v > 16.667).length,
    },
  );
  debugPrint('DANMAKU_PHASE ${jsonEncode(result)}');
  return result;
}

Map<String, num> _distribution(List<double> values) {
  values.sort();
  if (values.isEmpty) return {'p50': 0, 'p95': 0, 'max': 0};
  return {
    'p50': values[((values.length - 1) * .5).round()],
    'p95': values[((values.length - 1) * .95).round()],
    'max': values.last,
  };
}

Future<void> _checkLoading(
  WidgetTester tester,
  PlaybackSession session,
  NativePlayer native,
  GlobalKey key,
  String artifact,
) async {
  // The offline fixture never buffers naturally; use the native stream surface.
  native.state = native.state.copyWith(buffering: true);
  // ignore: invalid_use_of_protected_member
  native.bufferingController.add(true);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await tester.pump();
  final spinner = find.byKey(const ValueKey('player-buffering'));
  expect(spinner, findsOneWidget);
  expect(
    tester.getCenter(spinner).dx,
    closeTo(tester.getCenter(find.byType(PlayerPage)).dx, 1),
  );
  expect(
    tester.getCenter(spinner).dy,
    closeTo(tester.getCenter(find.byType(PlayerPage)).dy, 1),
  );
  expect(find.byType(LinearProgressIndicator), findsNothing);
  expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  expect(find.byIcon(Icons.pause_rounded), findsNothing);
  expect(tester.getSize(spinner), const Size.square(76));
  final ring = find.descendant(of: spinner, matching: find.byType(CustomPaint));
  expect(tester.getSize(ring), const Size.square(40));
  if (artifact.isNotEmpty) {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await _capture(boundary, '$artifact/player-loading.png', 1);
    final ringBoundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .descendant(of: spinner, matching: find.byType(RepaintBoundary))
          .first,
    );
    await _capture(ringBoundary, '$artifact/player-loading-ring.png', 3);
    expect(spinner, findsOneWidget);
  }
  native.state = native.state.copyWith(buffering: false);
  // ignore: invalid_use_of_protected_member
  native.bufferingController.add(false);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
  expect(spinner, findsNothing);
  expect(session.player.state.playing, isFalse);
}

Future<void> _capture(
  RenderRepaintBoundary boundary,
  String path,
  double scale,
) async {
  final image = await boundary.toImage(pixelRatio: scale);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}
