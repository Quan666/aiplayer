import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/media_controls.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Linux/mpv functional check of the shared command and lifecycle path.
// This does not emulate a Bluetooth accessory or validate native OS routing.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('system commands pause real playback with no background frames', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    const channel = MethodChannel('app.aiplayer/media_controls');
    const codec = StandardMethodCodec();
    final messenger = binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final directory = await Directory.systemTemp.createTemp(
      'native-media-controls-',
    );
    final store = await AppStore.open('${directory.path}/library.db');
    final model = AppModel(store, directory, backgroundWork: false);
    final controls = PlayerMediaControls(
      nativeSupported: true,
      keyboardEnabled: false,
    );
    Future<void> command(String action) async {
      final update =
          calls.lastWhere((call) => call.method == 'update').arguments as Map;
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall('command', {
            'sessionId': update['sessionId'],
            'pauseRevision': update['pauseRevision'],
            'action': action,
          }),
        ),
        (_) => done.complete(),
      );
      await done.future;
    }

    try {
      await model.updatePreferences({
        'enterFullscreen': false,
        'hardwareDecoding': false,
        'metadataStrategy': 'off',
        'autoPlay': false,
        'autoNextEpisode': false,
        'danmuVisible': false,
        'autoLoadExternalSubtitles': false,
        'pauseOnBackground': true,
      });
      final id = await model.importFile(
        const String.fromEnvironment(
          'MEDIA_FIXTURE',
          defaultValue: '/tmp/aiplayer-media-controls-fixture.mp4',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            model: model,
            media: store.get('media', id)!,
            mobilePlaybackLifecycle: true,
          ),
        ),
      );
      final dynamic page = tester.state(find.byType(PlayerPage));
      final session = page.session as PlaybackSession;
      final native = session.player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await _until(() => session.ready || session.error.isNotEmpty);
      expect(session.error, isEmpty);
      controls.bindSession(session);
      controls.configure(title: '本地媒体控制回归', seekStepSeconds: 5);
      await _until(() => calls.any((call) => call.method == 'update'));
      await command('play');
      await _until(
        () =>
            session.player.state.playing &&
            session.player.state.position.inMilliseconds > 300,
      );
      await command('pause');
      await _until(() => !session.player.state.playing);
      expect(await native.getProperty('pause'), 'yes');
      final position = session.player.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        (session.player.state.position - position).inMilliseconds.abs(),
        lessThan(100),
      );
      await command('seekForward');
      await _until(() => session.player.state.position.inSeconds >= 5);
      await command('play');
      await _until(() => session.player.state.playing);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No tester.pump after paused: Android may stop rendering altogether.
      await _until(() => !session.player.state.playing);
      await command('play');
      expect(await native.getProperty('pause'), 'yes');
      final backgroundPosition = session.player.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        (session.player.state.position - backgroundPosition).inMilliseconds
            .abs(),
        lessThan(100),
      );
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(session.player.state.playing, false);
      await command('play');
      await _until(() => session.player.state.playing);
      await command('pause');
      expect(await native.getProperty('pause'), 'yes');
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await controls.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await PlayerPage.waitForDisposals();
      model.dispose();
      store.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for native playback');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
