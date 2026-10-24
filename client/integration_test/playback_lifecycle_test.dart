import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Linux/Xvfb exercises the actual decoder with injected lifecycle events. The
// session-only case explicitly applies mobile policy; it is not a device test.
// Supply a local video of at least 30 seconds through --dart-define=MEDIA_FIXTURE.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixture = String.fromEnvironment(
    'MEDIA_FIXTURE',
    defaultValue: '/tmp/aiplayer-lifecycle-fixture.mp4',
  );
  final observations = <Map<String, Object?>>[];

  testWidgets('desktop PlayerPage keeps playing while unfocused or hidden', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final data = await _Fixture.open(fixture);
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(model: data.model, media: data.media),
        ),
      );
      final dynamic page = tester.state(find.byType(PlayerPage));
      final session = page.session as PlaybackSession;
      final native = session.player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await _ready(session);
      expect(data.model.preferences.pauseOnBackground, isTrue);
      await session.setPlaying(true);
      await _until(() async => session.player.state.playing);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        // Deliberately no pump after backgrounding: native commands and
        // progress must remain independent from Flutter's frame scheduler.
        expect(session.backgroundPlaybackBlocked, isFalse);
        observations.add(
          await _observe(native, 'desktop-${state.name}', false),
        );
      }
      expect(binding.framesEnabled, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      observations.add(await _observe(native, 'desktop-resumed', false));

      await session.setPlaying(false);
      await _until(() async => await native.getProperty('pause') == 'yes');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      observations.add(await _observe(native, 'desktop-manually-paused', true));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      observations.add(
        await _observe(native, 'desktop-paused-remains-paused', true),
      );
      expect(session.error, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await data.close();
    }
  });

  testWidgets('mobile policy pauses and restores the native playback intent', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final data = await _Fixture.open(fixture);
    final session = PlaybackSession(data.model, data.media);
    final native = session.player.platform as NativePlayer;
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Video(
              controller: session.video,
              controls: null,
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
            ),
          ),
        ),
      );
      await native.setProperty('ao', 'null');
      await session.open();
      await _ready(session);
      await session.setPlaying(true);
      await _until(() async => session.player.state.playing);

      void background() {
        session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }

      void foreground() {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        session.setBackgroundPlaybackBlocked(false);
      }

      background();
      expect(binding.framesEnabled, isFalse);
      await _until(() async => await native.getProperty('pause') == 'yes');
      observations.add(
        await _observe(native, 'mobile-policy-background', true),
      );
      foreground();
      await _until(() async => await native.getProperty('pause') == 'no');
      observations.add(await _observe(native, 'mobile-policy-restored', false));

      // Exercise overlapping real native pause/play calls, then finish hidden.
      background();
      foreground();
      background();
      foreground();
      background();
      await _until(() async => await native.getProperty('pause') == 'yes');
      observations.add(
        await _observe(native, 'rapid-cycles-final-hidden', true),
      );
      foreground();
      await _until(() async => await native.getProperty('pause') == 'no');
      observations.add(await _observe(native, 'rapid-cycles-restored', false));

      // A pause click immediately before hidden must win even if the native
      // playing stream has not acknowledged that click yet.
      final pausing = session.setPlaying(false);
      background();
      await pausing;
      await _until(() async => await native.getProperty('pause') == 'yes');
      foreground();
      observations.add(
        await _observe(native, 'pending-user-pause-retained', true),
      );

      background();
      observations.add(
        await _observe(native, 'originally-paused-hidden', true),
      );
      foreground();
      observations.add(
        await _observe(native, 'originally-paused-restored', true),
      );
      expect(session.error, isEmpty);
      expect(tester.takeException(), isNull);

      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'scope': 'Real PlayerPage/libmpv; injected lifecycle and mobile policy',
        'limitation':
            'No Android/iOS hardware, native PiP, or power measurement',
        'observations': observations,
      };
      binding.reportData = report;
      debugPrint('PLAYBACK_LIFECYCLE ${jsonEncode(report)}');
      const artifact = String.fromEnvironment('LIFECYCLE_ARTIFACT_DIR');
      if (artifact.isNotEmpty) {
        await Directory(artifact).create(recursive: true);
        await File(
          '$artifact/playback-lifecycle.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await session.close();
      await data.close();
    }
  });
}

Future<void> _ready(PlaybackSession session) async {
  await _until(() async => session.ready || session.error.isNotEmpty);
  expect(session.error, isEmpty);
  expect(session.ready, isTrue);
  await session.video.waitUntilFirstFrameRendered.timeout(
    const Duration(seconds: 20),
  );
  await _until(() async => session.player.state.duration > Duration.zero);
  expect(session.player.state.duration.inSeconds, greaterThanOrEqualTo(30));
}

Future<Map<String, Object?>> _observe(
  NativePlayer native,
  String name,
  bool paused,
) async {
  final expected = paused ? 'yes' : 'no';
  expect(await native.getProperty('pause'), expected, reason: name);
  final before = double.parse(await native.getProperty('time-pos'));
  await Future<void>.delayed(const Duration(milliseconds: 850));
  final after = double.parse(await native.getProperty('time-pos'));
  expect(await native.getProperty('pause'), expected, reason: name);
  expect(
    after - before,
    paused ? closeTo(0, .08) : greaterThan(.35),
    reason: '$name must ${paused ? 'stop' : 'advance'} the actual decoder',
  );
  return {
    'case': name,
    'nativePause': expected,
    'positionDeltaMs': ((after - before) * 1000).round(),
    'observationMs': 850,
  };
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Native playback timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Fixture {
  final Directory root;
  final AppModel model;
  final SyncRecord media;
  _Fixture(this.root, this.model, this.media);

  static Future<_Fixture> open(String path) async {
    expect(await File(path).exists(), isTrue, reason: 'Missing MEDIA_FIXTURE');
    final root = await Directory.systemTemp.createTemp('playback-lifecycle-');
    final store = AppStore('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    try {
      await model.updatePreferences({
        'autoPlay': false,
        'enterFullscreen': false,
        'pauseOnBackground': true,
        'hardwareDecoding': false,
        'metadataStrategy': 'off',
        'danmuVisible': false,
        'autoLoadExternalSubtitles': false,
      });
      final media = store.get('media', await model.importFile(path))!;
      return _Fixture(root, model, media);
    } catch (_) {
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    await model.flushPlaybackPreviews();
    model.dispose();
    model.store.dispose();
    await root.delete(recursive: true);
  }
}
