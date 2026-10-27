import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/desktop_window.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:aiplayer/ui/player_controls_settings.dart';
import 'package:aiplayer/ui/player_danmaku_panel.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:aiplayer/ui/desktop_window_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Native functional regression, not a performance measurement.
// xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test -d linux --no-pub
// integration_test/player_controls_behavior_test.dart
// --dart-define=CONTROLS_ARTIFACT_DIR=/absolute/path/to/artifacts
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native shortcuts preserve hidden controls and show seek delta', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('player-controls-');
    final store = await AppStore.open('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': false,
      'autoNextEpisode': false,
      'autoLoadExternalSubtitles': false,
      'volume': 50.0,
      'refreshInterval': 0,
    });
    expect(model.preferences.controlsHideSeconds, 2);
    final id = await model.importFile(
      const String.fromEnvironment(
        'MEDIA_FIXTURE',
        defaultValue: '/tmp/aiplayer-lifecycle-fixture.mp4',
      ),
    );
    await preparePlaybackFonts(root);
    final boundary = GlobalKey();
    final navigator = GlobalKey<NavigatorState>();
    final actions = <String>[];
    final previews = <Map<String, Object?>>[];
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    const artifact = String.fromEnvironment('CONTROLS_ARTIFACT_DIR');
    try {
      DesktopWindow.watchClose(() async {});
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => DesktopWindowFrame(child: child!),
          home: const Scaffold(body: Center(child: Text('影视库'))),
        ),
      );
      await DesktopWindow.ready();
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (context) => RepaintBoundary(
              key: boundary,
              child: PlayerPage(model: model, media: store.get('media', id)!),
            ),
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
      await session.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      await _until(
        () => session.player.state.duration.inSeconds >= 30,
        'duration',
      );
      session.danmaku = DanmakuSession(
        store,
        DanmuApiClient('https://offline.invalid', 'fixture'),
        id,
      )..comments = const [DanmakuComment(0, '本地弹幕快捷键回归', 0xffffff, 0)];
      await session.setPlaying(true);
      await _until(
        () => session.player.state.playing && !session.player.state.buffering,
        'playing',
      );
      await tester.pump(const Duration(milliseconds: 300));

      // The real mouse starts a fresh interval; stationary pointers must not
      // be mistaken for new movement when a shortcut rebuilds a control.
      await mouse.addPointer(location: const Offset(-1, -1));
      await mouse.moveTo(const Offset(12, 12));
      final hideClock = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 1200));
      _expectChrome(tester, visible: true);
      await _until(() => _chromeHidden(tester), 'two-second auto hide');
      final hiddenAfterMs = hideClock.elapsedMilliseconds;
      expect(hiddenAfterMs, inInclusiveRange(1750, 2900));
      await tester.pump(const Duration(milliseconds: 250));
      _expectChrome(tester, visible: false);
      expect(DesktopWindow.state.value.fullscreen, isFalse);
      expect(find.byKey(const ValueKey('desktop-window-drag')), findsNothing);
      expect(find.byTooltip('关闭窗口'), findsNothing);
      actions.add('windowed auto hide also hides window controls');

      Future<void> hiddenKey(
        LogicalKeyboardKey key,
        String name,
        FutureOr<bool> Function() applied,
      ) async {
        await tester.sendKeyEvent(key);
        await tester.pump(const Duration(milliseconds: 40));
        _expectChrome(tester, visible: false);
        await _until(applied, name);
        await tester.pump(const Duration(milliseconds: 100));
        _expectChrome(tester, visible: false);
        actions.add(name);
      }

      await hiddenKey(
        LogicalKeyboardKey.space,
        'Space pauses',
        () async => await native.getProperty('pause') == 'yes',
      );
      final pausedAt = await _position(native);
      await tester.pump(const Duration(milliseconds: 350));
      expect(await _position(native), closeTo(pausedAt, .08));
      await hiddenKey(
        LogicalKeyboardKey.keyK,
        'K resumes',
        () async => await native.getProperty('pause') == 'no',
      );
      await _until(
        () async => await _position(native) > pausedAt + .2,
        'native playback advances',
      );
      await hiddenKey(
        LogicalKeyboardKey.keyK,
        'K pauses',
        () async => await native.getProperty('pause') == 'yes',
      );
      await hiddenKey(
        LogicalKeyboardKey.space,
        'Space resumes',
        () async => await native.getProperty('pause') == 'no',
      );
      await hiddenKey(
        LogicalKeyboardKey.space,
        'Space pauses again',
        () async => await native.getProperty('pause') == 'yes',
      );

      for (final (key, label, volume) in [
        (LogicalKeyboardKey.arrowDown, 'volume down', 45.0),
        (LogicalKeyboardKey.arrowUp, 'volume up', 50.0),
        (LogicalKeyboardKey.keyM, 'mute', 0.0),
        (LogicalKeyboardKey.keyM, 'unmute', 50.0),
      ]) {
        await hiddenKey(
          key,
          label,
          () async =>
              model.preferences.volume == volume &&
              (double.parse(await native.getProperty('volume')) - volume)
                      .abs() <
                  .1,
        );
      }
      for (final enabled in [false, true]) {
        await hiddenKey(
          LogicalKeyboardKey.keyS,
          'subtitles $enabled',
          () async =>
              model.preferences.subtitlesEnabled == enabled &&
              await native.getProperty('sub-visibility') ==
                  (enabled ? 'yes' : 'no'),
        );
        await hiddenKey(
          LogicalKeyboardKey.keyD,
          'danmaku $enabled',
          () =>
              model.preferences.danmuVisible == enabled &&
              session.danmaku!.visible == enabled,
        );
      }
      // The 89-second shortcut clamps to this local 45-second clip's end.
      await hiddenKey(
        LogicalKeyboardKey.keyJ,
        'J seeks forward',
        () async =>
            await _position(native) >=
            session.player.state.duration.inSeconds - 1,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      try {
        await hiddenKey(
          LogicalKeyboardKey.keyJ,
          'Shift+J seeks backward',
          () async => await _position(native) < 1,
        );
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      final settings = find.byKey(const ValueKey('player-settings-popup'));
      await _until(() => settings.evaluate().isNotEmpty, 'settings shortcut');
      await tester.pump(const Duration(milliseconds: 250));
      _expectChrome(tester, visible: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings, findsNothing);
      _expectChrome(tester, visible: false);
      actions.add('settings opens and closes without revealing chrome');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump(const Duration(milliseconds: 500));
      _expectChrome(tester, visible: false);
      final fullscreenBeforePanels = DesktopWindow.state.value.fullscreen;
      final playerRoute = ModalRoute.of(
        tester.element(find.byType(PlayerPage)),
      )!;

      Future<void> dismissPanel(Finder panel, String name) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        try {
          await tester.pump(const Duration(milliseconds: 350));
          expect(panel, findsNothing, reason: '$name closes with Escape');
          // Holding Escape after closing a popup must not leave fullscreen or
          // playback, even after its route and keyboard listener are disposed.
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(PlayerPage), findsOneWidget);
          expect(DesktopWindow.state.value.fullscreen, fullscreenBeforePanels);
          expect(session.closed, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        }
        actions.add('Escape dismisses $name without leaving playback');
      }

      for (final (open, panel, name)
          in <(Future<void> Function(), Finder, String)>[
            (() => page.quickSettings(), settings, 'settings'),
            (
              () => page.playbackSpeed(),
              find.byKey(const ValueKey('player-speed-popup')),
              'playback speed',
            ),
            (
              () => page.audioTracks(),
              find.byKey(const ValueKey('player-audio-popup')),
              'audio tracks',
            ),
            (() => page.tracks(false), find.text('选择本地外挂字幕'), 'subtitles'),
            (() => page.diagnostics(), find.text('播放诊断'), 'diagnostics'),
          ]) {
        final closed = open();
        await _until(() => panel.evaluate().isNotEmpty, 'open $name');
        await tester.pump(const Duration(milliseconds: 350));
        await dismissPanel(panel, name);
        await closed;
        expect(playerRoute.isCurrent, isTrue);
      }

      final danmakuClosed = page.danmakuPanel() as Future<void>;
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, '保留弹幕搜索草稿');
      await tester.tap(find.widgetWithText(Tab, '列表'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('danmaku-time-list')), findsOneWidget);
      await dismissPanel(
        find.byType(PlayerDanmakuPanel),
        'danmaku list after unfocus',
      );
      await danmakuClosed;
      expect(playerRoute.isCurrent, isTrue);

      final advancedClosed = page.advancedSettings() as Future<void>;
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byType(PlayerSelect<String>).first);
      await tester.pump(const Duration(milliseconds: 350));
      final choices = find.widgetWithText(PlayerChoiceTile, '裁剪填满');
      expect(choices, findsOneWidget);
      await dismissPanel(choices, 'nested video fit choice');
      expect(find.byType(PlayerQuickSettings), findsOneWidget);
      expect(playerRoute.isCurrent, isFalse);
      await dismissPanel(find.byType(PlayerQuickSettings), 'advanced settings');
      await advancedClosed;
      expect(playerRoute.isCurrent, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PlayerPage), findsOneWidget);
      _expectChrome(tester, visible: false);
      actions.add('F and Escape preserve hidden controls');

      // Re-establish a native position event while playing before pausing for
      // accurate drag deltas: paused seeks may not publish a position event.
      await hiddenKey(
        LogicalKeyboardKey.keyK,
        'K resumes after seek',
        () async => await native.getProperty('pause') == 'no',
      );
      await _until(
        () =>
            session.position.value > const Duration(milliseconds: 250) &&
            session.position.value < const Duration(seconds: 5),
        'clock after seek',
      );
      await hiddenKey(
        LogicalKeyboardKey.space,
        'Space pauses before drag',
        () async => await native.getProperty('pause') == 'yes',
      );
      await mouse.moveTo(const Offset(32, 24));
      await tester.pump(const Duration(milliseconds: 300));
      _expectChrome(tester, visible: true);
      expect(find.byKey(const ValueKey('desktop-window-drag')), findsOneWidget);
      if (!Platform.isMacOS) {
        expect(find.byTooltip('关闭窗口'), findsOneWidget);
      }
      actions.add('mouse movement reveals controls');

      final first = await _dragPreview(
        tester,
        session,
        native,
        boundary,
        delta: const Duration(seconds: 30),
        expectedDirection: '>>',
        expectedDifference: '+0:30',
        artifact: artifact,
        name: 'seek-forward',
      );
      previews.add(first);
      // Release commits exactly the displayed target to the foreground player.
      final forwardTarget = (first['targetMilliseconds']! as int) / 1000;
      await _until(
        () async => (await _position(native) - forwardTarget).abs() < .6,
        'forward seek commits',
      );
      await _until(
        () =>
            (session.position.value.inMilliseconds / 1000 - forwardTarget)
                .abs() <
            .6,
        'forward seek position event',
      );
      previews.add(
        await _dragPreview(
          tester,
          session,
          native,
          boundary,
          delta: const Duration(seconds: -20),
          expectedDirection: '<<',
          expectedDifference: '-0:20',
          artifact: artifact,
          name: 'seek-backward',
        ),
      );
      final backwardTarget =
          (previews.last['targetMilliseconds']! as int) / 1000;
      await _until(
        () async => (await _position(native) - backwardTarget).abs() < .6,
        'backward seek commits',
      );
      expect(session.error, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _until(
        () => find.byType(PlayerPage).evaluate().isEmpty,
        'return to library',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(DesktopWindow.controlsVisible.value, isTrue);
      expect(find.text('影视库'), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-window-drag')), findsOneWidget);
      actions.add('leaving playback restores window controls');
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'scope':
            'Debug native PlayerPage; local H264 fixture; functional checks only',
        'defaultControlsHideSeconds': model.preferences.controlsHideSeconds,
        'controlsHiddenAfterMilliseconds': hiddenAfterMs,
        'actions': actions,
        'previews': previews,
      };
      binding.reportData = report;
      if (artifact.isNotEmpty) {
        await Directory(artifact).create(recursive: true);
        await File(
          '$artifact/player-controls.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
      debugPrint('PLAYER_CONTROLS ${jsonEncode(report)}');
    } finally {
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      DesktopWindow.watchClose(null);
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

const _chromeGroups = [
  'top-controls',
  'transport-controls',
  'bottom-controls',
  'shade',
  'lock',
];

double _opacity(WidgetTester tester, String name) => tester
    .widget<AnimatedOpacity>(
      find
          .descendant(
            of: find.byKey(ValueKey('player-$name')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

bool _chromeHidden(WidgetTester tester) =>
    _chromeGroups.every((name) => _opacity(tester, name) == 0);

void _expectChrome(WidgetTester tester, {required bool visible}) {
  if (DesktopWindow.supported) {
    expect(
      DesktopWindow.controlsVisible.value,
      visible,
      reason: 'window controls follow playback controls',
    );
  }
  for (final name in _chromeGroups) {
    expect(
      _opacity(tester, name),
      visible ? 1 : 0,
      reason: '$name must remain ${visible ? 'visible' : 'hidden'}',
    );
  }
}

Future<double> _position(NativePlayer player) async =>
    double.parse(await player.getProperty('time-pos'));

Future<void> _until(FutureOr<bool> Function() ready, String phase) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Map<String, Object?>> _dragPreview(
  WidgetTester tester,
  PlaybackSession session,
  NativePlayer native,
  GlobalKey boundary, {
  required Duration delta,
  required String expectedDirection,
  required String expectedDifference,
  required String artifact,
  required String name,
}) async {
  final timeline = find.byKey(const ValueKey('player-timeline'));
  final slider = tester.widget<Slider>(timeline);
  final box = tester.renderObject<RenderBox>(timeline);
  final style = SliderTheme.of(tester.element(timeline));
  final track = style.trackShape!.getPreferredRect(
    parentBox: box,
    sliderTheme: style,
    isEnabled: true,
    isDiscrete: false,
  );
  Offset point(double milliseconds) => box.localToGlobal(
    Offset(
      track.left + track.width * milliseconds / slider.max,
      track.center.dy,
    ),
  );
  final origin = session.position.value;
  final target = Duration(
    seconds: origin.inSeconds + delta.inSeconds,
    milliseconds: 200,
  );
  expect(target.inMilliseconds, inInclusiveRange(0, slider.max.round()));
  final nativeBefore = await _position(native);
  final gesture = await tester.startGesture(point(slider.value));
  try {
    await gesture.moveTo(point(target.inMilliseconds.toDouble()));
    await tester.pump(const Duration(milliseconds: 400));
    final time = find.byKey(const ValueKey('seek-preview-time'));
    final direction = find.byKey(const ValueKey('seek-preview-direction'));
    final difference = find.byKey(const ValueKey('seek-preview-difference'));
    final readout = find.byKey(const ValueKey('seek-preview-readout'));
    final displayedTarget = tester.widget<Slider>(timeline).value.round();
    expect(
      tester.widget<Text>(time).data,
      clockText(Duration(milliseconds: displayedTarget)),
    );
    expect(tester.widget<Text>(direction).data, expectedDirection);
    expect(tester.widget<Text>(difference).data, expectedDifference);
    final targetRect = tester.getRect(time);
    expect(
      tester.getRect(direction).center.dy,
      closeTo(targetRect.center.dy, .01),
    );
    expect(
      tester.getRect(difference).center.dy,
      closeTo(targetRect.center.dy, .01),
    );
    expect(
      await _position(native),
      closeTo(nativeBefore, .08),
      reason:
          'Dragging previews must not seek the foreground decoder before release',
    );
    final readoutRect = tester.getRect(readout);
    final previewRect = tester.getRect(
      find.byKey(const ValueKey('seek-preview-frame')),
    );
    final timelineRect = tester.getRect(timeline);
    expect(readoutRect.bottom, lessThanOrEqualTo(previewRect.top));
    expect(previewRect.bottom, lessThan(timelineRect.top));
    _expectChrome(tester, visible: true);
    if (artifact.isNotEmpty) {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(artifact).create(recursive: true);
        await File(
          '$artifact/$name.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    return {
      'direction': expectedDirection,
      'difference': expectedDifference,
      'originMilliseconds': origin.inMilliseconds,
      'targetMilliseconds': displayedTarget,
      'viewportHeight': tester.getSize(find.byType(PlayerPage)).height,
      'readoutTop': readoutRect.top,
      'readoutBottom': readoutRect.bottom,
      'previewTop': previewRect.top,
      'previewBottom': previewRect.bottom,
      'timelineTop': timelineRect.top,
    };
  } finally {
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
  }
}
