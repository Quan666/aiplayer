import 'dart:async';

import 'package:aiplayer/playback/seek_timeline.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'release keeps the target through stale native position events',
    () async {
      final position = ValueNotifier(const Duration(seconds: 2));
      final commands = <Duration>[];
      final timeline = PlaybackSeekTimeline(
        position: position,
        seek: (value) async => commands.add(value),
      );
      timeline.begin(const Duration(seconds: 2));
      timeline.update(const Duration(seconds: 20));
      expect(timeline.displayed, const Duration(seconds: 20));
      expect(
        commands,
        isEmpty,
        reason: 'Previewing never seeks the main video',
      );
      timeline.finish();
      await Future<void>.value();
      expect(timeline.dragging, false);
      expect(commands, [const Duration(seconds: 20)]);
      position.value = const Duration(milliseconds: 2200);
      expect(timeline.displayed, const Duration(seconds: 20));
      position.value = const Duration(milliseconds: 19960);
      expect(timeline.target, isNull);
      expect(timeline.displayed, position.value);
      timeline.dispose();
      position.dispose();
    },
  );

  test('pointer-up, slider-end and late cancel consume one seek only', () {
    final position = ValueNotifier(Duration.zero);
    final commands = <Duration>[];
    final timeline = PlaybackSeekTimeline(
      position: position,
      seek: (value) async => commands.add(value),
    );
    timeline.begin(const Duration(seconds: 15));
    timeline.finish();
    timeline.finish();
    timeline.finish(commit: false);
    expect(commands, [const Duration(seconds: 15)]);
    expect(timeline.displayed, const Duration(seconds: 15));
    timeline.dispose();
    position.dispose();
  });

  test('cancel restores playback position and ignores late drag callbacks', () {
    final position = ValueNotifier(const Duration(seconds: 4));
    final commands = <Duration>[];
    final timeline = PlaybackSeekTimeline(
      position: position,
      seek: (value) async => commands.add(value),
    );
    timeline.begin(const Duration(seconds: 18));
    position.value = const Duration(seconds: 5);
    timeline.finish(commit: false);
    timeline.update(const Duration(seconds: 19));
    timeline.finish();
    expect(timeline.dragging, false);
    expect(timeline.target, isNull);
    expect(timeline.displayed, const Duration(seconds: 5));
    expect(commands, isEmpty);
    timeline.dispose();
    position.dispose();
  });

  test('an old failed seek cannot discard a newer target', () async {
    final position = ValueNotifier(Duration.zero);
    final first = Completer<void>();
    final second = Completer<void>();
    var commands = 0;
    final timeline = PlaybackSeekTimeline(
      position: position,
      seek: (_) => ++commands == 1 ? first.future : second.future,
    );
    timeline.begin(const Duration(seconds: 10));
    timeline.finish();
    timeline.begin(const Duration(seconds: 24));
    timeline.finish();
    first.completeError(StateError('old request'));
    await Future<void>.value();
    expect(timeline.displayed, const Duration(seconds: 24));
    second.completeError(StateError('current request'));
    await Future<void>.value();
    expect(timeline.target, isNull);
    expect(timeline.displayed, Duration.zero);
    timeline.dispose();
    position.dispose();
  });

  test('a disconnected decoder expires safely and disposal cancels timers', () {
    fakeAsync((async) {
      final position = ValueNotifier(Duration.zero);
      final timeline = PlaybackSeekTimeline(
        position: position,
        seek: (_) async {},
      );
      timeline.begin(const Duration(seconds: 9));
      timeline.finish();
      async.elapse(const Duration(seconds: 9));
      expect(timeline.displayed, const Duration(seconds: 9));
      async.elapse(const Duration(seconds: 1));
      expect(timeline.target, isNull);
      timeline.begin(const Duration(seconds: 12));
      timeline.finish();
      timeline.dispose();
      position.value = const Duration(seconds: 12);
      expect(async.nonPeriodicTimerCount, 0);
      position.dispose();
    });
  });
}
