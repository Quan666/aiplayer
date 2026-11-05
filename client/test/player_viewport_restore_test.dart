import 'dart:async';

import 'package:aiplayer/playback/display.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('native acknowledgement waits for the destination viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    tester.view.physicalSize = const Size(800, 400);
    final native = Completer<void>();
    var visible = false;
    final leaving = viewport.restore(() => native.future).then((_) {
      visible = true;
    });
    native.complete();
    await tester.idle();
    expect(visible, isFalse);

    // Insets can change before the actual rotation. A metrics event by itself
    // must not expose the destination in the video's landscape viewport.
    tester.view.physicalSize = const Size(780, 400);
    await tester.idle();
    expect(visible, isFalse);
    tester.view.physicalSize = const Size(400, 800);
    await leaving;
    expect(visible, isTrue);
  });

  testWidgets(
    'a landscape destination is preserved instead of forced upright',
    (tester) async {
      tester.view.physicalSize = const Size(800, 400);
      addTearDown(tester.view.resetPhysicalSize);
      final viewport = PlayerViewportRestore(tester.view);
      addTearDown(viewport.dispose);
      tester.view.physicalSize = const Size(400, 800);
      var visible = false;
      final leaving = viewport.restore(() async {}).then((_) => visible = true);
      await tester.idle();
      expect(visible, isFalse);
      tester.view.physicalSize = const Size(800, 400);
      await leaving;
      expect(visible, isTrue);
    },
  );

  testWidgets('matching viewport does not delay navigation or leave a timer', (
    tester,
  ) async {
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    var requests = 0;
    await viewport.restore(() async => requests++);
    await viewport.restore(() async => requests++);
    expect(requests, 2);
  });

  testWidgets(
    'rotation declined by the system has a bounded event-driven wait',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      final viewport = PlayerViewportRestore(tester.view);
      addTearDown(viewport.dispose);
      tester.view.physicalSize = const Size(800, 400);
      var visible = false;
      final leaving = viewport.restore(() async {}).then((_) => visible = true);
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 749));
      expect(visible, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      await leaving;
      expect(visible, isTrue);
    },
  );

  testWidgets(
    'paused ends the wait without a pump and resume cannot restart it',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      final viewport = PlayerViewportRestore(tester.view);
      addTearDown(viewport.dispose);
      tester.view.physicalSize = const Size(800, 400);
      var requests = 0, completions = 0;
      final leaving = viewport
          .restore(() async => requests++)
          .then((_) => completions++);
      await tester.idle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.idle();
      expect(completions, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Deliberately do not pump a frame after pausing.
      await leaving;
      expect(completions, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(400, 800);
      await tester.idle();
      expect(requests, 1);
      expect(completions, 1);
    },
  );

  testWidgets(
    'an initially backgrounded app does not wait for an absent frame',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      final viewport = PlayerViewportRestore(tester.view);
      addTearDown(viewport.dispose);
      tester.view.physicalSize = const Size(800, 400);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await viewport.restore(() async {});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  testWidgets(
    'disposal releases the wait and rejects late restoration requests',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      final viewport = PlayerViewportRestore(tester.view);
      tester.view.physicalSize = const Size(800, 400);
      var requests = 0;
      final leaving = viewport.restore(() async => requests++);
      await tester.idle();
      viewport.dispose();
      await leaving;
      await viewport.restore(() async => requests++);
      expect(requests, 1);
    },
  );

  testWidgets('a failed native request releases its observer before retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    tester.view.physicalSize = const Size(800, 400);
    await expectLater(
      viewport.restore(() async => throw StateError('Unavailable')),
      throwsStateError,
    );
    tester.view.physicalSize = const Size(400, 800);
    await viewport.restore(() async {});
  });

  testWidgets('a pending native reply cannot outlive the total deadline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    tester.view.physicalSize = const Size(800, 400);
    final native = Completer<void>();
    var visible = false;
    final leaving = viewport.restore(() => native.future).then((_) {
      visible = true;
    });
    await tester.pump(const Duration(milliseconds: 750));
    await leaving;
    expect(visible, isTrue);
    native.completeError(StateError('Late platform failure'));
    await tester.idle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause releases a pending reply directly without another frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    tester.view.physicalSize = const Size(800, 400);
    final native = Completer<void>();
    final leaving = viewport.restore(() => native.future);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Intentionally no pump and no native reply after backgrounding.
    await leaving;
    native.completeError(StateError('Late platform failure'));
    await tester.idle();
    expect(tester.takeException(), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a late native failure cannot release a later attempt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    final viewport = PlayerViewportRestore(tester.view);
    addTearDown(viewport.dispose);
    tester.view.physicalSize = const Size(800, 400);
    final firstNative = Completer<void>(), secondNative = Completer<void>();
    final first = viewport.restore(() => firstNative.future);
    await tester.pump(const Duration(milliseconds: 750));
    await first;
    var visible = false;
    final second = viewport.restore(() => secondNative.future).then((_) {
      visible = true;
    });
    firstNative.completeError(StateError('Late first platform failure'));
    await tester.idle();
    expect(visible, isFalse);
    secondNative.complete();
    await tester.idle();
    expect(visible, isFalse);
    tester.view.physicalSize = const Size(400, 800);
    await second;
    expect(visible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposal releases a pending reply and absorbs its late failure',
    (tester) async {
      final viewport = PlayerViewportRestore(tester.view);
      final native = Completer<void>();
      final leaving = viewport.restore(() => native.future);
      viewport.dispose();
      await leaving;
      native.completeError(StateError('Late platform failure'));
      await tester.idle();
      expect(tester.takeException(), isNull);
    },
  );
}
