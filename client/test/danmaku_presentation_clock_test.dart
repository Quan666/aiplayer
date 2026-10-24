import 'package:aiplayer/danmaku/presentation_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('late position corrections cannot reverse scrolling text', () {
    final clock = DanmakuPresentationClock();
    var previous = clock.sample(
      position: 30,
      elapsed: Duration.zero,
      playing: true,
      rate: 1,
      contextKey: 0,
    );
    for (var milliseconds = 10; milliseconds <= 1000; milliseconds += 10) {
      // Native events alternate between 80 ms and 120 ms behind. Their raw
      // interpolation repeatedly goes backwards, despite forward playback.
      final lag = (milliseconds ~/ 100).isEven ? .08 : .12;
      final next = clock.sample(
        position: 30 + milliseconds / 1000 - lag,
        elapsed: Duration(milliseconds: milliseconds),
        playing: true,
        rate: 1,
        contextKey: 0,
      );
      expect(next - previous, inInclusiveRange(.009 - 1e-12, .011 + 1e-12));
      previous = next;
    }
    expect(previous, closeTo(30.9, .025));
  });

  test(
    'small corrections converge without depending on display refresh rate',
    () {
      double follow(int frameMicroseconds) {
        final clock = DanmakuPresentationClock();
        clock.sample(
          position: 10,
          elapsed: Duration.zero,
          playing: true,
          rate: 1,
          contextKey: 0,
        );
        var value = 10.0;
        for (var micros = frameMicroseconds; micros <= 1000000;) {
          value = clock.sample(
            position: 10 + micros / 1000000 + .05,
            elapsed: Duration(microseconds: micros),
            playing: true,
            rate: 1,
            contextKey: 0,
          );
          if (micros == 1000000) break;
          micros = (micros + frameMicroseconds).clamp(0, 1000000);
        }
        return value;
      }

      expect(follow(16667), closeTo(11.05, 1e-9));
      expect(follow(8333), closeTo(11.05, 1e-9));
    },
  );

  for (final reason in ['paused', 'buffering']) {
    test(
      '$reason freezes the last painted motion and resumes continuously',
      () {
        final clock = DanmakuPresentationClock();
        double sample(int milliseconds, double position, bool playing) =>
            clock.sample(
              position: position,
              elapsed: Duration(milliseconds: milliseconds),
              playing: playing,
              rate: 1,
              contextKey: 0,
            );
        expect(sample(0, 30, true), 30);
        expect(sample(100, 30.1, true), closeTo(30.1, 1e-9));
        expect(sample(150, 30.1, false), closeTo(30.15, 1e-9));
        expect(sample(5150, 30.1, false), closeTo(30.15, 1e-9));
        expect(sample(10150, 30.1, true), closeTo(30.15, 1e-9));
        expect(sample(10160, 30.11, true), closeTo(30.159, 1e-9));
      },
    );
  }

  test('rate changes preserve position and use the new playback rate', () {
    final clock = DanmakuPresentationClock();
    double sample(int milliseconds, double position, double rate) =>
        clock.sample(
          position: position,
          elapsed: Duration(milliseconds: milliseconds),
          playing: true,
          rate: rate,
          contextKey: 0,
        );
    sample(0, 10, 1);
    expect(sample(100, 10.1, 2), closeTo(10.1, 1e-9));
    expect(sample(200, 10.3, .5), closeTo(10.3, 1e-9));
    expect(sample(300, 10.35, .5), closeTo(10.35, 1e-9));
  });

  test(
    'seek and timing changes apply even a small backwards jump immediately',
    () {
      final clock = DanmakuPresentationClock();
      clock.sample(
        position: 30,
        elapsed: Duration.zero,
        playing: true,
        rate: 1,
        contextKey: ('episode', 0),
      );
      expect(
        clock.sample(
          position: 29.9,
          elapsed: const Duration(milliseconds: 10),
          playing: true,
          rate: 1,
          contextKey: ('episode', 1),
        ),
        29.9,
      );
    },
  );

  test(
    'late seek positions and large buffering changes immediately reanchor',
    () {
      final clock = DanmakuPresentationClock();
      double sample(int milliseconds, double position, bool playing) =>
          clock.sample(
            position: position,
            elapsed: Duration(milliseconds: milliseconds),
            playing: playing,
            rate: 1,
            contextKey: 0,
          );
      sample(0, 30, true);
      expect(sample(10, 10, true), 10);
      expect(sample(20, 10.01, false), closeTo(10.01, 1e-9));
      expect(sample(5020, 12, false), 12);
      expect(sample(5030, 12, true), 12);
    },
  );

  for (final target in [29.9, 30.1]) {
    test(
      'small seek to $target accepts a target after an older native event',
      () {
        final clock = DanmakuPresentationClock();
        double sample(int elapsed, double position, int native, int revision) =>
            clock.sample(
              position: position,
              elapsed: Duration(milliseconds: elapsed),
              playing: true,
              rate: 1,
              contextKey: ('episode', revision),
              timelineRevision: revision,
              nativePosition: Duration(milliseconds: native),
            );
        sample(0, 30, 30000, 0);
        // The command notification still contains the pre-seek native anchor.
        expect(sample(10, 30.01, 30000, 1), 30.01);
        expect(sample(20, 30.02, 30020, 1), 30.02);
        expect(sample(30, target, (target * 1000).round(), 1), target);
        // The settlement window is bounded and never needs a polling timer.
        // A later ordinary correction must again be smoothed, not snapped.
        final next = sample(
          530,
          target + .4,
          ((target + .4) * 1000).round(),
          1,
        );
        expect(next, closeTo(target + .45, 1e-9));
      },
    );
  }

  test('visibility reset uses the latest position after a long idle gap', () {
    final clock = DanmakuPresentationClock();
    clock.sample(
      position: 30,
      elapsed: Duration.zero,
      playing: true,
      rate: 1,
      contextKey: 0,
    );
    clock.reset();
    expect(
      clock.sample(
        position: 30.2,
        elapsed: const Duration(seconds: 20),
        playing: false,
        rate: 1,
        contextKey: 0,
      ),
      30.2,
    );
  });

  test('same-time repaints do not advance or apply corrections twice', () {
    final clock = DanmakuPresentationClock();
    for (var i = 0; i < 10; i++) {
      expect(
        clock.sample(
          position: 30 + i / 100,
          elapsed: Duration.zero,
          playing: true,
          rate: 1,
          contextKey: 0,
        ),
        30,
      );
    }
  });
}
