import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/layout.dart';
import 'package:flutter_test/flutter_test.dart';

const current = DanmakuComment(29, 'current', 0xffffff, 0);
const historical = DanmakuComment(28, 'historical', 0xffffff, 0);

void main() {
  test('historical insertion cannot remove or move an on-screen comment', () {
    for (final lanes in [1, 2]) {
      final layout = DanmakuLayout();
      layout.update([current], lanes, now: 30, presetFilter: false);
      final before = layout.visibleAt(30).single;
      layout.update([historical, current], lanes, now: 30, presetFilter: false);
      final after = layout.visibleAt(30).single;
      expect(identical(after, before), isTrue);
      expect(after.comment, current);
      expect(after.lane, 0);
      expect(after.start, 29);
      expect(after.duration, 8);
    }
  });

  test(
    'deleted or edited visible content finishes with its original lifetime',
    () {
      for (final replacement in <List<DanmakuComment>>[
        [],
        [const DanmakuComment(29, 'edited', 0xff0000, 1)],
      ]) {
        final layout = DanmakuLayout();
        layout.update([current], 1, now: 30, presetFilter: false);
        layout.update(replacement, 1, now: 30, presetFilter: false);
        expect(layout.visibleAt(36.9).single.comment, current);
        expect(layout.visibleAt(37), isEmpty);
      }
    },
  );

  test(
    'refresh reserves occupied lanes and applies future additions and edits',
    () {
      final layout = DanmakuLayout();
      layout.update(
        [
          current,
          const DanmakuComment(38, 'deleted future', 0xffffff, 0),
          const DanmakuComment(46, 'old future', 0xffffff, 0),
        ],
        1,
        now: 30,
        presetFilter: false,
      );
      layout.update(
        [
          const DanmakuComment(31, 'would overlap', 0xffffff, 0),
          const DanmakuComment(37, 'new future', 0xffffff, 0),
          const DanmakuComment(46, 'edited future', 0xff0000, 0),
        ],
        1,
        now: 30,
        presetFilter: false,
      );
      expect(layout.visibleAt(31).single.comment, current);
      expect(layout.visibleAt(37).single.comment.text, 'new future');
      expect(layout.visibleAt(38).single.comment.text, 'new future');
      expect(layout.visibleAt(46).single.comment.text, 'edited future');
      expect(layout.visibleAt(46).single.comment.color, 0xff0000);
    },
  );

  test(
    'repeated refreshes preserve duplicates without repeating active items',
    () {
      final layout = DanmakuLayout();
      layout.update([current, current], 2, now: 30, presetFilter: false);
      final initial = layout.visibleAt(30).toList();
      expect(initial.map((item) => item.lane), [0, 1]);
      for (final now in [30.0, 31.0, 32.0]) {
        layout.update(
          [historical, current, current],
          2,
          now: now,
          presetFilter: false,
        );
        expect(layout.visibleAt(now).toList(), initial);
      }
      expect(layout.visibleAt(37), isEmpty);
    },
  );

  test(
    'refresh does not introduce past or current-time arrivals mid-flight',
    () {
      final layout = DanmakuLayout();
      layout.update([current], 3, now: 30, presetFilter: false);
      layout.update(
        [
          historical,
          current,
          const DanmakuComment(30, 'arrived late', 0xffffff, 0),
          const DanmakuComment(31, 'future', 0xffffff, 0),
        ],
        3,
        now: 30,
        presetFilter: false,
      );
      expect(layout.visibleAt(30).map((item) => item.comment.text), [
        'current',
      ]);
      expect(layout.visibleAt(31).map((item) => item.comment.text), [
        'current',
        'future',
      ]);
    },
  );

  test(
    'empty snapshot followed by recovery does not replay historical items',
    () {
      final layout = DanmakuLayout();
      layout.update([current], 2, now: 30, presetFilter: false);
      layout.update([], 2, now: 30, presetFilter: false);
      layout.update([historical, current], 2, now: 31, presetFilter: false);
      expect(layout.visibleAt(31).single.comment, current);
      expect(layout.visibleAt(37), isEmpty);
    },
  );

  test(
    'seek rebuilds from the latest snapshot including newly added history',
    () {
      final layout = DanmakuLayout();
      layout.update([current], 1, now: 30, contextKey: 0, presetFilter: false);
      final latest = [historical];
      layout.update(latest, 1, now: 30, contextKey: 0, presetFilter: false);
      expect(layout.visibleAt(30).single.comment, current);
      layout.update(latest, 1, now: 28.5, contextKey: 1, presetFilter: false);
      expect(layout.visibleAt(28.5).single.comment, historical);
      // Small forward seeks must also discard content removed by the service.
      layout.update([], 1, now: 29, contextKey: 1, presetFilter: false);
      layout.update([], 1, now: 29.1, contextKey: 2, presetFilter: false);
      expect(layout.visibleAt(29.1), isEmpty);
    },
  );

  test(
    'late native seek position restores history after an intervening refresh',
    () {
      final layout = DanmakuLayout();
      const early = DanmakuComment(8, 'early', 0xffffff, 0);
      final original = [early, current];
      layout.update(
        original,
        1,
        now: 30,
        position: const Duration(seconds: 30),
        contextKey: 0,
        presetFilter: false,
      );
      // The command revision is observed before the native position changes.
      layout.update(
        original,
        1,
        now: 30,
        position: const Duration(seconds: 30),
        contextKey: 1,
        presetFilter: false,
      );
      final latest = [early];
      layout.update(
        latest,
        1,
        now: 30,
        position: const Duration(seconds: 30),
        contextKey: 1,
        presetFilter: false,
      );
      expect(layout.visibleAt(30).single.comment, current);
      layout.update(
        latest,
        1,
        now: 10,
        position: const Duration(seconds: 10),
        contextKey: 1,
        presetFilter: false,
      );
      expect(layout.visibleAt(10).single.comment, early);
    },
  );

  test('episode changes do not carry over visible comments', () {
    final layout = DanmakuLayout();
    layout.update(
      [current],
      1,
      now: 30,
      contextKey: 'episode 1',
      presetFilter: false,
    );
    layout.update(
      [historical],
      1,
      now: 30,
      contextKey: 'episode 2',
      presetFilter: false,
    );
    expect(layout.visibleAt(30).single.comment, historical);
  });

  test('filter and speed changes apply immediately to retained comments', () {
    final layout = DanmakuLayout();
    final comments = [current];
    layout.update(comments, 1, now: 30, presetFilter: false);
    layout.update(
      comments,
      1,
      now: 30,
      presetFilter: false,
      blockedWords: 'current',
    );
    expect(layout.visibleAt(30), isEmpty);
    layout.update(comments, 1, now: 30, presetFilter: false, speed: 2);
    expect(layout.visibleAt(30).single.duration, 4);
    expect(layout.visibleAt(33), isEmpty);
  });

  test('top and bottom comments retain lanes and four-second lifetimes', () {
    final layout = DanmakuLayout();
    const comments = [
      DanmakuComment(29, 'top', 0xffffff, 1),
      DanmakuComment(29, 'bottom', 0xffffff, 2),
    ];
    layout.update(comments, 3, now: 30, presetFilter: false);
    final before = layout.visibleAt(30).toList();
    layout.update([], 3, now: 30, presetFilter: false);
    expect(layout.visibleAt(32.9).toList(), before);
    expect(before.map((item) => item.lane), [0, 2]);
    expect(layout.visibleAt(33), isEmpty);
  });

  test('small playback clock corrections keep the current layout', () {
    final layout = DanmakuLayout();
    layout.update(
      [current],
      1,
      now: 30,
      position: const Duration(milliseconds: 29900),
      presetFilter: false,
    );
    final latest = [historical, current];
    layout.update(
      latest,
      1,
      now: 30,
      position: const Duration(milliseconds: 29900),
      presetFilter: false,
    );
    final before = layout.visibleAt(30).single;
    layout.update(
      latest,
      1,
      now: 29.95,
      position: const Duration(milliseconds: 29950),
      presetFilter: false,
    );
    expect(identical(layout.visibleAt(29.95).single, before), isTrue);
  });
}
