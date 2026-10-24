import 'api.dart';
import 'filter.dart';

class ScheduledComment {
  // Keep the original content when a refresh removes or edits a visible item.
  final DanmakuComment comment;
  // index refers to the snapshot that originally scheduled this comment.
  final int index, lane;
  final double start, duration;
  const ScheduledComment(
    this.comment,
    this.index,
    this.lane,
    this.start,
    this.duration,
  );
}

/// Allocate deterministically for a snapshot and viewport.
/// A lane is reserved until the previous comment exits, avoiding catch-up collisions.
List<ScheduledComment> assignLanes(
  List<DanmakuComment> comments,
  int count, {
  double speed = 1,
  bool scroll = true,
  bool top = true,
  bool bottom = true,
  bool presetFilter = true,
  String blockedWords = '',
  double? after,
  List<ScheduledComment> retained = const [],
}) {
  if (count < 1) return [];
  final words = blockedWords
      .split(RegExp(r'[,，\n]'))
      .map((v) => v.trim().toLowerCase())
      .where((v) => v.isNotEmpty)
      .toList();
  final velocity = speed.clamp(.25, 4.0);
  final available = List<double>.filled(count, double.negativeInfinity),
      result = [...retained];
  for (final item in retained) {
    available[item.lane] = item.start + item.duration;
  }
  for (var i = 0; i < comments.length; i++) {
    final c = comments[i];
    if ((after != null && c.time <= after) ||
        (c.mode == 0 && !scroll) ||
        (c.mode == 1 && !top) ||
        (c.mode == 2 && !bottom) ||
        (presetFilter && matchesDanmakuPreset(c.text)) ||
        words.any((word) => c.text.toLowerCase().contains(word))) {
      continue;
    }
    var lane = -1;
    for (var j = 0; j < count; j++) {
      final candidate = c.mode == 2 ? count - 1 - j : j;
      if (available[candidate] <= c.time) {
        lane = candidate;
        break;
      }
    }
    if (lane < 0) continue;
    final duration = (c.mode == 0 ? 8.0 : 4.0) / velocity;
    available[lane] = c.time + duration;
    result.add(ScheduledComment(c, i, lane, c.time, duration));
  }
  return result;
}

/// A refresh only changes future arrivals. Already visible comments finish on
/// their original lanes, even if the new snapshot edits or deletes them.
class DanmakuLayout {
  List<DanmakuComment>? _source;
  Object? _configuration;
  Duration? _position;
  DanmakuSchedule _schedule = const DanmakuSchedule.empty();

  void clear() {
    _source = null;
    _configuration = null;
    _position = null;
    _schedule = const DanmakuSchedule.empty();
  }

  void update(
    List<DanmakuComment> comments,
    int count, {
    required double now,
    Duration? position,
    // Change this key after seeking, switching episodes, or changing timing.
    Object? contextKey,
    double speed = 1,
    bool scroll = true,
    bool top = true,
    bool bottom = true,
    bool presetFilter = true,
    String blockedWords = '',
  }) {
    final configuration = (
      contextKey,
      count,
      speed,
      scroll,
      top,
      bottom,
      presetFilter,
      blockedWords,
    );
    // A seek command can finish before its new native position arrives. A
    // refresh in between must not discard the history needed at that target.
    // Compare native positions, not the interpolated clock, which can jitter.
    final backwards =
        position != null && _position != null && position < _position!;
    _position = position;
    final reset =
        _source == null || _configuration != configuration || backwards;
    if (!reset && identical(_source, comments)) return;
    final retained = reset ? <ScheduledComment>[] : visibleAt(now).toList();
    _schedule = DanmakuSchedule(
      assignLanes(
        comments,
        count,
        speed: speed,
        scroll: scroll,
        top: top,
        bottom: bottom,
        presetFilter: presetFilter,
        blockedWords: blockedWords,
        after: reset ? null : now,
        retained: retained,
      ),
      speed: speed,
    );
    _source = comments;
    _configuration = configuration;
  }

  Iterable<ScheduledComment> visibleAt(double now) => _schedule.visibleAt(now);

  double? nextStartAfter(double now) => _schedule.nextStartAfter(now);
}

/// A worker result carries indices and geometry, never another text snapshot.
class DanmakuPlacement {
  final int index, lane;
  final double start, duration;
  const DanmakuPlacement(this.index, this.lane, this.start, this.duration);
}

/// Prepared, time-indexed data. Queries only visit the bounded visible window.
/// Retained comments remain the exact UI objects used before a worker refresh.
class DanmakuSchedule {
  final List<ScheduledComment> _items, _retained;
  final List<DanmakuPlacement> _placements;
  final List<DanmakuComment> _source;
  final Map<int, ScheduledComment>? _visible;
  final double _maxDuration;

  const DanmakuSchedule.empty()
    : _items = const [],
      _retained = const [],
      _placements = const [],
      _source = const [],
      _visible = null,
      _maxDuration = 8;

  DanmakuSchedule(
    List<ScheduledComment> prepared, {
    double speed = 1,
    List<ScheduledComment> retained = const [],
  }) : _items = prepared,
       _retained = retained,
       _placements = const [],
       _source = const [],
       _visible = null,
       _maxDuration = 8 / speed.clamp(.25, 4.0);

  DanmakuSchedule.prepared(
    this._placements,
    this._source, {
    double speed = 1,
    List<ScheduledComment> retained = const [],
  }) : _items = const [],
       _retained = retained,
       _visible = {},
       _maxDuration = 8 / speed.clamp(.25, 4.0);

  int get _length => _retained.length + _items.length + _placements.length;

  double _startAt(int index) {
    if (index < _retained.length) return _retained[index].start;
    index -= _retained.length;
    return _visible == null ? _items[index].start : _placements[index].start;
  }

  double _endAt(int index) {
    if (index < _retained.length) {
      final item = _retained[index];
      return item.start + item.duration;
    }
    index -= _retained.length;
    if (_visible == null) {
      final item = _items[index];
      return item.start + item.duration;
    }
    final item = _placements[index];
    return item.start + item.duration;
  }

  ScheduledComment _at(int index) {
    if (index < _retained.length) return _retained[index];
    index -= _retained.length;
    final visible = _visible;
    if (visible == null) return _items[index];
    return visible.putIfAbsent(index, () {
      final item = _placements[index];
      return ScheduledComment(
        _source[item.index],
        item.index,
        item.lane,
        item.start,
        item.duration,
      );
    });
  }

  Iterable<ScheduledComment> visibleAt(double now) sync* {
    var lo = 0, hi = _length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_startAt(mid) < now - _maxDuration) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // Only materialize UI objects for the current window; keep their identity
    // while visible so a new arrival never invalidates existing text layouts.
    _visible?.removeWhere(
      (_, item) => item.start > now || now >= item.start + item.duration,
    );
    for (var i = lo; i < _length && _startAt(i) <= now; i++) {
      if (now < _endAt(i)) yield _at(i);
    }
  }

  /// Used to wake the overlay at the next arrival without rendering empty
  /// frames throughout long gaps or after the final comment has left.
  double? nextStartAfter(double now) {
    var lo = 0, hi = _length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_startAt(mid) <= now) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _length ? _startAt(lo) : null;
  }
}
