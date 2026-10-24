import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Native decoder/navigation coverage. The test text-input service verifies
// focus and keyboard requests; Android/iOS IME behavior still needs a device.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'returning from native continue playback retains an unfocused search',
    (tester) async {
      MediaKit.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = File(const String.fromEnvironment('MEDIA_FIXTURE'));
      expect(await fixture.exists(), isTrue, reason: 'Supply MEDIA_FIXTURE');
      final directory = await Directory.systemTemp.createTemp(
        'continue-native-playback-',
      );
      final store = AppStore('${directory.path}/test.db');
      final model = AppModel(store, directory, enableThumbnails: false);
      binding.testTextInput.register();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      try {
        await model.updatePreferences({
          'autoPlay': true,
          'enterFullscreen': false,
          'hardwareDecoding': false,
          'metadataStrategy': 'off',
          'controlsHideSeconds': 0,
        });
        final id = await model.importFile(fixture.path);
        final media = store.get('media', id)!;
        store.save('progress', model.progressKey(media), {
          'position': 1,
          'duration': 10,
          'updatedAt': '2026-10-24T00:00:00.000Z',
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme().copyWith(
              platform: TargetPlatform.android,
            ),
            home: LibraryPage(model: model),
          ),
        );
        final card = find.byKey(ValueKey('history:$id'));
        for (var i = 0; i < 100 && card.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(card, findsOneWidget);
        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        final search = find.byType(TextField).first;
        await tester.enterText(search, 'Continue');
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        final field = tester.widget<TextField>(search);
        expect(card, findsOneWidget);

        for (final dismissKeyboard in [false, true]) {
          await tester.tap(search);
          await tester.pumpAndSettle();
          expect(field.focusNode!.hasFocus, isTrue);
          if (dismissKeyboard) tester.testTextInput.hide();
          await tester.tap(card);
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 30));
            if (find.byType(PlayerPage).evaluate().isNotEmpty) break;
          }
          expect(find.byType(PlayerPage), findsOneWidget);
          final dynamic page = tester.state(find.byType(PlayerPage));
          final session = page.session as PlaybackSession;
          final player = session.player;
          if (player.platform is NativePlayer) {
            await (player.platform as NativePlayer).setProperty('ao', 'null');
          }
          for (var i = 0; i < 250; i++) {
            await tester.pump(const Duration(milliseconds: 30));
            if (session.ready &&
                player.state.playing &&
                player.state.videoParams.w != null &&
                player.state.position > const Duration(seconds: 1)) {
              break;
            }
          }
          expect(session.error, isEmpty);
          expect(session.ready, isTrue);
          expect(player.state.playing, isTrue);
          expect(player.state.videoParams.w, isNotNull);
          expect(
            player.state.position,
            greaterThan(const Duration(seconds: 1)),
          );
          expect(field.focusNode!.hasFocus, isFalse);
          expect(tester.testTextInput.isVisible, isFalse);
          await tester.tap(find.byTooltip('返回').first);
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 30));
            if (find.byType(PlayerPage).evaluate().isEmpty) break;
          }
          expect(find.byType(PlayerPage), findsNothing);
          await PlayerPage.waitForDisposals();
          await tester.pumpAndSettle();
          expect(field.controller!.text, 'Continue');
          expect(field.focusNode!.hasFocus, isFalse);
          expect(tester.testTextInput.isVisible, isFalse);
          expect(card, findsOneWidget);
        }
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await PlayerPage.waitForDisposals();
        model.dispose();
        store.dispose();
        await directory.delete(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        binding.testTextInput.unregister();
      }
    },
  );
}
