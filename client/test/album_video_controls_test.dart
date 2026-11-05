import 'package:aiplayer/playback/album_video_controller.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/album_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ChangeNotifier implements AlbumVideoController {
  @override
  final position = ValueNotifier(Duration.zero);
  @override
  Duration duration = const Duration(minutes: 2);
  @override
  PlaybackSession? session = _Session();
  @override
  bool playing = false, loading = false, muted = false;
  @override
  bool presentationActive = true;
  @override
  String error = '';
  int toggles = 0, muteToggles = 0;
  final seeks = <Duration>[];

  void changed() => notifyListeners();

  @override
  Future<void> toggle() async {
    toggles++;
    playing = !playing;
    changed();
  }

  @override
  Future<void> toggleMute() async {
    muteToggles++;
    muted = !muted;
    changed();
  }

  @override
  Future<void> seek(Duration value) async => seeks.add(value);

  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements PlaybackSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final play = find.byKey(const ValueKey('album-video-toggle'));
  final mute = find.byKey(const ValueKey('album-video-mute'));
  final seek = find.byKey(const ValueKey('album-video-seek'));
  final time = find.byKey(const ValueKey('album-video-time'));

  Future<void> mount(
    WidgetTester tester,
    _Controller controller, {
    VoidCallback? onStart,
    VoidCallback? onEnd,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 320,
            child: AlbumVideoControls(
              controller: controller,
              onInteractionStart: onStart,
              onInteractionEnd: onEnd,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'compact transport shows live time and keeps both buttons usable',
    (tester) async {
      final controller = _Controller()
        ..duration = const Duration(hours: 12, minutes: 34, seconds: 56)
        ..position.value = const Duration(hours: 1, minutes: 2, seconds: 3);
      await mount(tester, controller);
      expect(find.text('1:02:03 / 12:34:56'), findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(time).didExceedMaxLines,
        isFalse,
        reason:
            'time=${tester.getSize(time)} play=${tester.getSize(play)} '
            'mute=${tester.getSize(mute)}',
      );
      for (final button in [play, mute]) {
        expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(52));
        expect(button.hitTestable(), findsOneWidget);
      }
      expect(tester.getRect(play).left, lessThan(tester.getRect(mute).left));
      expect(
        tester.getRect(seek).top,
        greaterThanOrEqualTo(tester.getRect(play).bottom),
      );
      expect(tester.getSize(seek).width, 320);

      controller.position.value = const Duration(
        hours: 1,
        minutes: 2,
        seconds: 4,
      );
      await tester.pump();
      expect(find.text('1:02:04 / 12:34:56'), findsOneWidget);
      final playBounds = tester.getRect(play);
      await tester.tapAt(Offset(playBounds.left + 3, playBounds.center.dy));
      await tester.pump();
      expect(controller.toggles, 1);
      expect(find.byTooltip('暂停'), findsOneWidget);
      final muteBounds = tester.getRect(mute);
      await tester.tapAt(Offset(muteBounds.right - 3, muteBounds.center.dy));
      await tester.pump();
      expect(controller.muteToggles, 1);
      expect(find.byTooltip('取消静音'), findsOneWidget);
      controller
        ..playing = false
        ..error = '播放失败'
        ..changed();
      await tester.pump();
      expect(find.byTooltip('重试播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'scrubbing previews time and submits once; background cancels without a frame',
    (tester) async {
      final controller = _Controller()
        ..position.value = const Duration(seconds: 10);
      var starts = 0, ends = 0;
      await mount(
        tester,
        controller,
        onStart: () => starts++,
        onEnd: () => ends++,
      );
      final bounds = tester.getRect(seek);
      final gesture = await tester.startGesture(
        Offset(bounds.left + 40, bounds.center.dy),
      );
      await tester.pump();
      await gesture.moveTo(Offset(bounds.center.dx, bounds.center.dy));
      await tester.pump();
      expect(starts, 1);
      expect(controller.seeks, isEmpty);
      final preview = tester.widget<Text>(time).data;
      expect(preview, isNot('0:10 / 2:00'));
      controller.position.value = const Duration(seconds: 11);
      await tester.pump();
      expect(tester.widget<Text>(time).data, preview);
      await gesture.up();
      await tester.pump();
      expect(ends, 1);
      expect(controller.seeks, hasLength(1));
      expect(controller.seeks.single.inSeconds, inInclusiveRange(55, 65));

      final cancelled = await tester.startGesture(
        Offset(bounds.left + 40, bounds.center.dy),
      );
      await tester.pump();
      await cancelled.moveTo(Offset(bounds.right - 50, bounds.center.dy));
      await tester.pump();
      expect(starts, 2);
      controller.presentationActive = false;
      controller.changed();
      // No pump: hidden/paused applications may not receive another frame.
      expect(ends, 2);
      await cancelled.up();
      expect(controller.seeks, hasLength(1));
      controller.presentationActive = true;
      controller.changed();
      await tester.pump();
      expect(find.text('0:11 / 2:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(ends, 2);
      controller.dispose();
    },
  );
}
