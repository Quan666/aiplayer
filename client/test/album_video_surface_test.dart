import 'package:aiplayer/playback/album_video_controller.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/album_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

class _Controller extends ChangeNotifier implements AlbumVideoController {
  @override
  PlaybackSession? session = _Session();
  @override
  bool firstFrameRendered = false, presentationActive = true;
  @override
  bool loading = false, buffering = false;
  @override
  bool playing = false;
  @override
  String error = '';
  void changed() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements PlaybackSession {
  @override
  final Player player = _Player();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState get state => const PlayerState();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const cover = ValueKey('cover');
  Future<void> mount(WidgetTester tester, _Controller controller) =>
      tester.pumpWidget(
        MaterialApp(
          home: AlbumVideoSurface(
            controller: controller,
            backgroundColor: Colors.white,
            videoBuilder: (_, color) => ColoredBox(color: color),
            cover: const ColoredBox(key: cover, color: Colors.blue),
          ),
        ),
      );

  testWidgets('decoded notification retains cover until texture composition', (
    tester,
  ) async {
    final controller = _Controller();
    await mount(tester, controller);
    controller.firstFrameRendered = true;
    controller.changed();
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox).last).color,
      Colors.white,
    );
    controller.session = _Session();
    controller.firstFrameRendered = false;
    controller.changed();
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'startup keeps its cover and loading feedback until the video is presented',
    (tester) async {
      final controller = _Controller()..session = null;
      await mount(tester, controller);
      final coverElement = tester.element(find.byKey(cover));
      controller.loading = true;
      controller.changed();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.session = _Session();
      controller.playing = true;
      controller.loading = false;
      controller.changed();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.element(find.byKey(cover)), same(coverElement));

      controller.buffering = true;
      controller.changed();
      await tester.pump();
      controller.buffering = false;
      controller.changed();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.element(find.byKey(cover)), same(coverElement));

      controller.error = '播放失败';
      controller.changed();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.element(find.byKey(cover)), same(coverElement));
      controller.error = '';
      controller.firstFrameRendered = true;
      controller.changed();
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(cover), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'background revokes pending reveal without pump and resume retries once',
    (tester) async {
      final controller = _Controller();
      await mount(tester, controller);
      controller.firstFrameRendered = true;
      controller.changed();
      controller.presentationActive = false;
      controller.changed();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      controller.presentationActive = true;
      controller.changed();
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(cover), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
