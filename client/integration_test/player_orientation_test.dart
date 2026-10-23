import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Supply short, silent H.264 MP4 fixtures as base64 through
// --dart-define-from-file. The test writes them only into its own temp folder.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native fullscreen retains orientation and page across episodes', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    const landscape = String.fromEnvironment('LANDSCAPE_FIXTURE');
    const portrait = String.fromEnvironment('PORTRAIT_FIXTURE');
    expect(landscape, isNotEmpty, reason: 'Supply LANDSCAPE_FIXTURE as base64');
    expect(portrait, isNotEmpty, reason: 'Supply PORTRAIT_FIXTURE as base64');
    final root = await Directory.systemTemp.createTemp('orientation-test-');
    final store = AppStore('${root.path}/test.db');
    final model = AppModel(store, root);
    final navigator = GlobalKey<NavigatorState>();
    final dimensions = _Dimensions();
    WidgetsBinding.instance.addObserver(dimensions);
    try {
      await model.updatePreferences({
        'autoPlay': false,
        'enterFullscreen': true,
        'metadataStrategy': 'off',
        'autoRotateFullscreen': false,
        'hardwareDecoding': false,
        'controlsHideSeconds': 0,
      });
      Future<SyncRecord> import(String name, String bytes) async {
        final file = File('${root.path}/$name.mp4');
        await file.writeAsBytes(base64Decode(bytes));
        return store.get('media', await model.importFile(file.path))!;
      }

      final first = await import('Window S01E01', landscape);
      final second = await import('Window S01E02', landscape);
      final vertical = await import('Portrait', portrait);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Center(child: Text('Library'))),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      navigator.currentState!.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, animation, secondaryAnimation) =>
              PlayerPage(model: model, media: first),
        ),
      );
      await tester.pump();
      final dynamic page = tester.state(find.byType(PlayerPage));
      PlaybackSession session() => page.session as PlaybackSession;
      Future<void> ready(String id, {required bool horizontal}) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          final size = tester.view.physicalSize;
          if (session().media.id == id &&
              session().ready &&
              session().player.state.videoParams.w != null &&
              (size.width > size.height) == horizontal) {
            return;
          }
        }
        fail(
          'Video $id did not become ready with horizontal=$horizontal: '
          '${session().error}, ${tester.view.physicalSize}',
        );
      }

      await ready(first.id, horizontal: true);
      final videoState = tester.state(find.byType(Video));
      dimensions.sizes.clear();
      expect(find.byTooltip('退出全屏'), findsNothing);
      expect(find.byTooltip('切换全屏'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump(const Duration(milliseconds: 300));
      expect(identical(tester.state(find.byType(Video)), videoState), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await ready(first.id, horizontal: true);
      expect(identical(tester.state(find.byType(Video)), videoState), true);
      expect(
        dimensions.sizes.every((size) => size.width > size.height),
        true,
        reason: 'Toggling system bars must retain the video orientation',
      );

      dimensions.sizes.clear();
      await tester.tap(find.byTooltip('下一集'));
      await ready(second.id, horizontal: true);
      expect(identical(tester.state(find.byType(PlayerPage)), page), true);
      expect(
        dimensions.sizes.every((size) => size.width > size.height),
        true,
        reason: 'Switching landscape episodes must never request portrait',
      );
      await tester.tap(find.byTooltip('上一集'));
      await ready(first.id, horizontal: true);
      expect(dimensions.sizes.every((size) => size.width > size.height), true);

      // A genuinely vertical video is the only episode transition that rotates.
      page.selectMedia(vertical);
      await ready(vertical.id, horizontal: false);
      expect(identical(tester.state(find.byType(PlayerPage)), page), true);
      await tester.tap(find.byTooltip('返回'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.text('Library'), findsOneWidget);
      await tester.runAsync(PlayerPage.waitForDisposals);
      expect(tester.takeException(), isNull);
    } finally {
      WidgetsBinding.instance.removeObserver(dimensions);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(PlayerPage.waitForDisposals);
      await SystemChrome.setPreferredOrientations([]);
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  });
}

class _Dimensions extends WidgetsBindingObserver {
  final sizes = <Size>[];
  @override
  void didChangeMetrics() {
    sizes.add(
      WidgetsBinding.instance.platformDispatcher.views.first.physicalSize,
    );
  }
}
