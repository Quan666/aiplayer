import 'dart:io';

import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native codec recovery requires an active video decoder', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    const fixture = String.fromEnvironment('MEDIA_FIXTURE');
    expect(await File(fixture).exists(), isTrue);
    final root = await Directory.systemTemp.createTemp('codec-recovery-');
    final store = AppStore(':memory:');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'autoPlay': true,
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
    });
    final id = await model.importFile(fixture);
    final session = PlaybackSession(model, store.get('media', id)!);
    final native = session.player.platform as NativePlayer;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await session.close();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    });
    Future<void> pumpUntil(bool Function() condition) async {
      for (var i = 0; i < 100 && !condition(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(condition(), isTrue);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Video(controller: session.video, controls: null)),
      ),
    );
    await native.setProperty('ao', 'null');
    await session.open(play: true, resume: false);
    await pumpUntil(() => session.firstFrameRendered);
    final before = AppLog.instance.entries.toSet();
    // The pinned backend exposes errors through a stream. Simulate its
    // recoverable open-attempt message while real native video is advancing.
    // ignore: invalid_use_of_protected_member
    native.errorController.add('Could not open codec.');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.error, isEmpty);
    final logs = AppLog.instance.entries.where(
      (entry) => !before.contains(entry),
    );
    expect(
      logs.any(
        (entry) =>
            entry.level == '警告' &&
            entry.message.contains('Could not open codec.'),
      ),
      isTrue,
    );
    expect(
      logs.any(
        (entry) =>
            entry.level == '错误' &&
            entry.message.contains('Could not open codec.'),
      ),
      isFalse,
    );
    expect(
      logs.any(
        (entry) => entry.scope == '播放诊断' && entry.message.contains('软件解码'),
      ),
      isTrue,
    );

    await native.setProperty('vid', 'no');
    await tester.pump(const Duration(milliseconds: 200));
    expect(await native.getProperty('video-dec-params'), isEmpty);
    final audioPosition = session.player.state.position;
    // ignore: invalid_use_of_protected_member
    native.errorController.add('Could not open codec.');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.player.state.position, greaterThan(audioPosition));
    expect(session.error, isNotEmpty);
    await native.setProperty('vid', 'auto');
    await pumpUntil(() => session.error.isEmpty);
    expect(await native.getProperty('video-dec-params'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
