import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/album_video_controller.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_video_player.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Native Linux/Xvfb functionality, not mobile performance or power measurement.
// ALBUM_VIDEO_FIXTURES contains 30-second playback.mp4 (360x640). An optional
// ALBUM_TEST_ROTATION=true variant starts with rotated.mp4 (640x360 with a
// 90-degree display matrix) in a fresh native process. Both are local H264.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixtures = String.fromEnvironment('ALBUM_VIDEO_FIXTURES');
  const verifyRotation = bool.fromEnvironment('ALBUM_TEST_ROTATION');
  const artifactDirectory = String.fromEnvironment('ALBUM_VIDEO_ARTIFACT_DIR');

  testWidgets('album native playback, portrait geometry and background pause', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    expect(fixtures, isNotEmpty, reason: 'Provide ALBUM_VIDEO_FIXTURES');
    final root = await Directory.systemTemp.createTemp(
      'album-native-playback-',
    );
    final store = AppStore('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final controller = AlbumVideoController(model: model, sourceId: 'local');
    final observations = <Map<String, Object?>>[];
    final startups = <Map<String, Object?>>[];
    final viewport = ValueNotifier(const Size(360, 640));
    Future<SourceEntry> entry(String name, {String? directory}) async {
      final path = '${directory ?? fixtures}/$name.mp4';
      final stat = await File(path).stat();
      expect(stat.size, greaterThan(0), reason: path);
      return SourceEntry(
        name: '$name.mp4',
        path: path,
        size: stat.size,
        modified: stat.modified.millisecondsSinceEpoch,
      );
    }

    try {
      await model.updatePreferences({
        'autoPlay': true,
        'enterFullscreen': true,
        'pauseOnBackground': true,
        'hardwareDecoding': false,
        'keepScreenOn': false,
        'metadataStrategy': 'off',
        'danmuVisible': false,
        'autoLoadExternalSubtitles': false,
      });
      controller.select(await entry(verifyRotation ? 'rotated' : 'playback'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: ValueListenableBuilder<Size>(
                valueListenable: viewport,
                builder: (_, size, _) => SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AlbumVideoSurface(
                        controller: controller,
                        cover: const ColoredBox(
                          key: ValueKey('album-native-cover'),
                          color: Colors.blue,
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: AlbumVideoControls(controller: controller),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(controller.session, isNull);
      expect(find.byKey(const ValueKey('album-native-cover')), findsOneWidget);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        controller.session,
        isNull,
        reason: 'Browsing must never autoplay',
      );

      final firstStartup = Stopwatch()..start();
      await controller.toggle();
      final firstOpenReturnedMs = firstStartup.elapsedMilliseconds;
      await _until(() async => controller.firstFrameRendered);
      startups.add({
        'case': 'explicit-play',
        'openReturnedMs': firstOpenReturnedMs,
        'firstFrameObservedMs': firstStartup.elapsedMilliseconds,
        'stagesMs': controller.session!.startupTimings,
      });
      await _until(() async => controller.position.value.inMilliseconds > 300);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(controller.error, isEmpty);
      expect(controller.playing, isTrue);
      final first = controller.session!;
      final native = first.player.platform as NativePlayer;
      expect(
        tester.widget<Video>(find.byType(Video)).aspectRatio,
        closeTo(360 / 640, .01),
      );
      expect(find.byKey(const ValueKey('album-native-cover')), findsNothing);
      observations.add(await _observe(native, 'explicit-play', paused: false));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      observations.add(
        await _observe(native, 'inactive-keeps-playing', paused: false),
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No pump after paused. Native state and timeline must stop even when
      // Flutter no longer delivers frames to this mounted surface.
      expect(binding.framesEnabled, isFalse);
      await _until(() async => await native.getProperty('pause') == 'yes');
      await _until(() async => !first.player.state.playing);
      observations.add(
        await _observe(native, 'paused-without-pump', paused: true),
      );
      final displayedPosition = controller.position.value;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      observations.add(
        await _observe(native, 'foreground-stays-paused', paused: true),
      );
      expect(
        controller.position.value.inMilliseconds,
        greaterThanOrEqualTo(displayedPosition.inMilliseconds),
      );
      await controller.toggle();
      await _until(() async => first.player.state.playing);
      observations.add(
        await _observe(native, 'explicit-resume', paused: false),
      );

      // Keep the same native decoder and transform-safe layout across viewport
      // shapes. The album does not invoke a separate fullscreen player route.
      viewport.value = const Size(640, 360);
      await tester.pump();
      expect(controller.session, same(first));
      expect(
        tester.widget<Video>(find.byType(Video)).aspectRatio,
        closeTo(360 / 640, .01),
      );
      expect(tester.takeException(), isNull);

      await File('$fixtures/playback.mp4').copy('${root.path}/replacement.mp4');
      controller.select(await entry('replacement', directory: root.path));
      expect(first.closed, isTrue);
      expect(controller.session, isNull);
      await AlbumVideoController.waitForDisposals();
      await tester.pump();
      expect(find.byKey(const ValueKey('album-native-cover')), findsOneWidget);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        controller.session,
        isNull,
        reason: 'Switching videos must stay paused',
      );
      final secondStartup = Stopwatch()..start();
      await controller.toggle();
      final secondOpenReturnedMs = secondStartup.elapsedMilliseconds;
      await _until(() async => controller.firstFrameRendered);
      startups.add({
        'case': 'replacement-video-explicit-play',
        'openReturnedMs': secondOpenReturnedMs,
        'firstFrameObservedMs': secondStartup.elapsedMilliseconds,
        'stagesMs': controller.session!.startupTimings,
      });
      await tester.pump();
      final second = controller.session!;
      expect(second, isNot(same(first)));
      expect(
        tester.widget<Video>(find.byType(Video)).aspectRatio,
        closeTo(360 / 640, .01),
      );
      observations.add(
        await _observe(
          second.player.platform as NativePlayer,
          'replacement-video-explicit-play',
          paused: false,
        ),
      );
      final transferPosition = second.player.state.position;
      final transferred = await controller.takeSession();
      expect(transferred, same(second));
      expect(second.closed, isFalse);
      expect(controller.session, isNull);
      await model.updatePreferences({'enterFullscreen': false});
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            model: model,
            media: second.media,
            initialSession: transferred,
            initialPlay: true,
          ),
        ),
      );
      await _until(() async => second.player.state.playing);
      expect(
        second.player.state.position,
        greaterThanOrEqualTo(transferPosition),
      );
      expect(
        tester.widget<Video>(find.byType(Video)).controller,
        same(second.video),
        reason: 'The full player must reuse the existing decoder',
      );
      observations.add(
        await _observe(
          second.player.platform as NativePlayer,
          'full-player-same-decoder-and-position',
          paused: false,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      controller.select(null);
      expect(second.closed, isTrue);
      expect(controller.session, isNull);
      await AlbumVideoController.waitForDisposals();
      expect(tester.takeException(), isNull);

      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'rotationMetadata': verifyRotation,
        'scope': 'Real AlbumVideoController/AlbumVideoSurface/libmpv; portrait geometry, two decoders opened serially, transfer to full PlayerPage retaining decoder and position; injected lifecycle with no pump after paused',
        'limitation': 'Linux/Xvfb software rendering; no Android/iOS hardware, frame-performance, battery, or power measurement',
        'observations': observations,
        'startupDiagnostics': startups,
      };
      binding.reportData = report;
      debugPrint('ALBUM_NATIVE_PLAYBACK ${jsonEncode(report)}');
      if (artifactDirectory.isNotEmpty) {
        await Directory(artifactDirectory).create(recursive: true);
        await File('$artifactDirectory/album-video-playback.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      await PlayerPage.waitForDisposals();
      controller.dispose();
      viewport.dispose();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _until(Future<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Native album video timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<Map<String, Object?>> _observe(
  NativePlayer native,
  String label, {
  required bool paused,
}) async {
  expect(
    await native.getProperty('pause'),
    paused ? 'yes' : 'no',
    reason: label,
  );
  final before = double.parse(await native.getProperty('time-pos'));
  await Future<void>.delayed(const Duration(milliseconds: 650));
  final after = double.parse(await native.getProperty('time-pos'));
  expect(
    await native.getProperty('pause'),
    paused ? 'yes' : 'no',
    reason: label,
  );
  expect(
    after - before,
    paused ? closeTo(0, .08) : greaterThan(.3),
    reason: label,
  );
  return {
    'case': label,
    'nativePause': paused,
    'positionDeltaMs': ((after - before) * 1000).round(),
    'observationMs': 650,
  };
}
