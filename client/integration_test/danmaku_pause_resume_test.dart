import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/overlay.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Native functional regression; no device FPS or battery measurement.
// xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test -d linux --no-pub
// integration_test/danmaku_pause_resume_test.dart
// --dart-define=MEDIA_FIXTURE=/absolute/path/to/local-video.mp4
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native resume keeps the first painted comment in place', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('danmaku-resume-');
    final store = await AppStore.open('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': false,
      'autoNextEpisode': false,
      'autoLoadExternalSubtitles': false,
      'danmuVisible': true,
      'refreshInterval': 0,
    });
    final id = await model.importFile(
      const String.fromEnvironment(
        'MEDIA_FIXTURE',
        defaultValue: '/tmp/aiplayer-lifecycle-fixture.mp4',
      ),
    );
    await preparePlaybackFonts(root);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(model: model, media: store.get('media', id)!),
        ),
      );
      final dynamic page = tester.state(find.byType(PlayerPage));
      final session = page.session as PlaybackSession;
      final native = session.player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await _until(() => session.ready || session.error.isNotEmpty, 'open');
      expect(session.error, isEmpty);
      await session.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      session.danmaku = DanmakuSession(
        store,
        DanmuApiClient('https://offline.invalid', 'fixture'),
        id,
      )..comments = const [DanmakuComment(0, 'pause resume', 0xffffff, 0)];
      await session.setPlaying(true);
      await _until(
        () => session.position.value.inMilliseconds >= 2000,
        'moving comment',
      );
      final dynamic overlay = tester.state(find.byType(DanmakuOverlay));
      await (overlay.debugLayoutReady as Future<void>);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: find.byType(DanmakuOverlay),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      final observations = <Map<String, Object?>>[];
      for (final pauseMs in [300, 500]) {
        await session.setPlaying(false);
        await _until(() => !session.player.state.playing, 'pause event');
        expect(await native.getProperty('pause'), 'yes');
        // fullyLive would keep advancing the scheduler timestamp while the
        // player is paused and mask the idle gap. Only explicit pumps follow.
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
        await tester.pump();
        final before = await _leftEdge(boundary);
        final pausedAt = await _position(native);
        final pausedFrame = binding.currentSystemFrameTimeStamp;
        await Future<void>.delayed(Duration(milliseconds: pauseMs));
        expect(binding.currentSystemFrameTimeStamp, pausedFrame);
        expect(await native.getProperty('pause'), 'yes');
        final pauseDelta = await _position(native) - pausedAt;
        expect(pauseDelta, closeTo(0, .08));
        expect(await _leftEdge(boundary), before);

        await session.setPlaying(true);
        await _until(() => session.player.state.playing, 'resume event');
        expect(await native.getProperty('pause'), 'no');
        expect(binding.currentSystemFrameTimeStamp, pausedFrame);
        // This must be the first actual paint after the native resume event.
        await tester.pump();
        final after = await _leftEdge(boundary);
        expect(after, closeTo(before, 16), reason: 'resume after $pauseMs ms');
        observations.add({
          'pauseMs': pauseMs,
          'pausedNativePositionDeltaSeconds': pauseDelta,
          'firstResumedFrameDeltaPixels': after - before,
        });
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
        await _until(
          () async => await _position(native) > pausedAt + .25,
          'native position advances after resume',
        );
      }
      binding.reportData = {
        'environment': 'Linux native PlayerPage; controlled idle frame gaps',
        'observations': observations,
      };
      debugPrint('DANMAKU_RESUME $observations');
      expect(session.error, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<double> _position(NativePlayer player) async =>
    double.parse(await player.getProperty('time-pos'));

Future<void> _until(FutureOr<bool> Function() ready, String phase) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<int> _leftEdge(RenderRepaintBoundary boundary) async {
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final width = image.width;
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final left = await Isolate.run(() {
      var left = width;
      for (var offset = 3; offset < pixels.length; offset += 4) {
        if (pixels[offset] < 128) continue;
        final x = (offset ~/ 4) % width;
        if (x < left) left = x;
      }
      return left;
    });
    expect(
      left,
      inExclusiveRange(0, width),
      reason: 'comment is fully visible',
    );
    return left;
  } finally {
    image.dispose();
  }
}
