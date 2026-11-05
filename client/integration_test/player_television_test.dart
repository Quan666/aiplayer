import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Desktop native decoder regression with television input enabled. This does
// not measure Android remote hardware, TV performance, or battery consumption.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('TV player navigates, pauses, seeks and backs out in layers', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('player-television-');
    final store = await AppStore.open('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': false,
      'autoNextEpisode': false,
      'autoLoadExternalSubtitles': false,
      'refreshInterval': 0,
      'seekStepSeconds': 5,
      // Remote focus must keep controls visible beyond the normal timeout.
      'controlsHideSeconds': 1,
    });
    final id = await model.importFile(
      const String.fromEnvironment(
        'MEDIA_FIXTURE',
        defaultValue: '/tmp/aiplayer-lifecycle-fixture.mp4',
      ),
    );
    await preparePlaybackFonts(root);
    final navigator = GlobalKey<NavigatorState>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              TelevisionInputScope(overrideTelevision: true, child: child!),
          home: const Scaffold(body: Text('媒体库')),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (context) =>
                PlayerPage(model: model, media: store.get('media', id)!),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      final dynamic page = tester.state(find.byType(PlayerPage));
      final session = page.session as PlaybackSession;
      final native = session.player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await _until(() => session.ready || session.error.isNotEmpty, 'open');
      expect(session.error, isEmpty);
      await _until(
        () => session.player.state.duration.inSeconds >= 25,
        'duration',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );

      final play = _button(tester, '播放');
      final style = play.style!.side!.resolve({WidgetState.focused});
      expect(style?.width, 2);
      final playRect = tester.getRect(_buttonFinder('播放'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _until(
        () async => await native.getProperty('pause') == 'no',
        'remote play',
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getRect(_buttonFinder('暂停')), playRect);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );
      expect(_buttonFinder('暂停'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _until(
        () async => await native.getProperty('pause') == 'yes',
        'remote pause',
      );
      final paused = await _position(native);
      await tester.pump(const Duration(milliseconds: 300));
      expect(await _position(native), closeTo(paused, .08));

      // No new frame is produced in paused state. Late OK cannot restart the
      // native decoder through the still-focused button's default shortcut.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(await native.getProperty('pause'), 'yes');
      expect(await _position(native), closeTo(paused, .08));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 150));
      expect(await native.getProperty('pause'), 'yes');

      // The original transport layout supplies right/left navigation.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('television-play-pause'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _until(
        () async => await _position(native) > paused + 4,
        'remote seek',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );

      // Back hides chrome; OK reveals controls without accidentally toggling.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player-surface');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );
      expect(await native.getProperty('pause'), 'yes');

      // Lock remains reachable and Back unlocks before hiding/exiting.
      _button(tester, '锁定控件').focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_buttonFinder('解除锁定'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-player-lock',
      );
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 250));
      expect(_buttonFinder('锁定控件'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );

      // Single Menu also reveals the original controls from the video surface.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'television-play-pause',
      );

      // Timeline arrows use five seconds rather than 5% of a long movie.
      final timeline = tester.widget<Slider>(
        find.byKey(const ValueKey('player-timeline')),
      );
      timeline.focusNode!.requestFocus();
      await tester.pump();
      final beforeSeek = await _position(native);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _until(
        () async => await _position(native) > beforeSeek + 4,
        'timeline seek',
      );
      expect(await _position(native), closeTo(beforeSeek + 5, .25));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 60));
      expect(timeline.focusNode!.hasFocus, isFalse);

      // A hidden control cannot retain remote focus or activate invisibly.
      await tester.sendKeyEvent(
        LogicalKeyboardKey.escape,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player-surface');
      await tester.sendKeyEvent(
        LogicalKeyboardKey.escape,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await _until(() => session.closed, 'close');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.text('媒体库'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Finder _buttonFinder(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

IconButton _button(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(_buttonFinder(tooltip));

Future<double> _position(NativePlayer player) async =>
    double.parse(await player.getProperty('time-pos'));

Future<void> _until(FutureOr<bool> Function() ready, String phase) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
