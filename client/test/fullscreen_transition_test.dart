import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:aiplayer/playback/fullscreen_transition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop background never pauses; mobile honors PiP and preference', () {
    for (final backgrounded in [false, true]) {
      for (final pauseOnBackground in [false, true]) {
        for (final pictureInPicture in [false, true]) {
          expect(
            playbackShouldPauseInBackground(
              mobile: false,
              backgrounded: backgrounded,
              pauseOnBackground: pauseOnBackground,
              pictureInPicture: pictureInPicture,
            ),
            isFalse,
          );
          expect(
            playbackShouldPauseInBackground(
              mobile: true,
              backgrounded: backgrounded,
              pauseOnBackground: pauseOnBackground,
              pictureInPicture: pictureInPicture,
            ),
            backgrounded && pauseOnBackground && !pictureInPicture,
          );
        }
      }
    }
  });

  test('fullscreen entry, exit, and reentry cannot overlap', () async {
    final transitions = FullscreenTransition();
    final entry = Completer<void>();
    final exit = Completer<void>();
    final events = <String>[];

    final entering = transitions.run(() async {
      events.add('enter started');
      await entry.future;
      events.add('enter finished');
    });
    final exiting = transitions.run(() async {
      events.add('exit started');
      await exit.future;
      events.add('exit finished');
    });
    final reentering = transitions.run(() async {
      events.add('reenter');
    });
    final idle = transitions.idle;

    expect(transitions.isTransitioning, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['enter started']);

    entry.complete();
    await entering;
    await Future<void>.delayed(Duration.zero);
    expect(events, ['enter started', 'enter finished', 'exit started']);
    expect(transitions.isTransitioning, isTrue);

    exit.complete();
    await Future.wait([exiting, reentering, idle]);
    expect(events, [
      'enter started',
      'enter finished',
      'exit started',
      'exit finished',
      'reenter',
    ]);
    expect(transitions.isTransitioning, isFalse);
  });

  test('native failure reaches its caller without blocking cleanup', () async {
    final transitions = FullscreenTransition();
    final native = Completer<void>();
    var restored = false;

    final entering = transitions.run(() => native.future);
    final failure = expectLater(entering, throwsStateError);
    final exiting = transitions.run(() async {
      restored = true;
    });

    native.completeError(StateError('Native entry failed'));
    await failure;
    await exiting;
    await transitions.idle;
    expect(restored, isTrue);
    expect(transitions.isTransitioning, isFalse);
  });

  test('synchronous platform failure also releases the queue', () async {
    final transitions = FullscreenTransition();
    final failed = transitions.run(() => throw StateError('Unavailable'));
    await expectLater(failed, throwsStateError);
    await transitions.idle;
    expect(transitions.isTransitioning, isFalse);

    var called = false;
    await transitions.run(() async {
      called = true;
    });
    expect(called, isTrue);
  });

  test('only hidden, paused, and detached are playback background states', () {
    for (final state in [
      null,
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
    ]) {
      expect(playbackIsBackgrounded(state), isFalse, reason: '$state');
    }
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(playbackIsBackgrounded(state), isTrue, reason: '$state');
    }
  });

  test(
    'focus changes preserve playback and respect a pause while switching',
    () async {
      for (final initiallyPlaying in [true, false]) {
        final transitions = FullscreenTransition();
        final native = Completer<void>();
        var playing = initiallyPlaying;
        void lifecycle(AppLifecycleState state) {
          if (playbackIsBackgrounded(state)) playing = false;
        }

        final entering = transitions.run(() async {
          lifecycle(AppLifecycleState.inactive);
          await native.future;
          lifecycle(AppLifecycleState.resumed);
        });
        await Future<void>.delayed(Duration.zero);
        expect(playing, initiallyPlaying);
        playing = false; // Explicit pause while native entry is still pending.
        native.complete();
        await entering;
        expect(playing, isFalse);
      }
    },
  );

  test(
    'real backgrounding still pauses during a fullscreen transition',
    () async {
      final transitions = FullscreenTransition();
      final native = Completer<void>();
      var playing = true;
      final entering = transitions.run(() => native.future);

      expect(transitions.isTransitioning, isTrue);
      if (playbackIsBackgrounded(AppLifecycleState.hidden)) playing = false;
      native.complete();
      await entering;
      expect(playing, isFalse);
    },
  );
}
