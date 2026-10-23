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
  List<ScheduledComment> _schedule = [];
  double _maxDuration = 8;

  void clear() {
    _source = null;
    _configuration = null;
    _position = null;
    _schedule = [];
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
    _schedule = assignLanes(
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
    );
    _source = comments;
    _configuration = configuration;
    _maxDuration = 8 / speed.clamp(.25, 4.0);
  }

  Iterable<ScheduledComment> visibleAt(double now) sync* {
    var lo = 0, hi = _schedule.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_schedule[mid].start < now - _maxDuration) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < _schedule.length && _schedule[i].start <= now; i++) {
      final item = _schedule[i];
      if (now < item.start + item.duration) yield item;
    }
  }

  /// Used to wake the overlay at the next arrival without rendering empty
  /// frames throughout long gaps or after the final comment has left.
  double? nextStartAfter(double now) {
    var lo = 0, hi = _schedule.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_schedule[mid].start <= now) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _schedule.length ? _schedule[lo].start : null;
  }
}
