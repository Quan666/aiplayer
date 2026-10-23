import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/desktop_window.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/danmaku/overlay.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/core/external_open.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/ui/player_theme.dart';

void expectChoiceTextAlignment(WidgetTester tester, Finder title) {
  final tile = find.ancestor(
    of: title,
    matching: find.byType(PlayerChoiceTile),
  );
  final tileRect = tester.getRect(tile);
  final textBlock = find.descendant(of: tile, matching: find.byType(Column));
  expect(tester.getRect(title).left, closeTo(tileRect.left + 8, .1));
  expect(
    tester.getRect(textBlock).center.dy,
    closeTo(tileRect.center.dy, .1),
    reason: 'The title and subtitle form one vertically centered text block',
  );
  expect(
    tester
        .renderObject<RenderParagraph>(
          find.descendant(of: title, matching: find.byType(RichText)),
        )
        .textAlign,
    TextAlign.start,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment(
    'MEDIA_FIXTURE',
    defaultValue: '/tmp/aiplayer-media-fixture/Example S01E01.mkv',
  );
  testWidgets(
    'real MKV decode, libass, seeking, overlay and persistent progress',
    (tester) async {
      MediaKit.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'aiplayer-integration-',
      );
      final model = AppModel(AppStore('${root.path}/test.db'), root);
      final id = await model.importFile(fixture),
          record = model.store.get('media', id)!;
      await model.updatePreferences({
        'autoPlay': false,
        'enterFullscreen': false,
        'volume': 64.0,
        'playbackRate': 1.25,
        'subtitleScale': 1.3,
        'subtitleDelay': .5,
        'hardwareDecoding': false,
      });
      // Opening an end-of-file record must decode the beginning, not stall
      // on an unplayable last frame.
      model.store.save('progress', model.progressKey(record), {
        'position': 30.0,
        'duration': 30.0,
      });
      final playback = PlaybackSession(model, record);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await playback.close();
        await PlayerPage.waitForDisposals();
        model.dispose();
        model.store.dispose();
        await root.delete(recursive: true);
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Video(
                controller: playback.video,
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  visible: false,
                ),
                controls: (_) => DanmakuOverlay(session: playback),
              ),
            ),
          ),
        ),
      );
      final native = playback.player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await playback.open();
      expect(playback.ready, true, reason: playback.error);
      expect(playback.player.state.playing, false);
      await playback.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.player.state.position.inMilliseconds, lessThan(500));
      expect(playback.player.state.completed, false);
      expect(playback.error, isEmpty);
      expect(double.parse(await native.getProperty('volume')), closeTo(64, .1));
      expect(
        double.parse(await native.getProperty('speed')),
        closeTo(1.25, .01),
      );
      expect(
        double.parse(await native.getProperty('sub-scale')),
        closeTo(1.3, .01),
      );
      expect(
        double.parse(await native.getProperty('sub-delay')),
        closeTo(.5, .01),
      );
      expect(await native.getProperty('hwdec'), 'no');
      expect(await native.getProperty('cache-on-disk'), 'no');
      expect(await native.getProperty('cache-pause-initial'), 'no');
      expect(double.parse(await native.getProperty('cache-pause-wait')), .15);
      await playback.updateSettings({
        'subtitlesEnabled': false,
        'audioDelay': .2,
      });
      expect(await native.getProperty('sub-visibility'), 'no');
      expect(
        double.parse(await native.getProperty('audio-delay')),
        closeTo(.2, .01),
      );
      await playback.updateSettings({
        'autoPlay': true,
        'subtitlesEnabled': true,
        'audioDelay': 0.0,
        'subtitleDelay': 0.0,
        'subtitleScale': 1.0,
        'playbackRate': 1.0,
      });
      await playback.player.play();
      for (
        var i = 0;
        i < 100 && playback.player.state.position < const Duration(seconds: 1);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.ready, true, reason: playback.error);
      expect(
        playback.player.state.duration.inSeconds,
        greaterThanOrEqualTo(29),
      );
      expect(playback.player.state.position.inMilliseconds, greaterThan(500));
      for (
        var i = 0;
        i < 30 && model.store.local('technical:$id') == null;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final technical = MediaTechnicalInfo.forRecord(model.store, record);
      expect(
        technical.container,
        'Matroska',
        reason:
            'cached=${model.store.local('technical:$id')}; '
            'native=${await native.getProperty('file-format')}',
      );
      expect(technical.codec, isNotEmpty);
      expect(technical.width, playback.player.state.videoParams.w);
      expect(technical.height, playback.player.state.videoParams.h);
      expect(technical.duration, greaterThan(29));
      expect(technical.size, greaterThan(0));
      await playback.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      expect(
        playback.player.state.tracks.subtitle.any(
          (t) => t.id != 'no' && t.id != 'auto',
        ),
        true,
      );
      expect(await native.getProperty('sub-ass'), 'yes');
      // Progress updates redraw only the seek timeline; they must not notify
      // every session listener (which would rebuild the entire player page).
      var timelineUpdates = 0;
      var fullUpdates = 0;
      void timelineChanged() => timelineUpdates++;
      void sessionChanged() => fullUpdates++;
      playback.position.addListener(timelineChanged);
      playback.addListener(sessionChanged);
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      playback.position.removeListener(timelineChanged);
      playback.removeListener(sessionChanged);
      expect(timelineUpdates, greaterThan(1));
      expect(fullUpdates, lessThan(timelineUpdates));
      // Decoder fallback diagnostics must not permanently cover working video.
      // The pinned native backend has no public fault-injection API.
      // ignore: invalid_use_of_protected_member
      native.errorController.add('Could not open codec.');
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.error, isEmpty);
      // A failure without fresh frames/progress is still shown, then clears
      // when real playback resumes. Do not silently swallow fatal failures.
      await playback.player.pause();
      await tester.pump(const Duration(milliseconds: 200));
      // Inject the same native-stream failure without frame progress.
      // ignore: invalid_use_of_protected_member
      native.errorController.add('Controlled unrecovered decoder failure');
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.error, isNotEmpty);
      await playback.player.play();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.error, isEmpty);
      await playback.player.pause();
      await playback.player.seek(const Duration(seconds: 12));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.player.state.position.inSeconds, closeTo(12, 1));
      await playback.saveProgress();
      expect(
        model.store
            .get('progress', model.progressKey(record))!
            .data['position'],
        closeTo(12, 1),
      );
      // Fixtures never contact the online danmaku service.
      playback.danmaku =
          DanmakuSession(
              model.store,
              DanmuApiClient(DanmuApiClient.defaultOrigin, 'fixture'),
              id,
            )
            ..comments = [
              const DanmakuComment(11, '滚动弹幕 · 与播放器时钟同步', 0xffffff, 0),
              const DanmakuComment(11, '顶部弹幕', 0xffe08a, 1),
              const DanmakuComment(11, '底部弹幕', 0xa7b3ff, 2),
            ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Video(
                controller: playback.video,
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  visible: false,
                ),
                controls: (_) => DanmakuOverlay(session: playback),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final artifacts = Directory('${Directory.current.path}/../artifacts');
      await artifacts.create(recursive: true);
      await File(
        '${artifacts.path}/playback.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      await tester.pumpWidget(const SizedBox());
      await playback.close();
      final appBoundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: appBoundaryKey,
          child: AIPlayerApp(model: model),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('我的影视库'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('我的影视库'))).brightness,
        Brightness.light,
      );
      expect(find.text('继续观看'), findsOneWidget);
      final playCard = find.byKey(ValueKey('play:$id')).first;
      await tester.ensureVisible(playCard);
      await tester.tap(playCard);
      for (
        var i = 0;
        i < 20 && find.byType(PlayerPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      // This second player is owned by the real page, so it also needs a null
      // audio sink in headless CI. Configure it before waiting for playback;
      // the error assertion below must still catch any real player failure.
      final dynamic pageState = tester.state(find.byType(PlayerPage));
      final pagePlayback = pageState.session as PlaybackSession;
      final pageNative = pagePlayback.player.platform as NativePlayer;
      await pageNative.setProperty('ao', 'null');
      expect(await pageNative.getProperty('ao'), 'null');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(pagePlayback.error, isEmpty);
      expect(pagePlayback.ready, true);
      // Keep the initial toolbar assertion stable while the native host is
      // busy; auto-hide is exercised separately with playback running below.
      await pagePlayback.player.pause();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        Theme.of(tester.element(find.byType(Video))).brightness,
        Brightness.dark,
      );
      if (find.byTooltip('播放器设置').hitTestable().evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(Video)));
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(
        find.byType(BackdropFilter),
        findsNothing,
        reason: 'Revealing controls must not blur the live video texture',
      );
      expect(find.byTooltip('截图'), findsNothing);
      expect(find.byTooltip('弹幕').hitTestable(), findsOneWidget);
      expect(find.byTooltip('加入同步播放'), findsNothing);
      expect(find.byTooltip('退出同步播放'), findsNothing);
      expect(
        tester.widget<Video>(find.byType(Video)).controls,
        isNull,
        reason:
            'Controls render independently from native video layout updates',
      );
      final params = pagePlayback.player.state.videoParams;
      expect(
        tester.widget<Video>(find.byType(Video)).aspectRatio,
        closeTo((params.dw ?? params.w!) / (params.dh ?? params.h!), .001),
      );
      debugPrint('player regression: touch/hover controls');
      // Real gesture hit testing, playback rebuilds and hover must preserve a
      // reveal. A timer-only test missed the pointer-down/onTap race.
      await pagePlayback.player.seek(const Duration(seconds: 2));
      await pagePlayback.player.play();
      await model.updatePreferences({'controlsHideSeconds': 3});
      final videoRect = tester.getRect(find.byType(Video));
      final background = Offset(
        videoRect.left + videoRect.width * .22,
        videoRect.top + videoRect.height * .36,
      );
      for (var i = 0; i < 36; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('播放器设置'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final keyboardSettings = find.byKey(
        const ValueKey('player-settings-popup'),
      );
      void expectSettingsPosition(Finder menu) {
        expect(menu, findsOneWidget);
        final bounds = tester.getRect(menu);
        final media = MediaQuery.of(tester.element(find.byType(Video)));
        expect(bounds.width, lessThanOrEqualTo(300));
        expect(
          bounds.right,
          closeTo(media.size.width - media.padding.right - 16, 1),
        );
        expect(
          bounds.bottom,
          closeTo(media.size.height - media.padding.bottom - 90, 1),
        );
        expect(Theme.of(tester.element(menu)).brightness, Brightness.dark);
      }

      expectSettingsPosition(keyboardSettings);
      Navigator.of(tester.element(keyboardSettings)).pop();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 36; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('播放器设置'), findsNothing);
      final touch = await tester.startGesture(background);
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        find.byTooltip('播放器设置'),
        findsOneWidget,
        reason: 'Hidden controls reveal on pointer-down',
      );
      await touch.up();
      await model.updatePreferences({'volume': 63.0});
      // Live integration pumps use wall time. Fifteen software-rendered frames
      // on a busy CI host can exceed the three-second hide interval even when
      // their requested delays add up to only 1.5 seconds.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(
        find.byTooltip('播放器设置'),
        findsOneWidget,
        reason: 'The same tap and playback rebuild cannot hide revealed chrome',
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('播放器设置'), findsNothing);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(background);
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.down(background);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.byTooltip('播放器设置'),
        findsOneWidget,
        reason: 'Hover then click is one reveal, not immediate reverse toggle',
      );
      await mouse.removePointer();
      // Fit is a cycle, without a selection modal or losing the toolbar.
      final toolbar = find.byKey(const ValueKey('player-top-controls'));
      final originalToolbarElement = tester.element(toolbar);
      final entrance = find.descendant(
        of: toolbar,
        matching: find.byType(AnimatedOpacity),
      );
      final originalEntranceState = tester.state(entrance);
      final castRect = tester.getRect(find.byTooltip('投屏'));
      final volumeRect = tester.getRect(find.byTooltip('静音'));
      final settingsRect = tester.getRect(find.byTooltip('播放器设置'));
      final danmakuRect = tester.getRect(find.byTooltip('弹幕'));
      expect(find.byTooltip('退出全屏'), findsNothing);
      expect(find.byTooltip('切换全屏'), findsNothing);
      expect(castRect.center.dx, lessThan(volumeRect.center.dx));
      expect((castRect.center.dy - volumeRect.center.dy).abs(), lessThan(2));
      expect(
        (settingsRect.center.dy - danmakuRect.center.dy).abs(),
        lessThan(2),
      );
      await tester.tap(find.byTooltip('画面适配'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.videoFit, 'cover');
      expect(find.byKey(const ValueKey('player-hud')), findsOneWidget);
      expect(identical(tester.element(toolbar), originalToolbarElement), true);
      expect(
        identical(tester.state(entrance), originalEntranceState),
        true,
        reason: 'Feedback must not restart the controls entrance animation',
      );
      await tester.tap(find.byTooltip('画面适配'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.videoFit, 'fill');
      await tester.tap(find.byTooltip('画面适配'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.videoFit, 'contain');
      await tester.pump(const Duration(milliseconds: 950));
      // The expiry timer starts the outgoing HUD animation on this frame.
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('player-hud')), findsNothing);
      expect(identical(tester.state(entrance), originalEntranceState), true);
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pump(const Duration(milliseconds: 300));
      final popup = find.byKey(const ValueKey('player-playlist-popup'));
      expect(popup, findsOneWidget);
      expect(tester.getRect(popup).width, lessThan(300));
      final playlistTitle = find.descendant(
        of: popup,
        matching: find.text(model.episodeLabel(record)),
      );
      expect(playlistTitle, findsOneWidget);
      expectChoiceTextAlignment(tester, playlistTitle);
      expect(
        tester.getRect(playlistTitle).left,
        closeTo(tester.getRect(popup).left + 14, 1),
      );
      expect(
        tester
            .getSize(
              find.ancestor(
                of: playlistTitle,
                matching: find.byType(PlayerChoiceTile),
              ),
            )
            .height,
        PlayerTheme.choiceRowWithSubtitleHeight,
      );
      expect(
        tester.getRect(popup).bottom,
        lessThanOrEqualTo(tester.getRect(find.byTooltip('播放列表')).top),
      );
      expect(Theme.of(tester.element(popup)).brightness, Brightness.dark);
      Future<void> capturePlayer(String filename) async {
        final boundary =
            appBoundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(
          '${artifacts.path}/$filename',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      }

      await capturePlayer('player_playlist.png');
      await tester.tapAt(const Offset(8, 8));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      await pagePlayback.player.pause();
      await tester.pump(const Duration(milliseconds: 100));
      void expectChoicePopover(Finder menu, String tooltip) {
        expect(menu, findsOneWidget);
        final bounds = tester.getRect(menu);
        final anchor = tester.getRect(find.byTooltip(tooltip));
        expect(bounds.width, lessThanOrEqualTo(300));
        expect(bounds.bottom, closeTo(anchor.top - 8, 1));
        expect(bounds.right, closeTo(anchor.right, 1));
        expect(Theme.of(tester.element(menu)).brightness, Brightness.dark);
      }

      debugPrint('player regression: anchored speed and audio menus');
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pump(const Duration(milliseconds: 300));
      final settingsPopup = find.byKey(const ValueKey('player-settings-popup'));
      expectSettingsPosition(settingsPopup);
      await capturePlayer('player_quick_settings.png');
      Navigator.of(tester.element(settingsPopup)).pop();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('播放速度'));
      await tester.pump(const Duration(milliseconds: 350));
      final speedPopup = find.byKey(const ValueKey('player-speed-popup'));
      expectChoicePopover(speedPopup, '播放速度');
      await capturePlayer('player_speed.png');
      final faster = find.descendant(
        of: speedPopup,
        matching: find.text('1.5×'),
      );
      await tester.ensureVisible(faster);
      await tester.tap(faster);
      await tester.pump(const Duration(milliseconds: 300));
      expect(speedPopup, findsNothing);
      expect(model.preferences.playbackRate, 1.5);
      expect(
        double.parse(await pageNative.getProperty('speed')),
        closeTo(1.5, .01),
      );
      await tester.tap(find.byTooltip('播放速度'));
      await tester.pump(const Duration(milliseconds: 350));
      final selectedSpeed = find.widgetWithText(PlayerChoiceTile, '1.5×');
      await tester.ensureVisible(selectedSpeed);
      expect(tester.getSize(selectedSpeed).height, PlayerTheme.choiceRowHeight);
      expectChoiceTextAlignment(
        tester,
        find.descendant(of: selectedSpeed, matching: find.text('1.5×')),
      );
      expect(
        find.descendant(
          of: selectedSpeed,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      Navigator.of(tester.element(speedPopup)).pop();
      await tester.pump(const Duration(milliseconds: 300));
      await pagePlayback.updateSettings({'playbackRate': 1.0});

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('音轨'));
      await tester.pump(const Duration(milliseconds: 350));
      final audioPopup = find.byKey(const ValueKey('player-audio-popup'));
      expectChoicePopover(audioPopup, '播放器设置');
      await capturePlayer('player_audio.png');
      await tester.tap(
        find.descendant(of: audioPopup, matching: find.text('关闭音轨')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(audioPopup, findsNothing);
      expect(await pageNative.getProperty('aid'), 'no');
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('音轨'));
      await tester.pump(const Duration(milliseconds: 350));
      final selectedAudio = find.widgetWithText(PlayerChoiceTile, '关闭音轨');
      expect(
        tester.getSize(selectedAudio).height,
        PlayerTheme.choiceTrackRowHeight,
      );
      expectChoiceTextAlignment(
        tester,
        find.descendant(of: selectedAudio, matching: find.text('关闭音轨')),
      );
      expect(
        find.descendant(
          of: selectedAudio,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: audioPopup, matching: find.text('自动选择')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(audioPopup, findsNothing);
      expect(await pageNative.getProperty('aid'), isNot('no'));
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('投屏'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('手动地址'), findsOneWidget);
      await tester.tap(find.text('手动地址'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.widgetWithText(TextField, '设备描述地址'), findsOneWidget);
      await capturePlayer('player_cast.png');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('锁定控件'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('播放器设置'), findsNothing);
      expect(find.byTooltip('解除锁定'), findsOneWidget);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      // Capture the real player chrome with a stable frame, in addition to the
      // original video/subtitle/danmaku-only fixture above.
      if (find.byTooltip('暂停').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('暂停'));
      }
      await tester.pump(const Duration(milliseconds: 400));
      final appBoundary =
          appBoundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final playerImage = await appBoundary.toImage(pixelRatio: 1);
      final playerBytes = await playerImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      playerImage.dispose();
      await File(
        '${artifacts.path}/player_glass.png',
      ).writeAsBytes(playerBytes!.buffer.asUint8List());
      debugPrint('player regression: seek preview');
      final controlGroups = {
        for (final name in ['top', 'transport', 'bottom'])
          name: find.byKey(ValueKey('player-$name-controls')),
      };
      final controlElements = {
        for (final entry in controlGroups.entries)
          entry.key: tester.element(entry.value),
      };
      final controlWidgets = {
        for (final entry in controlGroups.entries)
          entry.key: tester.widget(entry.value),
      };
      final controlAnimations = {
        for (final entry in controlGroups.entries)
          entry.key: tester.state(
            find.descendant(
              of: entry.value,
              matching: find.byType(AnimatedOpacity),
            ),
          ),
      };
      final videoElement = tester.element(find.byType(Video));
      final videoState = tester.state(find.byType(Video));
      final texture = find.descendant(
        of: find.byType(Video),
        matching: find.byType(Texture),
      );
      final textureElement = tester.element(texture);
      final timelineFinder = find.byKey(const ValueKey('player-timeline'));
      final sliderState = tester.state(timelineFinder);
      final previewLayer = find.byKey(const ValueKey('player-seek-preview'));
      final previewElement = tester.element(previewLayer);
      void expectStablePlayer({bool unchangedControls = false}) {
        for (final entry in controlGroups.entries) {
          expect(
            identical(tester.element(entry.value), controlElements[entry.key]),
            true,
            reason:
                '${entry.key} controls must keep their Element while seeking',
          );
          expect(
            identical(
              tester.state(
                find.descendant(
                  of: entry.value,
                  matching: find.byType(AnimatedOpacity),
                ),
              ),
              controlAnimations[entry.key],
            ),
            true,
            reason:
                '${entry.key} entrance animation must never restart on seek',
          );
          if (unchangedControls) {
            expect(
              identical(tester.widget(entry.value), controlWidgets[entry.key]),
              true,
              reason:
                  'Scrubbing must only rebuild preview/timeline, not chrome',
            );
          }
          final opacity = tester.widget<FadeTransition>(
            find
                .descendant(
                  of: entry.value,
                  matching: find.byType(FadeTransition),
                )
                .first,
          );
          expect(
            opacity.opacity.value,
            1,
            reason: 'Controls must stay fully visible',
          );
        }
        expect(
          identical(tester.element(find.byType(Video)), videoElement),
          true,
        );
        expect(identical(tester.state(find.byType(Video)), videoState), true);
        expect(identical(tester.element(texture), textureElement), true);
        expect(identical(tester.state(timelineFinder), sliderState), true);
        expect(identical(tester.element(previewLayer), previewElement), true);
      }

      final beforePreview = pagePlayback.player.state.position;
      final timeline = tester.getRect(timelineFinder);
      final seekDrag = await tester.startGesture(timeline.center);
      await tester.pump(const Duration(milliseconds: 20));
      expectStablePlayer(unchangedControls: true);
      final timelineFocus = FocusManager.instance.primaryFocus;
      await seekDrag.moveTo(
        Offset(timeline.left + timeline.width * .65, timeline.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expectStablePlayer(unchangedControls: true);
      expect(FocusManager.instance.primaryFocus, same(timelineFocus));
      for (var i = 0; i < 140; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .descendant(
              of: find.byKey(const ValueKey('seek-preview-frame')),
              matching: find.byType(Image),
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('seek-preview-time')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('seek-preview-frame')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        (pagePlayback.player.state.position - beforePreview).inMilliseconds
            .abs(),
        lessThan(500),
        reason:
            'A preview must never seek the foreground decoder before release',
      );
      expect(
        find.byTooltip('播放器设置'),
        findsOneWidget,
        reason: 'Holding the seek thumb suspends hiding for the entire gesture',
      );
      expectStablePlayer(unchangedControls: true);
      // Deterministically exercise a delayed source, including the loading
      // overlay appearing during an active scrub. The backend does not expose
      // a cache-stall injector, so mirror its state/stream pair here.
      final videoBeforeBuffering = tester.widget<Video>(find.byType(Video));
      pageNative.state = pageNative.state.copyWith(buffering: true);
      // ignore: invalid_use_of_protected_member
      pageNative.bufferingController.add(true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('player-buffering')), findsOneWidget);
      final loading = tester.getRect(
        find.byKey(const ValueKey('player-buffering')),
      );
      final transport = tester.getRect(
        find.byTooltip(pagePlayback.player.state.playing ? '暂停' : '播放'),
      );
      expect(loading.overlaps(transport), isFalse);
      expect(loading.height, 3);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-buffering')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Video>(find.byType(Video)),
        same(videoBeforeBuffering),
        reason: 'Buffering must update controls without rebuilding Video',
      );
      expectStablePlayer();
      pageNative.state = pageNative.state.copyWith(buffering: false);
      // ignore: invalid_use_of_protected_member
      pageNative.bufferingController.add(false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('player-buffering')), findsNothing);
      expect(
        tester.widget<Video>(find.byType(Video)),
        same(videoBeforeBuffering),
      );
      expectStablePlayer();
      await tester.pump(const Duration(milliseconds: 300));
      final seekImage = await appBoundary.toImage(pixelRatio: 1);
      final seekBytes = await seekImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      seekImage.dispose();
      await File(
        '${artifacts.path}/player_seek_preview.png',
      ).writeAsBytes(seekBytes!.buffer.asUint8List());
      await seekDrag.up();
      await tester.pump();
      expectStablePlayer();
      await tester.pump(const Duration(milliseconds: 400));
      debugPrint('player regression: seek preview release');
      expect(find.byKey(const ValueKey('seek-preview-frame')), findsNothing);
      expectStablePlayer();
      // A click is also a seek; preview teardown must work without any drag
      // update and the same Slider/Video/control state survives both events.
      final timelineClick = await tester.startGesture(
        Offset(timeline.left + timeline.width * .35, timeline.center.dy),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-preview-time')), findsOneWidget);
      expectStablePlayer();
      final clickedTarget = tester.widget<Slider>(timelineFinder).value;
      await timelineClick.up();
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-preview-frame')), findsNothing);
      expectStablePlayer();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        pagePlayback.player.state.position.inMilliseconds,
        closeTo(clickedTarget, 500),
      );
      final beforeCancel = pagePlayback.player.state.position;
      final cancelledDrag = await tester.startGesture(timeline.center);
      await cancelledDrag.moveTo(
        Offset(timeline.left + timeline.width * .8, timeline.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('seek-preview-time')), findsOneWidget);
      await cancelledDrag.cancel();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('seek-preview-frame')), findsNothing);
      expect(pagePlayback.player.state.position, beforeCancel);
      expectStablePlayer();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      // Fullscreen now uses the same main window and preserves the decoder.
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expectStablePlayer();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.byType(Video), findsOneWidget);
      expect(pagePlayback.closed, false);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsNothing);
      if (DesktopWindow.supported) {
        expect(find.byTooltip('全屏'), findsOneWidget);
      }
      debugPrint(
        'player regression: fullscreen restored, opening nested settings',
      );
      await pagePlayback.player.play();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('高级选项'), findsOneWidget);
      // Keep the real menu open beyond the automatic hide interval. Nested
      // panel transitions must not leave an expired timer hiding the controls.
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('高级选项'), findsOneWidget);
      debugPrint('player regression: advanced settings');
      await tester.tap(find.text('高级选项'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('高级设置'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, '字幕'));
      await tester.pump(const Duration(milliseconds: 300));
      final subtitleSwitch = find.widgetWithText(SwitchListTile, '显示字幕');
      await tester.ensureVisible(subtitleSwitch);
      await tester.tap(subtitleSwitch);
      await tester.pump(const Duration(milliseconds: 250));
      expect(model.preferences.subtitlesEnabled, false);
      expect(await pageNative.getProperty('sub-visibility'), 'no');
      expect(pagePlayback.error, isEmpty);
      final settingsImage = await appBoundary.toImage(pixelRatio: 1);
      final settingsBytes = await settingsImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      settingsImage.dispose();
      await File(
        '${artifacts.path}/player_settings.png',
      ).writeAsBytes(settingsBytes!.buffer.asUint8List());
      await tester.tap(subtitleSwitch);
      await tester.pump(const Duration(milliseconds: 250));
      expect(await pageNative.getProperty('sub-visibility'), 'yes');
      Navigator.of(tester.element(subtitleSwitch)).pop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      await pagePlayback.player.pause();
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('player regression: keyboard actions');
      final keyboardTimelineFocus = tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: find.byKey(const ValueKey('player-timeline')),
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!;
      keyboardTimelineFocus.requestFocus();
      await tester.pump();
      expect(keyboardTimelineFocus.hasPrimaryFocus, isTrue);
      final volumeBeforeKey = model.preferences.volume;
      final positionBeforeKey = pagePlayback.player.state.position;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.volume, volumeBeforeKey - 5);
      expect(
        pagePlayback.player.state.position,
        positionBeforeKey,
        reason: 'Focused timeline must not consume volume arrows as seeking',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.volume, volumeBeforeKey);
      await pagePlayback.seek(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 250));
      expect(pagePlayback.player.state.position.inSeconds, closeTo(12, 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        pagePlayback.player.state.position.inSeconds,
        greaterThanOrEqualTo(29),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        pagePlayback.player.state.position.inSeconds,
        lessThanOrEqualTo(1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump(const Duration(milliseconds: 150));
      expect(pagePlayback.player.state.playing, isTrue);
      Focus.of(tester.element(find.byTooltip('播放器设置'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 150));
      expect(pagePlayback.player.state.playing, isFalse);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 150));
      expect(pagePlayback.player.state.playing, isFalse);
      expect(
        find.byKey(const ValueKey('player-settings-popup')),
        findsNothing,
        reason: 'Holding Space must not activate the focused settings button',
      );
      // Exercise the actual focused player, including replacing the default S
      // binding. The pure parser tests cannot verify focus and action dispatch.
      await model.updatePreferences({
        'shortcuts': {'subtitles': 'K', 'playPauseAlternate': 'None'},
      });
      await tester.pump(const Duration(milliseconds: 100));
      Focus.of(tester.element(find.byTooltip('播放器设置'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.preferences.subtitlesEnabled, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump(const Duration(milliseconds: 250));
      expect(model.preferences.subtitlesEnabled, false);
      expect(await pageNative.getProperty('sub-visibility'), 'no');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump(const Duration(milliseconds: 250));
      expect(model.preferences.subtitlesEnabled, true);
      expect(await pageNative.getProperty('sub-visibility'), 'yes');
      await model.updatePreferences({
        'shortcuts': {'subtitles': 'S', 'playPauseAlternate': 'K'},
      });
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('字幕'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择本地外挂字幕'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('选择本地外挂字幕'))).brightness,
        Brightness.dark,
      );
      Navigator.of(tester.element(find.text('选择本地外挂字幕'))).pop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      if (find.byTooltip('返回').evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(Video)));
        await tester.pump(const Duration(milliseconds: 350));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      if (DesktopWindow.supported) {
        await model.updatePreferences({'controlsHideSeconds': 3});
        await pagePlayback.seek(const Duration(seconds: 2));
        await pagePlayback.player.play();
        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byTooltip('播放器设置'), findsNothing);
        final fullscreenMouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        final center = tester.getCenter(find.byType(Video));
        await fullscreenMouse.addPointer(location: center);
        await fullscreenMouse.moveTo(center + const Offset(15, 10));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byTooltip('播放器设置').hitTestable(),
          findsOneWidget,
          reason: 'Mouse movement reveals fullscreen controls',
        );
        expect(find.byTooltip('退出全屏').hitTestable(), findsOneWidget);
        await fullscreenMouse.removePointer();
        await model.updatePreferences({'keyboardEnabled': false});
        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byTooltip('播放器设置'), findsNothing);
        await pagePlayback.player.pause();
      }
      debugPrint('player regression: seek immediately followed by system Back');
      // The seek command may return before decoding finishes. Closing must not
      // save the previous nonblank frame under this new resume position.
      await pagePlayback.player.seek(const Duration(seconds: 20));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsNothing);
      expect(
        find.byTooltip('播放器设置').hitTestable(),
        findsOneWidget,
        reason: 'Escape reveals controls after leaving fullscreen',
      );
      expect(
        identical(
          (tester.state(find.byType(PlayerPage)) as dynamic).session,
          pagePlayback,
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('我的影视库'), findsOneWidget);
      final savedFrame = model.store.local('preview:${record.id}') as Map;
      expect(savedFrame['requestedPosition'], closeTo(20, .2));
      expect(savedFrame['capturedPosition'], closeTo(20, .2));
      expect(await model.needsMediaPreview(record.id), false);
      await File(
        '${artifacts.path}/player-close-seek-051.jpg',
      ).writeAsBytes(await File(savedFrame['path'] as String).readAsBytes());
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('external opens replace playback inside the main application', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('aiplayer-inline-');
    final model = AppModel(
      AppStore('${root.path}/test.db'),
      root,
      enableThumbnails: false,
      backgroundWork: false,
    );
    await model.updatePreferences({
      'autoPlay': false,
      'enterFullscreen': false,
      'hardwareDecoding': false,
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      model.dispose();
      model.store.dispose();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pump(const Duration(milliseconds: 100));
    Future<void> open() async {
      final delivered = Completer<void>();
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        ExternalVideoInbox.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onOpen', {'path': fixture}),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
    }

    final configured = <PlaybackSession>{};
    Future<PlaybackSession> loaded() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byType(PlayerPage, skipOffstage: false).evaluate().length,
          lessThanOrEqualTo(1),
        );
        if (find.byType(PlayerPage).evaluate().isNotEmpty) {
          final state = tester.state(find.byType(PlayerPage)) as dynamic;
          final session = state.session as PlaybackSession;
          if (configured.add(session)) {
            await (session.player.platform as NativePlayer).setProperty(
              'ao',
              'null',
            );
          }
          if (session.ready) return session;
          expect(session.error, isEmpty);
        }
      }
      throw StateError('In-app playback did not become ready');
    }

    await open();
    final first = await loaded();
    // Multiple native requests during replacement must settle on one player.
    await open();
    await open();
    final second = await loaded();
    expect(first.closed, isTrue);
    expect(identical(first, second), isFalse);
    expect(find.byType(AIPlayerApp), findsOneWidget);
    expect(find.byType(PlayerPage), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await PlayerPage.waitForDisposals();
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.text('我的影视库'), findsOneWidget);
    expect(model.store.all('progress'), isEmpty);
    expect(await File(fixture).exists(), isTrue);
  });

  testWidgets('landscape controls and menus handle asymmetric safe areas', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = await Directory.systemTemp.createTemp('player-safe-area-');
    final model = AppModel(AppStore('${root.path}/test.db'), root);
    final safePadding = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
    final boundaryKey = GlobalKey();
    try {
      await model.updatePreferences({
        'autoPlay': false,
        'enterFullscreen': false,
        'controlsHideSeconds': 0,
        'metadataStrategy': 'off',
        'hardwareDecoding': false,
        'volume': 64.0,
      });
      final id = await model.importFile(fixture);
      final record = model.store.get('media', id)!;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            builder: (context, child) => ValueListenableBuilder<EdgeInsets>(
              valueListenable: safePadding,
              builder: (context, padding, _) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: padding, viewPadding: padding),
                child: child!,
              ),
            ),
            home: PlayerPage(model: model, media: record),
          ),
        ),
      );
      final dynamic page = tester.state(find.byType(PlayerPage));
      final session = page.session as PlaybackSession;
      await (session.player.platform as NativePlayer).setProperty('ao', 'null');
      for (var i = 0; i < 100 && !session.ready; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.ready, true, reason: session.error);
      await session.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      for (
        var i = 0;
        i < 80 && (session.player.state.videoParams.w ?? 0) == 0;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.player.state.videoParams.w, greaterThan(0));

      for (final padding in const [
        EdgeInsets.only(left: 59, right: 24),
        EdgeInsets.only(left: 24, right: 59),
      ]) {
        safePadding.value = padding;
        await tester.pump(const Duration(milliseconds: 350));
        final viewport = tester.getRect(find.byType(Video));
        final back = tester.getRect(find.byTooltip('返回'));
        final volume = tester.getRect(find.byTooltip('静音'));
        final playlist = tester.getRect(find.byTooltip('播放列表'));
        final fullscreen = DesktopWindow.supported
            ? tester.getRect(find.byTooltip('全屏'))
            : null;
        final lock = tester.getRect(find.byTooltip('锁定控件'));
        final timeline = tester.getRect(
          find.byKey(const ValueKey('player-timeline')),
        );
        final leftMargin = back.left - viewport.left;
        final rightMargin = viewport.right - volume.right;
        expect(leftMargin, closeTo(rightMargin, .1));
        expect(leftMargin, greaterThanOrEqualTo(padding.left + 16));
        expect(rightMargin, greaterThanOrEqualTo(padding.right + 16));
        // Desktop controls append a fullscreen button after the playlist.
        // Its outside edge stays aligned with the safe-area boundary, while
        // the playlist remains immediately adjacent inside the same capsule.
        if (fullscreen != null) {
          expect(fullscreen.right, closeTo(volume.right, .1));
          expect(playlist.right, closeTo(fullscreen.left, .1));
        } else {
          expect(playlist.right, closeTo(volume.right, .1));
        }
        expect(lock.right, closeTo(volume.right, .1));
        expect(timeline.left, closeTo(back.left, .1));
        expect(timeline.right, closeTo(volume.right, .1));
        for (final tooltip in [
          '返回',
          '静音',
          '锁定控件',
          '播放速度',
          '播放器设置',
          '弹幕',
          '播放列表',
          if (DesktopWindow.supported) '全屏',
        ]) {
          expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
        }

        await tester.tap(find.byTooltip('播放列表'));
        await tester.pump(const Duration(milliseconds: 300));
        final popup = find.byKey(const ValueKey('player-playlist-popup'));
        final popupRect = tester.getRect(popup);
        final title = find.descendant(
          of: popup,
          matching: find.text(model.episodeLabel(record)),
        );
        final titleLeft = tester.getRect(title).left;
        expectChoiceTextAlignment(tester, title);
        expect(titleLeft, closeTo(popupRect.left + 14, 1));
        expect(popupRect.left, greaterThanOrEqualTo(padding.left + 12));
        expect(
          popupRect.right,
          lessThanOrEqualTo(viewport.right - padding.right - 12),
        );
        debugPrint(
          'Safe area $padding: controls margins $leftMargin/$rightMargin, '
          'playlist text left $titleLeft',
        );
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final side = padding.left > padding.right ? 'left' : 'right';
        await Directory('../artifacts').create(recursive: true);
        await File(
          '../artifacts/player-safe-area-$side.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        Navigator.of(tester.element(popup)).pop();
        await tester.pump(const Duration(milliseconds: 300));
        for (final (label, key) in const [
          ('播放速度', 'player-speed-popup'),
          ('音轨', 'player-audio-popup'),
        ]) {
          if (label == '播放速度') {
            await tester.tap(find.byTooltip('播放速度'));
          } else {
            await tester.tap(find.byTooltip('播放器设置'));
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(label));
          }
          await tester.pump(const Duration(milliseconds: 350));
          final menu = find.byKey(ValueKey(key));
          expect(menu, findsOneWidget);
          final bounds = tester.getRect(menu);
          final anchor = tester.getRect(
            find.byTooltip(label == '播放速度' ? '播放速度' : '播放器设置'),
          );
          expect(bounds.width, lessThanOrEqualTo(300));
          expect(
            bounds.left,
            greaterThanOrEqualTo(viewport.left + padding.left + 12),
          );
          expect(
            bounds.right,
            lessThanOrEqualTo(viewport.right - padding.right - 12),
          );
          expect(bounds.top, greaterThanOrEqualTo(viewport.top + 12));
          expect(bounds.bottom, closeTo(anchor.top - 8, 1));
          expect(bounds.right, closeTo(anchor.right, 1));
          if (label == '播放速度') {
            // A short landscape viewport must scroll to every rate choice.
            final fastest = find.descendant(
              of: menu,
              matching: find.text('3.0×'),
            );
            await tester.scrollUntilVisible(
              fastest,
              100,
              scrollable: find.descendant(
                of: menu,
                matching: find.byType(Scrollable),
              ),
            );
            await tester.pump(const Duration(milliseconds: 100));
            expect(fastest.hitTestable(), findsOneWidget);
          }
          Navigator.of(tester.element(menu)).pop();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byTooltip('播放器设置'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      safePadding.dispose();
      model.dispose();
      model.store.dispose();
      await root.delete(recursive: true);
    }
  });
}
