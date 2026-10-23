import 'dart:ui' as ui;
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/overlay.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

const _current = DanmakuComment(26, 'original comment', 0xffffff, 0);
const _future = DanmakuComment(40, 'future comment', 0xffffff, 0);

Widget _overlay(_Session session, GlobalKey boundary) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: RepaintBoundary(
      key: boundary,
      child: SizedBox(
        width: 480,
        height: 180,
        child: DanmakuOverlay(
          session: session,
          opacity: 1,
          area: 1,
          density: 1,
          presetFilter: false,
        ),
      ),
    ),
  ),
);

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return Uint8List.fromList(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }))!;
}

bool _hasPaint(Uint8List pixels) {
  for (var i = 3; i < pixels.length; i += 4) {
    if (pixels[i] != 0) return true;
  }
  return false;
}

void main() {
  testWidgets('empty gaps sleep and wake for the next scrolling comment', (
    tester,
  ) async {
    final session = _Session(const [_current, _future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    session.seconds = 35;
    await tester.pumpWidget(_overlay(session, boundary));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    // No native position event: the exact arrival still wakes the overlay.
    session.seconds = 40.1;
    await tester.pump(const Duration(milliseconds: 5100));
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    session.seconds = 48;
    await tester.pump(const Duration(seconds: 8));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fixed comments repaint at expiry without a continuous ticker', (
    tester,
  ) async {
    final session = _Session(const [
      DanmakuComment(29, 'top comment', 0xffffff, 1),
    ]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    session.player.state = const PlayerState(playing: true, rate: 2);
    await tester.pumpWidget(_overlay(session, boundary));
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, 0);

    session.seconds = 33;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause cancels scheduled arrivals and resume reschedules them', (
    tester,
  ) async {
    final session = _Session(const [_future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(_overlay(session, boundary));
    session.player.state = const PlayerState(playing: false);
    session.refresh(session.danmaku.comments);
    await tester.pump(const Duration(seconds: 20));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    session.player.state = const PlayerState(playing: true, rate: 2);
    session.refresh(session.danmaku.comments);
    await tester.pump();
    session.seconds = 40.1;
    await tester.pump(const Duration(milliseconds: 5050));
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fully filtered comments never start a frame ticker', (
    tester,
  ) async {
    final session = _Session(const [_current, _future]);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DanmakuOverlay(session: session, blockedWords: 'comment'),
      ),
    );
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  final snapshots = <String, List<DanmakuComment>>{
    'an earlier arrival changes source indices': const [
      DanmakuComment(25, 'late historical arrival', 0xff0000, 0),
      _current,
      _future,
    ],
    'the current comment is deleted': const [_future],
    'the current comment is edited': const [
      DanmakuComment(26, 'edited comment', 0xff0000, 2),
      _future,
    ],
    'the entire snapshot is empty': const [],
  };
  for (final entry in snapshots.entries) {
    testWidgets('refresh keeps identical pixels when ${entry.key}', (
      tester,
    ) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      final before = await _pixels(tester, boundary);
      expect(_hasPaint(before), isTrue);

      session.refresh(entry.value);
      await tester.pump();
      final after = await _pixels(tester, boundary);
      expect(listEquals(after, before), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'an empty refresh keeps animating until the retained comment exits',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      final before = await _pixels(tester, boundary);
      expect(_hasPaint(before), isTrue);

      session.refresh(const []);
      await tester.pump();
      expect(listEquals(await _pixels(tester, boundary), before), isTrue);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      // Advance only the interpolated clock. The ticker must repaint without a
      // new player position event or a nonempty comments list.
      session.seconds = 31;
      await tester.pump(const Duration(seconds: 1));
      final moving = await _pixels(tester, boundary);
      expect(_hasPaint(moving), isTrue);
      expect(listEquals(moving, before), isFalse);

      session.seconds = 34;
      await tester.pump(const Duration(seconds: 3));
      expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'seeking rebuilds from the latest snapshot at the same position',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      session.refresh(const []);
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);

      await session.seek(const Duration(seconds: 30));
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a late native backward seek restores history after a concurrent refresh',
    (tester) async {
      const early = DanmakuComment(6, 'early comment', 0xffffff, 0);
      final session = _Session(const [early, _current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await session.seek(const Duration(seconds: 10));
      await tester.pumpWidget(_overlay(session, boundary));
      final expected = await _pixels(tester, boundary);
      expect(_hasPaint(expected), isTrue);

      await session.seek(const Duration(seconds: 30));
      await tester.pump();
      // Observe the next seek command while the native clock is still at 30.
      await session.seek(const Duration(seconds: 30));
      await tester.pump();
      session.refresh(const [early]);
      await tester.pump();

      // Its target position arrives after refresh, without another revision.
      session.seconds = 10;
      session.position.value = const Duration(seconds: 10);
      await tester.pump();
      expect(listEquals(await _pixels(tester, boundary), expected), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'replacing the playback session clears retained comments and listeners',
    (tester) async {
      final previous = _Session(const [_current]);
      final next = _Session(const []);
      addTearDown(previous.dispose);
      addTearDown(next.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(previous, boundary));
      previous.refresh(const []);
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      expect(previous.listened, isTrue);

      await tester.pumpWidget(_overlay(next, boundary));
      expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
      expect(previous.listened, isFalse);
      expect(next.listened, isTrue);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(next.listened, isFalse);
    },
  );
}

class _Session extends ChangeNotifier implements PlaybackSession {
  _Session(List<DanmakuComment> comments) : danmaku = _Danmaku(comments);

  @override
  final _Danmaku danmaku;
  @override
  final _Player player = _Player();
  @override
  final position = ValueNotifier<Duration>(const Duration(seconds: 30));
  @override
  bool closed = false;
  @override
  double seconds = 30;
  @override
  int timelineRevision = 0;

  bool get listened => hasListeners;

  void refresh(List<DanmakuComment> comments) {
    danmaku.comments = comments;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration target) async {
    seconds = target.inMicroseconds / Duration.microsecondsPerSecond;
    position.value = target;
    timelineRevision++;
    notifyListeners();
  }

  @override
  void dispose() {
    position.dispose();
    danmaku.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Danmaku extends ChangeNotifier implements DanmakuSession {
  _Danmaku(this.comments);

  @override
  List<DanmakuComment> comments;
  @override
  String? episodeId = '1';
  @override
  double shift = 0, offset = 0;
  @override
  bool visible = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState(playing: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
