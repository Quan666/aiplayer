import 'dart:async';
import 'dart:isolate';

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/layout.dart';
import 'package:aiplayer/danmaku/layout_worker.dart';
import 'package:flutter_test/flutter_test.dart';

const _current = DanmakuComment(29, 'current', 0xffffff, 0);
const _options = DanmakuLayoutOptions(count: 3, presetFilter: false);

void main() {
  test(
    'rapid cancel and resume keeps only one isolate spawn in flight',
    () async {
      final worker = DanmakuLayoutWorker();
      addTearDown(worker.dispose);
      final cancelled = <Future<List<DanmakuPlacement>?>>[];
      for (var i = 0; i < 40; i++) {
        cancelled.add(worker.prepare(const [_current], _options));
        worker.cancel();
        expect(worker.pendingCount, 0);
      }
      final latest = worker.prepare(const [_current], _options);
      expect(worker.starts, 1);
      expect(worker.pendingCount, 1);
      expect(await Future.wait(cancelled), everyElement(isNull));
      expect(await latest, hasLength(1));
      expect(worker.starts, 2);
      expect(worker.sourceTransfers, 1);
      expect(worker.pendingCount, 0);
    },
  );

  test(
    'large preparation runs outside the UI and leaves its event loop free',
    () async {
      final worker = DanmakuLayoutWorker();
      addTearDown(worker.dispose);
      final source = List<DanmakuComment>.unmodifiable(
        List.generate(
          120000,
          (i) => DanmakuComment(i / 10, '弹幕测试 $i', 0xffffff, 0),
        ),
      );
      var wakeups = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => wakeups++,
      );
      final result = await worker.prepare(
        source,
        const DanmakuLayoutOptions(count: 12),
      );
      heartbeat.cancel();
      expect(result, isNotEmpty);
      expect(worker.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(wakeups, greaterThan(0));
      expect(worker.starts, 1);
      expect(() => result!.clear(), throwsUnsupportedError);
    },
  );

  test(
    'one active request and only the latest queued request reuse the source',
    () async {
      final worker = DanmakuLayoutWorker();
      addTearDown(worker.dispose);
      final source = List<DanmakuComment>.unmodifiable(
        List.generate(
          40000,
          (i) => DanmakuComment(i / 10, 'comment $i', 0xffffff, 0),
        ),
      );
      await worker.prepare(source, _options);
      final active = worker.prepare(source, _options);
      final queued = <Future<List<DanmakuPlacement>?>>[];
      for (var i = 0; i < 30; i++) {
        queued.add(worker.prepare(source, DanmakuLayoutOptions(count: i + 1)));
        expect(worker.pendingCount, 2);
      }
      await active;
      final results = await Future.wait(queued);
      expect(results.take(29), everyElement(isNull));
      expect(results.last, isNotEmpty);
      expect(worker.starts, 1);
      expect(worker.completions, 3);
      expect(worker.sourceTransfers, 1);
      expect(worker.pendingCount, 0);
    },
  );

  test(
    'a refresh keeps original visible objects and applies future edits',
    () async {
      var notifications = 0;
      final layout = AsyncDanmakuLayout(() => notifications++);
      addTearDown(layout.dispose);
      void update(List<DanmakuComment> source, {int revision = 0}) =>
          layout.update(
            source,
            _options,
            now: 30,
            position: const Duration(seconds: 30),
            contextKey: revision,
          );
      update(const [_current]);
      await layout.ready;
      final original = layout.schedule.visibleAt(30).single;
      update(const [
        DanmakuComment(28, 'late historical', 0xffffff, 0),
        DanmakuComment(40, 'future edit', 0xffffff, 0),
      ]);
      expect(identical(layout.schedule.visibleAt(30).single, original), isTrue);
      await layout.ready;
      expect(identical(layout.schedule.visibleAt(30).single, original), isTrue);
      expect(layout.schedule.visibleAt(40).single.comment.text, 'future edit');
      expect(notifications, 2);
      update(const [
        DanmakuComment(28, 'late historical', 0xffffff, 0),
        DanmakuComment(40, 'future edit', 0xffffff, 0),
      ], revision: 1);
      expect(layout.schedule.visibleAt(30), isEmpty);
      await layout.ready;
      expect(
        layout.schedule.visibleAt(30).single.comment.text,
        'late historical',
      );
    },
  );

  test(
    'suspending cancels startup and queued work without applying late results',
    () async {
      var notifications = 0;
      final layout = AsyncDanmakuLayout(() => notifications++);
      addTearDown(layout.dispose);
      final source = List<DanmakuComment>.unmodifiable(
        List.generate(
          50000,
          (i) => DanmakuComment(i / 10, 'comment $i', 0xffffff, 0),
        ),
      );
      void update() => layout.update(
        source,
        _options,
        now: 30,
        position: const Duration(seconds: 30),
        contextKey: 0,
      );
      update();
      final cancelled = layout.ready;
      layout.setSuspended(true);
      expect(layout.worker.pendingCount, 0);
      await cancelled;
      update();
      expect(layout.worker.starts, 1);
      expect(notifications, 0);
      layout.setSuspended(false);
      update();
      await layout.ready;
      expect(layout.worker.starts, 2);
      expect(notifications, 1);
      expect(layout.schedule.visibleAt(30), isNotEmpty);
    },
  );

  test(
    'seeks, settings, episode replacement and disposal reject stale results',
    () async {
      var notifications = 0;
      final layout = AsyncDanmakuLayout(() => notifications++);
      addTearDown(layout.dispose);
      const source = [_current];
      void update({
        int revision = 0,
        DanmakuLayoutOptions options = _options,
      }) => layout.update(
        source,
        options,
        now: 30,
        position: const Duration(seconds: 30),
        contextKey: revision,
      );
      update();
      update(revision: 1);
      update(
        revision: 2,
        options: const DanmakuLayoutOptions(count: 1, blockedWords: 'current'),
      );
      await layout.ready;
      expect(layout.schedule.visibleAt(30), isEmpty);
      expect(notifications, 1);
      update(revision: 3);
      final pending = layout.ready;
      layout.dispose();
      await pending;
      expect(notifications, 1);
      expect(layout.worker.pendingCount, 0);
      expect(layout.schedule.visibleAt(30), isEmpty);
    },
  );

  test('unchanged native positions never enqueue preparation', () async {
    var notifications = 0;
    final layout = AsyncDanmakuLayout(() => notifications++);
    addTearDown(layout.dispose);
    const source = [_current];
    for (var i = 0; i < 200; i++) {
      layout.update(
        source,
        _options,
        now: 30 + i / 100,
        position: Duration(milliseconds: 30000 + i * 10),
        contextKey: 0,
      );
      await layout.ready;
    }
    expect(layout.worker.completions, 1);
    expect(layout.worker.sourceTransfers, 1);
    expect(notifications, 1);
  });

  test(
    'an interrupted refresh keeps its cutoff when resuming the same snapshot',
    () async {
      final layout = AsyncDanmakuLayout(() {});
      addTearDown(layout.dispose);
      void update(
        List<DanmakuComment> source,
        double now, {
        DanmakuLayoutOptions options = _options,
      }) => layout.update(
        source,
        options,
        now: now,
        position: Duration(milliseconds: (now * 1000).round()),
        contextKey: 0,
      );
      update(const [_current], 30);
      await layout.ready;
      final original = layout.schedule.visibleAt(30).single;
      const refreshed = [
        _current,
        DanmakuComment(35, 'arrived while hidden', 0xffffff, 0),
      ];
      update(refreshed, 31);
      final cancelled = layout.ready;
      layout.setSuspended(true);
      await cancelled;
      layout.setSuspended(false);
      update(refreshed, 36);
      await layout.ready;
      final visible = layout.schedule.visibleAt(36).toList();
      expect(visible.map((item) => item.comment.text), [
        'current',
        'arrived while hidden',
      ]);
      expect(identical(visible.first, original), isTrue);
    },
  );

  for (final changeSource in [true, false]) {
    test(
      'an interrupted refresh discards its checkpoint after ${changeSource ? 'source' : 'configuration'} changes',
      () async {
        final layout = AsyncDanmakuLayout(() {});
        addTearDown(layout.dispose);
        void update(
          List<DanmakuComment> source,
          double now, {
          DanmakuLayoutOptions options = _options,
        }) => layout.update(
          source,
          options,
          now: now,
          position: Duration(milliseconds: (now * 1000).round()),
          contextKey: 0,
        );
        update(const [_current], 30);
        await layout.ready;
        const refreshed = [DanmakuComment(29, 'replacement', 0xffffff, 0)];
        update(refreshed, 31);
        final cancelled = layout.ready;
        layout.setSuspended(true);
        await cancelled;
        layout.setSuspended(false);
        update(
          changeSource
              ? const [DanmakuComment(30, 'latest', 0xffffff, 0)]
              : refreshed,
          32,
          options: changeSource
              ? _options
              : const DanmakuLayoutOptions(count: 2, presetFilter: false),
        );
        await layout.ready;
        expect(
          layout.schedule.visibleAt(32).single.comment.text,
          changeSource ? 'latest' : 'replacement',
        );
      },
    );
  }

  test(
    'normalized source snapshots cannot be mutated behind their revision',
    () {
      final source = normalizeComments([
        {'time': 1, 'text': 'hello', 'color': 0xffffff, 'mode': 0},
      ]);
      expect(() => source.clear(), throwsUnsupportedError);
    },
  );
}
