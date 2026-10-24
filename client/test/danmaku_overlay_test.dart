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

Future<void> _settleLayout(WidgetTester tester) async {
  final states = tester.stateList(find.byType(DanmakuOverlay)).toList();
  if (states.isEmpty) return;
  for (var i = 0; i < 1000; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
    if (states.every(
      (state) => (state as dynamic).debugLayoutWorker.pendingCount == 0,
    )) {
      await tester.pump();
      return;
    }
  }
  fail('Danmaku layout worker did not settle');
}

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  await _settleLayout(tester);
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
  testWidgets(
    'an initially backgrounded overlay prepares only after resuming',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(_overlay(session, boundary));
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(find.byType(DanmakuOverlay), findsOneWidget);
      final state = tester.state(find.byType(DanmakuOverlay)) as dynamic;
      expect(state.debugLayoutWorker.starts, 0);
      expect(tester.binding.transientCallbackCount, 0);
      expect(session.presentationActive, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settleLayout(tester);
      expect(state.debugLayoutWorker.starts, 1);
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('losing focus keeps scrolling comments moving with the video', (
    tester,
  ) async {
    final session = _Session(const [_current]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(_overlay(session, boundary));
    await _settleLayout(tester);
    final before = await _pixels(tester, boundary);
    expect(_hasPaint(before), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(session.presentationActive, isTrue);
    expect(session.player.state.playing, isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // Only the interpolated video clock changes: focus loss must not require a
    // native position event or a click back into the player to repaint.
    session.seconds = 31;
    await tester.pump(const Duration(seconds: 1));
    final after = await _pixels(tester, boundary);
    expect(_hasPaint(after), isTrue);
    expect(listEquals(after, before), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  testWidgets('scheduled comments still arrive while the app is unfocused', (
    tester,
  ) async {
    final session = _Session(const [_future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(_overlay(session, boundary));
    await _settleLayout(tester);
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    session.seconds = 40.1;
    await tester.pump(const Duration(milliseconds: 10100));
    expect(session.presentationActive, isTrue);
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  for (final background in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('$background stops moving comments without another frame', (
      tester,
    ) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      await _settleLayout(tester);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      tester.binding.handleAppLifecycleStateChanged(background);
      // Android may produce no frames after this event. Late playback events
      // must leave animation and refresh disabled without any pump.
      for (var i = 0; i < 20; i++) {
        session.seconds = 30 + i / 100;
        session.position.value = Duration(milliseconds: 30000 + i * 10);
        session.refresh(session.danmaku.comments);
      }
      expect(session.presentationActive, isFalse);
      expect(session.player.state.playing, isTrue);
      expect(tester.binding.transientCallbackCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(session.presentationActive, isTrue);
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleLayout(tester);
    });
  }

  testWidgets('offscreen position updates do not repaint and resume once', (
    tester,
  ) async {
    final session = _Session(const [_future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    Widget view(bool enabled) =>
        TickerMode(enabled: enabled, child: _overlay(session, boundary));
    await tester.pumpWidget(view(true));
    await _settleLayout(tester);
    await tester.pumpWidget(view(false));
    await _settleLayout(tester);
    expect(session.presentationActive, isFalse);
    expect(session.player.state.playing, isTrue);
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    for (var i = 0; i < 50; i++) {
      session.seconds = 40.1 + i / 1000;
      session.position.value = Duration(milliseconds: 40100 + i);
    }
    await tester.pump(const Duration(seconds: 15));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(view(true));
    await _settleLayout(tester);
    expect(session.presentationActive, isTrue);
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  testWidgets('background stops arrivals and foreground uses latest position', (
    tester,
  ) async {
    final session = _Session(const [_future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(_overlay(session, boundary));
    await _settleLayout(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(session.presentationActive, isFalse);
    expect(session.player.state.playing, isTrue);
    session.seconds = 40.1;
    session.position.value = const Duration(milliseconds: 40100);
    await tester.pump(const Duration(seconds: 15));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(session.presentationActive, isTrue);
    await tester.pump();
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  testWidgets('empty gaps sleep and wake for the next scrolling comment', (
    tester,
  ) async {
    final session = _Session(const [_current, _future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    session.seconds = 35;
    await tester.pumpWidget(_overlay(session, boundary));
    await _settleLayout(tester);
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
    await _settleLayout(tester);
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
    await _settleLayout(tester);
    expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
    expect(tester.binding.transientCallbackCount, 0);

    session.seconds = 33;
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  testWidgets('pause cancels scheduled arrivals and resume reschedules them', (
    tester,
  ) async {
    final session = _Session(const [_future]);
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(_overlay(session, boundary));
    await _settleLayout(tester);
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
    await _settleLayout(tester);
  });

  for (final buffering in [false, true]) {
    for (final idle in [
      const Duration(milliseconds: 300),
      const Duration(seconds: 5),
    ]) {
      final reason = buffering ? 'buffering' : 'pause';
      testWidgets('$reason resumes continuously after a $idle frame gap', (
        tester,
      ) async {
        final session = _Session(const [_current]);
        addTearDown(session.dispose);
        final boundary = GlobalKey();
        await tester.pumpWidget(_overlay(session, boundary));
        await _settleLayout(tester);
        session.seconds = 30.1;
        await tester.pump(const Duration(milliseconds: 100));

        session.player.state = PlayerState(
          playing: buffering,
          buffering: buffering,
        );
        // Native playback can still report the preceding position at pause.
        session.seconds = 30;
        session.refresh(session.danmaku.comments);
        await tester.pump();
        final paused = await _pixels(tester, boundary);
        expect(_hasPaint(paused), isTrue);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);

        final pausedFrame = tester.binding.currentSystemFrameTimeStamp;
        await tester.pump(idle);
        expect(tester.binding.currentSystemFrameTimeStamp, pausedFrame);
        expect(tester.binding.transientCallbackCount, 0);

        session.player.state = const PlayerState(playing: true);
        session.refresh(session.danmaku.comments);
        await tester.pump();
        final resumed = await _pixels(tester, boundary);
        expect(
          listEquals(resumed, paused),
          isTrue,
          reason: 'The first resumed frame must not advance through idle time.',
        );
        expect(tester.binding.transientCallbackCount, greaterThan(0));

        session.seconds += .016;
        await tester.pump(const Duration(milliseconds: 16));
        expect(listEquals(await _pixels(tester, boundary), resumed), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settleLayout(tester);
      });
    }
  }

  testWidgets(
    'rapid pause and resume before a frame preserves comment position',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      await _settleLayout(tester);
      final before = await _pixels(tester, boundary);

      session.player.state = const PlayerState(playing: false);
      session.refresh(session.danmaku.comments);
      expect(tester.binding.transientCallbackCount, 0);
      // Advance fake time without allowing the requested pause repaint to run.
      await tester.binding.delayed(const Duration(milliseconds: 300));
      session.player.state = const PlayerState(playing: true);
      session.refresh(session.danmaku.comments);
      session.refresh(session.danmaku.comments);
      await tester.pump();
      expect(listEquals(await _pixels(tester, boundary), before), isTrue);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleLayout(tester);
    },
  );

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
    await _settleLayout(tester);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLayout(tester);
  });

  testWidgets(
    'scrolling frames reuse lane preparation and visible glyph layouts',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      await _settleLayout(tester);
      final state = tester.state(find.byType(DanmakuOverlay)) as dynamic;
      final preparations = state.debugLayoutWorker.completions as int;
      final glyphs = state.debugTextLayouts as int;
      expect(glyphs, 1);
      for (var i = 1; i <= 120; i++) {
        session.seconds = 30 + i / 120;
        session.position.value = Duration(
          microseconds: (session.seconds * 1000000).round(),
        );
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(state.debugLayoutWorker.completions, preparations);
      expect(state.debugTextLayouts, glyphs);
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background cancels pending layout without pumping or accepting late results',
    (tester) async {
      final source = List<DanmakuComment>.unmodifiable(
        List.generate(
          50000,
          (i) => DanmakuComment(i / 10, 'comment $i', 0xffffff, 0),
        ),
      );
      final session = _Session(source);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      final state = tester.state(find.byType(DanmakuOverlay)) as dynamic;
      final worker = state.debugLayoutWorker;
      expect(worker.pendingCount, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final completions = worker.completions;
      for (var i = 0; i < 20; i++) {
        session.position.value = Duration(milliseconds: 30000 + i);
        session.refresh(source);
      }
      // There is deliberately no pump after paused: only real isolate events
      // may finish, and those may neither restart work nor request a ticker.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(worker.pendingCount, 0);
      expect(worker.completions, completions);
      expect(worker.starts, 1);
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settleLayout(tester);
      expect(worker.starts, 2);
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
      await _settleLayout(tester);
      final before = await _pixels(tester, boundary);
      expect(_hasPaint(before), isTrue);

      session.refresh(entry.value);
      await tester.pump();
      final after = await _pixels(tester, boundary);
      expect(listEquals(after, before), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleLayout(tester);
    });
  }

  testWidgets(
    'an empty refresh keeps animating until the retained comment exits',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      await _settleLayout(tester);
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
      await _settleLayout(tester);
    },
  );

  testWidgets(
    'seeking rebuilds from the latest snapshot at the same position',
    (tester) async {
      final session = _Session(const [_current]);
      addTearDown(session.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(_overlay(session, boundary));
      await _settleLayout(tester);
      session.refresh(const []);
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);

      await session.seek(const Duration(seconds: 30));
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleLayout(tester);
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
      await _settleLayout(tester);
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
      await _settleLayout(tester);
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
      await _settleLayout(tester);
      previous.refresh(const []);
      await tester.pump();
      expect(_hasPaint(await _pixels(tester, boundary)), isTrue);
      expect(previous.listened, isTrue);

      await tester.pumpWidget(_overlay(next, boundary));
      await _settleLayout(tester);
      expect(_hasPaint(await _pixels(tester, boundary)), isFalse);
      expect(previous.listened, isFalse);
      expect(next.listened, isTrue);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settleLayout(tester);
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
  bool presentationActive = true;
  @override
  void setDanmakuPresentationActive(bool value) => presentationActive = value;

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
