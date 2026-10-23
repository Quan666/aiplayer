import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/layout.dart';
import 'package:aiplayer/playback/input.dart';
import 'package:aiplayer/playback/display.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const f = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyF,
    logicalKey: LogicalKeyboardKey.keyF,
    timeStamp: Duration.zero,
  );
  testWidgets(
    'controls stay while dragging or in a panel and restart the full hide interval',
    (tester) async {
      var hidden = 0;
      final timer = PlaybackControlsTimer(() => hidden++);
      timer.configure(playing: true, seconds: 3);
      await tester.pump(const Duration(seconds: 2));
      timer.hold(); // Finger on a slider.
      await tester.pump(const Duration(seconds: 8));
      expect(hidden, 0);
      timer.hold(); // Opening a modal while the button is held.
      timer.release();
      await tester.pump(const Duration(seconds: 8));
      expect(hidden, 0);
      timer.release();
      await tester.pump(const Duration(seconds: 2));
      expect(hidden, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(hidden, 1);
      timer.configure(playing: false, seconds: 3);
      timer.arm();
      await tester.pump(const Duration(seconds: 5));
      expect(hidden, 1);
      timer.dispose();
    },
  );
  test('delayed surface tap preserves pointer-down reveal after rebuilds', () {
    final tap = PlaybackTapIntent();
    tap.pointerDown(visible: false);
    // Pointer-down reveals, then playback/timer/gesture updates rebuild it.
    expect(tap.resolve(visible: true), true);
    tap.pointerDown(visible: true);
    expect(tap.resolve(visible: true), false);
    tap.hoverRevealed();
    tap.pointerDown(visible: true);
    // Desktop hover followed by a click is a single reveal interaction.
    expect(tap.resolve(visible: true), true);
    tap.pointerDown(visible: false);
    tap.cancel();
    expect(tap.resolve(visible: true), false);
  });
  test('shortcut mapping respects reassignment, editing, and key repeat', () {
    expect(shortcutAction(f, {'fullscreen': 'F'}), 'fullscreen');
    expect(shortcutAction(f, {'fullscreen': 'X'}), isNull);
    expect(shortcutAction(f, {'fullscreen': 'F'}, editingText: true), isNull);
    const repeat = KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      timeStamp: Duration.zero,
    );
    expect(shortcutAction(repeat, {'fullscreen': 'F'}), isNull);
    expect(shortcutAction(repeat, {'seekForward': 'F'}), 'seekForward');
    const release = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      timeStamp: Duration.zero,
    );
    expect(shortcutAction(release, {'seekForward': 'F'}), isNull);
    const comma = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(shortcutAction(comma, {'settings': 'Comma'}), 'settings');
    expect(shortcutAction(comma, {'settings': 'None'}), isNull);
  });
  testWidgets('modified keys never trigger unmodified bindings', (
    tester,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      expect(shortcutAction(f, {'fullscreen': 'F'}), isNull);
      expect(shortcutAction(f, {'fullscreen': 'Ctrl+F'}), 'fullscreen');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(shortcutAction(f, {'fullscreen': 'Shift+Ctrl+F'}), 'fullscreen');
      expect(shortcutAction(f, {'fullscreen': 'Ctrl+F'}), isNull);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  });
  test(
    'seek and level gestures scale with viewport and clamp at boundaries',
    () {
      expect(
        gestureSeekTarget(
          startSeconds: 600,
          deltaX: 195,
          width: 390,
          durationSeconds: 1440,
        ),
        660,
      );
      expect(
        gestureSeekTarget(
          startSeconds: 1,
          deltaX: -390,
          width: 390,
          durationSeconds: 1440,
        ),
        0,
      );
      expect(
        gestureSeekTarget(
          startSeconds: 20,
          deltaX: 844,
          width: 844,
          durationSeconds: 30,
        ),
        30,
      );
      expect(
        gestureSeekTarget(
          startSeconds: 20,
          deltaX: 1,
          width: 0,
          durationSeconds: 30,
        ),
        0,
      );
      expect(gestureLevel(start: .5, deltaY: -200, height: 400), 1);
      expect(gestureLevel(start: .5, deltaY: 600, height: 400), 0);
      expect(gestureLevel(start: .5, deltaY: 1, height: 0), .5);
    },
  );
  testWidgets('leaving fullscreen restores legacy bars before edge-to-edge', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    try {
      await PlayerDisplay.restoreSystemUi();
      expect(calls.map((call) => call.method).toList(), [
        'SystemChrome.setPreferredOrientations',
        'SystemChrome.setEnabledSystemUIOverlays',
        'SystemChrome.setEnabledSystemUIMode',
      ]);
      expect(calls[0].arguments, isEmpty);
      expect(calls[1].arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
      expect(calls[2].arguments, 'SystemUiMode.edgeToEdge');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
  test('fullscreen orientation follows display size and rotation metadata', () {
    expect(videoIsLandscape(width: null, height: null), isNull);
    expect(videoIsLandscape(width: 0, height: 1080), isNull);
    expect(videoIsLandscape(width: 1920, height: 1080), true);
    expect(videoIsLandscape(width: 1080, height: 1920), false);
    expect(videoIsLandscape(width: 1920, height: 1080, rotation: 90), false);
    expect(videoIsLandscape(width: 1080, height: 1920, rotation: 270), true);
    expect(videoIsLandscape(width: 1920, height: 1080, rotation: -90), false);
    expect(videoIsLandscape(width: 1920, height: 1080, rotation: 180), true);
    expect(videoIsLandscape(width: 720, height: 720), true);
    expect(videoIsLandscape(width: 720, height: 720, rotation: 90), true);
  });
  testWidgets('leaving immersive mode retains the current video orientation', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    try {
      await PlayerDisplay.restoreSystemUi(restoreOrientation: false);
      expect(calls.map((call) => call.method), [
        'SystemChrome.setEnabledSystemUIOverlays',
        'SystemChrome.setEnabledSystemUIMode',
      ]);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
  test('filtered comments do not reserve lanes and speed changes lifetime', () {
    const comments = [
      DanmakuComment(0, 'spoiler sentence', 0xffffff, 0),
      DanmakuComment(0, 'top', 0xffffff, 1),
      DanmakuComment(0, 'bottom', 0xffffff, 2),
      DanmakuComment(0, 'keep', 0xffffff, 0),
    ];
    final schedule = assignLanes(
      comments,
      1,
      speed: 2,
      top: false,
      bottom: false,
      blockedWords: 'Spoiler\nother',
    );
    expect(schedule, hasLength(1));
    expect(schedule.single.index, 3);
    expect(schedule.single.duration, 4);
    expect(
      assignLanes(comments, 1, scroll: false, top: false, bottom: false),
      isEmpty,
    );
    final slow = assignLanes(
      const [
        DanmakuComment(0, 'a', 0xffffff, 0),
        DanmakuComment(10, 'b', 0xffffff, 0),
      ],
      1,
      speed: .5,
      presetFilter: false,
    );
    expect(slow, hasLength(1));
    expect(slow.single.duration, 16);
  });
}
