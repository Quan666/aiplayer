import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// From client/, serially with native builds and Flutter tests:
// dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24' env
// LIBGL_ALWAYS_SOFTWARE=1 flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/album_video_scroll_return_test.dart
// --dart-define=ALBUM_VIDEO_FIXTURES=/tmp/album-video-fixtures
// --dart-define=ALBUM_VIDEO_RETURN_ARTIFACT_DIR=/absolute/artifact/path
// scripts/generate_album_video_fixture.py prepares first.mp4. Actual AlbumPage,
// disk SQLite binding workers, native mpv first-frame capture and image decode.
// Linux software rendering and a tiny local fixture do not establish device FPS,
// NAS throughput, real-world decoder latency or power improvement.
const _videos = 1200;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixtures = String.fromEnvironment('ALBUM_VIDEO_FIXTURES');

  testWidgets('native album video covers survive recycled scroll cells', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    expect(fixtures, isNotEmpty, reason: 'Provide ALBUM_VIDEO_FIXTURES');
    final rootPath = await _seedInBackground('$fixtures/first.mp4');
    final root = Directory(rootPath);
    final store = AppStore.openExisting('$rootPath/library.db');
    final captures = _CaptureStats();
    final model = _Model(store, root, captures);
    final wall = find.byKey(const ValueKey('album-wall'));
    final returns = <Map<String, Object?>>[];
    final report = <String, Object?>{
      'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'platform': Platform.operatingSystem,
      'videos': _videos,
      'fixture': 'first.mp4 (360x640, H264, 2 seconds)',
      'scope':
          'Actual AlbumPage, native capture and disk-backed binding worker; '
          'local fixture and Linux software rendering, not phone/TV FPS or power.',
      'returns': returns,
    };
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: wall, matching: find.byType(Scrollable)).first,
        )
        .position;
    Future<void> ready(String phase) => _until(() {
      final visible = _visible(tester, wall);
      return visible.visible > 0 &&
          visible.missing == 0 &&
          model.pendingBindings == 0 &&
          captures.active == 0 &&
          ArtworkDecodeQueue.instance.activeCount == 0 &&
          ArtworkDecodeQueue.instance.pendingCount == 0;
    }, phase);
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: AlbumPage(
            model: model,
            source: const {
              'id': 'local',
              'kind': 'local',
              'label': 'Video return',
            },
            initialPath: '$rootPath/album',
            initialName: 'Video return',
          ),
        ),
      );
      await ready('initial native video covers');
      final firstVisible = _visible(tester, wall).visible;
      expect(captures.total, greaterThanOrEqualTo(firstVisible));
      final firstCaptureCount = captures.total;
      final viewport = position().viewportDimension;
      for (var round = 0; round < 3; round++) {
        model.delayBindings = false;
        position().jumpTo(viewport * 2.2);
        await WidgetsBinding.instance.endOfFrame;
        await ready('two pages away $round');
        model.delayBindings = true;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final timings = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> value) => timings.addAll(value);
        WidgetsBinding.instance.addTimingsCallback(collect);
        final before = captures.total;
        final readsBefore = model.bindingReads;
        final watch = Stopwatch()..start();
        try {
          position().jumpTo(0);
          await WidgetsBinding.instance.endOfFrame;
          final frame = _visible(tester, wall);
          final firstFrameMs = watch.elapsedMicroseconds / 1000;
          expect(frame.visible, firstVisible);
          expect(
            frame.missing,
            0,
            reason: 'The first recycled video cells need their warm paths before revalidation.',
          );
          expect(captures.total, before);
          // The shared scroll scope deliberately defers even binding reads
          // until scrolling settles. The first returning frame above must
          // already be warm before the delayed validation is admitted.
          await _until(
            () => model.pendingBindings > 0,
            'return binding validation admitted $round',
          );
          expect(_visible(tester, wall).missing, 0);
          await ready('returned video covers $round');
          watch.stop();
          expect(
            captures.total,
            before,
            reason:
                'Returning to prepared covers must not reopen native capture.',
          );
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          returns.add({
            'round': round,
            'firstFrameMs': firstFrameMs,
            'visible': frame.visible,
            'missing': frame.missing,
            'revalidatedMs': watch.elapsedMicroseconds / 1000,
            'captureCountBefore': before,
            'captureCountAfter': captures.total,
            'bindingReadsBefore': readsBefore,
            'bindingReadsAfter': model.bindingReads,
            'buildUs': [
              for (final frame in timings) frame.buildDuration.inMicroseconds,
            ],
            'rasterUs': [
              for (final frame in timings) frame.rasterDuration.inMicroseconds,
            ],
          });
        } finally {
          WidgetsBinding.instance.removeTimingsCallback(collect);
        }
      }

      // A cold page creates real queued/native capture work before pause.
      model.delayBindings = false;
      position().jumpTo(viewport * 4.2);
      await WidgetsBinding.instance.endOfFrame;
      await _until(() => captures.active > 0, 'cold native capture started');
      final cancellationsBefore = captures.cancelled;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(binding.framesEnabled, isFalse);
      final pausedCount = captures.total;
      // Do not pump after paused: Android may never provide a stopping frame.
      await _until(
        () => captures.active == 0,
        'native cancellation without frames',
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(captures.total, pausedCount);
      expect(captures.cancelled, greaterThan(cancellationsBefore));
      expect(ArtworkDecodeQueue.instance.pendingCount, 0);
      report['pausedWithoutPump'] = {
        'captureCountBefore': pausedCount,
        'captureCountAfter': captures.total,
        'activeAfter': captures.active,
        'cancellations': captures.cancelled - cancellationsBefore,
      };
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await WidgetsBinding.instance.endOfFrame;
      await ready('video covers resume after native cancellation');
      expect(captures.peakActive, 1);
      report['firstPageCaptures'] = firstCaptureCount;
      report['totalCaptures'] = captures.total;
      report['peakNativeCaptures'] = captures.peakActive;
      report['decodedCacheBytes'] =
          PaintingBinding.instance.imageCache.currentSizeBytes;
      report['runStatus'] = 'complete';
      binding.reportData = await compute(_writeReport, report);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.flushMetadataTasks();
      await _until(
        () => captures.active == 0 && AlbumPage.pendingDisposals == 0,
        'native and album worker disposal',
      );
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _CaptureStats {
  int total = 0, active = 0, peakActive = 0, cancelled = 0;
  Future<MediaPreview> capture(String uri, CancelToken token) async {
    total++;
    active++;
    if (active > peakActive) peakActive = active;
    try {
      return await captureMediaPreview(uri, token, firstFrame: true);
    } finally {
      if (token.cancelled) cancelled++;
      active--;
    }
  }
}

class _Model extends AppModel {
  int bindingReads = 0, pendingBindings = 0;
  bool delayBindings = false;
  _Model(super.store, super.documents, _CaptureStats captures)
    : super(
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: captures.capture,
      );

  @override
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    required CancelToken cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) async {
    bindingReads++;
    pendingBindings++;
    try {
      if (delayBindings) {
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 400)),
          cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
        ]);
      }
      cancel.check();
      return await super.readSourceMediaPreview(
        sourceId,
        entry,
        cancel: cancel,
        albumCover: albumCover,
        originalResolution: originalResolution,
      );
    } finally {
      pendingBindings--;
    }
  }
}

Future<void> _until(bool Function() condition, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 8));
  }
}

({int visible, int missing}) _visible(WidgetTester tester, Finder wall) {
  if (wall.evaluate().isEmpty) return (visible: 0, missing: 0);
  final bounds = tester
      .getRect(wall)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  var visible = 0, missing = 0;
  for (final element in find.byType(AlbumVideoThumbnail).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox ||
        !box.hasSize ||
        !(box.localToGlobal(Offset.zero) & box.size).overlaps(bounds)) {
      continue;
    }
    visible++;
    final pixels = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(RawImage),
    );
    if (!tester
        .widgetList<RawImage>(pixels)
        .any((image) => image.image != null)) {
      missing++;
    }
  }
  return (visible: visible, missing: missing);
}

Future<String> _seedInBackground(String fixture) => Isolate.run(() {
  final root = Directory.systemTemp.createTempSync('album-video-return-');
  final album = Directory('${root.path}/album')..createSync();
  final source = File(fixture);
  for (var i = 0; i < _videos; i++) {
    source.copySync('${album.path}/video-${i.toString().padLeft(4, '0')}.mp4');
  }
  final store = AppStore('${root.path}/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
      'autoIdentifyOnFolderOpen': false,
    });
  } finally {
    store.dispose();
  }
  return root.path;
});

Map<String, Object?> _writeReport(Map<String, Object?> report) {
  for (final round in report['returns'] as List) {
    for (final prefix in ['build', 'raster']) {
      final values = (round.remove('${prefix}Us') as List).cast<int>()..sort();
      round['${prefix}Ms'] = values.isEmpty
          ? {'count': 0}
          : {
              'count': values.length,
              'p50': values[(values.length * .5).ceil() - 1] / 1000,
              'p95': values[(values.length * .95).ceil() - 1] / 1000,
              'max': values.last / 1000,
            };
    }
  }
  const output = String.fromEnvironment(
    'ALBUM_VIDEO_RETURN_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  Directory(output).createSync(recursive: true);
  File('$output/album-video-scroll-return.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  return report;
}
