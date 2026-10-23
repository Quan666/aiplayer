import 'dart:async';

import 'package:aiplayer/playback/checkpoints.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playing records progress every ten seconds without taking frames', () {
    fakeAsync((clock) {
      var playing = true, saves = 0, captures = 0;
      final checkpoints = PlaybackCheckpoints(
        isPlaying: () => playing,
        saveProgress: () => saves++,
        capturePreview: () async => captures++,
        onError: (error) => fail('$error'),
      )..start();
      clock.elapse(const Duration(seconds: 9));
      expect(saves, 0);
      clock.elapse(const Duration(seconds: 1));
      expect(saves, 1);
      clock.elapse(const Duration(seconds: 80));
      expect(saves, 9);
      expect(captures, 0);
      playing = false;
      clock.elapse(const Duration(seconds: 30));
      expect(saves, 9);
      checkpoints.stop();
    });
  });

  test(
    'pause and background events coalesce and capture the latest position',
    () {
      fakeAsync((clock) {
        var position = 1;
        final saved = <int>[], captured = <int>[];
        final checkpoints = PlaybackCheckpoints(
          isPlaying: () => false,
          saveProgress: () => saved.add(position),
          capturePreview: () async => captured.add(position),
          onError: (error) => fail('$error'),
        );
        for (; position < 100; position++) {
          checkpoints.checkpoint();
        }
        expect(saved, isEmpty);
        expect(captured, isEmpty);
        clock.elapse(PlaybackCheckpoints.eventDelay);
        expect(saved, [100]);
        expect(captured, [100]);
        checkpoints.stop();
      });
    },
  );

  test(
    'events during native capture save progress without overlapping frames',
    () {
      fakeAsync((clock) {
        var position = 1;
        final frames = <int>[], saved = <int>[];
        final capturing = Completer<void>();
        final checkpoints = PlaybackCheckpoints(
          isPlaying: () => false,
          saveProgress: () => saved.add(position),
          capturePreview: () {
            frames.add(position);
            return frames.length == 1 ? capturing.future : Future.value();
          },
          onError: (error) => fail('$error'),
        );
        checkpoints.checkpoint();
        clock.elapse(PlaybackCheckpoints.eventDelay);
        position = 2;
        checkpoints.checkpoint();
        clock.elapse(PlaybackCheckpoints.eventDelay);
        position = 3;
        checkpoints.checkpoint();
        clock.elapse(PlaybackCheckpoints.eventDelay);
        expect(frames, [1]);
        expect(saved, [1, 2, 3]);
        capturing.complete();
        clock.flushMicrotasks();
        clock.elapse(PlaybackCheckpoints.eventDelay);
        expect(frames, [1, 3]);
        checkpoints.stop();
      });
    },
  );

  test('close flushes a pending event and cancels every timer', () {
    fakeAsync((clock) {
      var saves = 0, captures = 0;
      final checkpoints = PlaybackCheckpoints(
        isPlaying: () => true,
        saveProgress: () => saves++,
        capturePreview: () async => captures++,
        onError: (error) => fail('$error'),
      )..start();
      checkpoints.checkpoint();
      final first = checkpoints.close();
      expect(identical(first, checkpoints.close()), isTrue);
      clock.flushMicrotasks();
      expect(captures, 1);
      final finalSaves = saves;
      clock.elapse(const Duration(minutes: 1));
      checkpoints.checkpoint();
      clock.elapse(PlaybackCheckpoints.eventDelay);
      expect(saves, finalSaves);
      expect(captures, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('slow periodic writes do not block timers and close waits for each', () {
    fakeAsync((clock) {
      final pending = <Completer<void>>[];
      var captures = 0;
      final checkpoints = PlaybackCheckpoints(
        isPlaying: () => true,
        saveProgress: () {
          final write = Completer<void>();
          pending.add(write);
          return write.future;
        },
        capturePreview: () async => captures++,
        onError: (error) => fail('$error'),
      )..start();
      clock.elapse(const Duration(seconds: 30));
      expect(pending, hasLength(3));
      expect(captures, 0);

      var closed = false;
      checkpoints.close().then((_) => closed = true);
      clock.flushMicrotasks();
      expect(captures, 1);
      for (final write in pending.skip(1)) {
        write.complete();
      }
      clock.flushMicrotasks();
      expect(closed, isFalse);
      pending.first.complete();
      clock.flushMicrotasks();
      expect(closed, isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'asynchronous persistence errors are reported and later saves continue',
    () {
      fakeAsync((clock) {
        final first = Completer<void>();
        final errors = <Object>[];
        var saves = 0;
        final checkpoints = PlaybackCheckpoints(
          isPlaying: () => true,
          saveProgress: () {
            saves++;
            if (saves == 1) return first.future;
          },
          capturePreview: () async {},
          onError: errors.add,
        )..start();
        clock.elapse(PlaybackCheckpoints.interval);
        final failure = StateError('Disk unavailable');
        first.completeError(failure);
        clock.flushMicrotasks();
        expect(errors, [failure]);
        clock.elapse(PlaybackCheckpoints.interval);
        expect(saves, 2);
        var closed = false;
        checkpoints.close().then((_) => closed = true);
        clock.flushMicrotasks();
        expect(closed, isTrue);
        expect(errors, [failure]);
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );
}
