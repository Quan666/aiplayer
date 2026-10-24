import 'dart:async';
import 'dart:isolate';

import 'api.dart';
import 'layout.dart';

class DanmakuLayoutOptions {
  final int count;
  final double speed;
  final bool scroll, top, bottom, presetFilter;
  final String blockedWords;

  const DanmakuLayoutOptions({
    required this.count,
    this.speed = 1,
    this.scroll = true,
    this.top = true,
    this.bottom = true,
    this.presetFilter = true,
    this.blockedWords = '',
  });

  @override
  bool operator ==(Object other) =>
      other is DanmakuLayoutOptions &&
      (count, speed, scroll, top, bottom, presetFilter, blockedWords) ==
          (
            other.count,
            other.speed,
            other.scroll,
            other.top,
            other.bottom,
            other.presetFilter,
            other.blockedWords,
          );

  @override
  int get hashCode => Object.hash(
    count,
    speed,
    scroll,
    top,
    bottom,
    presetFilter,
    blockedWords,
  );
}

class _LayoutJob {
  final List<DanmakuComment> source;
  final DanmakuLayoutOptions options;
  final double? after;
  final List<ScheduledComment> retained;
  final result = Completer<List<DanmakuPlacement>?>();

  _LayoutJob(this.source, this.options, this.after, this.retained);
}

/// One sleeping isolate per overlay, one running job and one latest pending job.
/// Repeated seeks/settings reuse the source already held by the worker.
class DanmakuLayoutWorker {
  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _requests;
  List<DanmakuComment>? _sentSource;
  _LayoutJob? _active, _pending;
  bool _disposed = false, _starting = false;

  int starts = 0, completions = 0, sourceTransfers = 0;
  int? preparationIsolate;
  int get pendingCount =>
      (_active == null ? 0 : 1) + (_pending == null ? 0 : 1);

  Future<List<DanmakuPlacement>?> prepare(
    List<DanmakuComment> source,
    DanmakuLayoutOptions options, {
    double? after,
    List<ScheduledComment> retained = const [],
  }) {
    if (_disposed) return Future.value(null);
    final job = _LayoutJob(source, options, after, retained);
    _pending?.result.complete(null);
    _pending = job;
    if (_events == null) _start();
    _dispatch();
    return job.result.future;
  }

  void _start() {
    if (_starting) return;
    _starting = true;
    final events = _events = ReceivePort();
    starts++;
    events.listen((message) {
      if (!identical(_events, events)) return;
      if (message is SendPort) {
        _requests = message;
        _dispatch();
      } else if (message case (List<DanmakuPlacement> items, int isolate)) {
        preparationIsolate = isolate;
        completions++;
        final active = _active;
        _active = null;
        active?.result.complete(items);
        _dispatch();
      } else {
        // Fatal worker errors/exit settle callers without scheduling retries.
        cancel();
      }
    });
    unawaited(
      Isolate.spawn(
        _prepareLayouts,
        events.sendPort,
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'danmaku-layout',
      ).then<void>(
        (isolate) {
          _starting = false;
          if (_disposed || !identical(_events, events)) {
            isolate.kill(priority: Isolate.immediate);
            // A lifecycle transition can cancel before spawn returns. Keep
            // only its latest pending replacement until this spawn is ended.
            if (!_disposed && _pending != null) _start();
          } else {
            _isolate = isolate;
          }
        },
        onError: (Object error, StackTrace trace) {
          _starting = false;
          if (identical(_events, events)) cancel();
          if (!_disposed && _pending != null) _start();
        },
      ),
    );
  }

  void _dispatch() {
    if (_disposed || _requests == null || _active != null) return;
    final job = _pending;
    if (job == null) return;
    _pending = null;
    _active = job;
    final changed = !identical(_sentSource, job.source);
    _sentSource = job.source;
    if (changed) sourceTransfers++;
    _requests!.send((
      changed ? job.source : null,
      job.options,
      job.after,
      job.retained,
    ));
  }

  /// Lifecycle cancellation stops CPU work immediately, without another frame.
  /// A future request may lazily start a new worker with a fresh source copy.
  void cancel() {
    _events?.close();
    _events = null;
    _requests = null;
    _sentSource = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _active?.result.complete(null);
    _active = null;
    _pending?.result.complete(null);
    _pending = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}

void _prepareLayouts(SendPort replies) {
  final requests = ReceivePort();
  List<DanmakuComment> source = const [];
  replies.send(requests.sendPort);
  requests.listen((message) {
    final (snapshot, options, after, retained) =
        message
            as (
              List<DanmakuComment>?,
              DanmakuLayoutOptions,
              double?,
              List<ScheduledComment>,
            );
    if (snapshot != null) source = snapshot;
    final schedule = assignLanes(
      source,
      options.count,
      speed: options.speed,
      scroll: options.scroll,
      top: options.top,
      bottom: options.bottom,
      presetFilter: options.presetFilter,
      blockedWords: options.blockedWords,
      after: after,
      retained: retained,
    );
    // Never copy retained UI objects back or copy the full result on the UI
    // isolate. Both slicing and the read-only snapshot are built here.
    replies.send((
      List<DanmakuPlacement>.unmodifiable(
        schedule
            .skip(retained.length)
            .map(
              (item) => DanmakuPlacement(
                item.index,
                item.lane,
                item.start,
                item.duration,
              ),
            ),
      ),
      Isolate.current.hashCode,
    ));
  });
}

/// Owns invalidation on the UI isolate; filtering and lane allocation are only
/// performed by the worker. Reads during paint use the last prepared snapshot.
class AsyncDanmakuLayout {
  final DanmakuLayoutWorker worker;
  final void Function() onChanged;
  AsyncDanmakuLayout(this.onChanged, {DanmakuLayoutWorker? worker})
    : worker = worker ?? DanmakuLayoutWorker();

  DanmakuSchedule schedule = const DanmakuSchedule.empty();
  List<DanmakuComment>? _source;
  Object? _configuration;
  Duration? _position;
  int _revision = 0;
  bool _hasPrepared = false, _suspended = false, _disposed = false;
  bool _pending = false, _needsPreparation = false;
  double? _pendingAfter;
  List<ScheduledComment> _pendingRetained = const [];
  Future<void> ready = Future.value();

  void update(
    List<DanmakuComment> comments,
    DanmakuLayoutOptions options, {
    required double now,
    required Duration position,
    required Object contextKey,
  }) {
    if (_disposed || _suspended) return;
    final configuration = (contextKey, options);
    final backwards = _position != null && position < _position!;
    _position = position;
    final reset =
        _configuration != configuration ||
        backwards ||
        (_needsPreparation && !identical(_source, comments));
    final resumeRequest = _needsPreparation && !reset;
    if (!reset && identical(_source, comments) && !_needsPreparation) return;
    if (reset) {
      // Invalidate a running job before replacing its input. Setting changes
      // are coalesced by the worker; its obsolete result cannot be applied.
      schedule = const DanmakuSchedule.empty();
      _hasPrepared = false;
    }
    // A suspended refresh resumes at its original cutoff. Advancing that
    // cutoff to the foreground time would drop comments which arrived while
    // hidden but are still visible now. Changed source/configuration instead
    // rebuilds from its latest snapshot, without reviving the old request.
    final retained = resumeRequest
        ? _pendingRetained
        : _hasPrepared
        ? List<ScheduledComment>.unmodifiable(schedule.visibleAt(now))
        : const <ScheduledComment>[];
    final after = resumeRequest ? _pendingAfter : (_hasPrepared ? now : null);
    schedule = DanmakuSchedule(
      const [],
      speed: options.speed,
      retained: retained,
    );
    _configuration = configuration;
    _source = comments;
    _needsPreparation = false;
    final revision = ++_revision;
    if (comments.isEmpty ||
        (!options.scroll && !options.top && !options.bottom)) {
      _pending = false;
      _pendingAfter = null;
      _pendingRetained = const [];
      _hasPrepared = true;
      // There is no useful queued work after the final source is removed.
      worker.cancel();
      ready = Future.value();
      return;
    }
    _pending = true;
    _pendingAfter = after;
    _pendingRetained = retained;
    ready = worker
        .prepare(comments, options, after: after, retained: retained)
        .then((items) {
          if (_disposed || _suspended || revision != _revision) return;
          _pending = false;
          _pendingAfter = null;
          _pendingRetained = const [];
          if (items == null) return;
          schedule = DanmakuSchedule.prepared(
            items,
            comments,
            speed: options.speed,
            retained: retained,
          );
          _hasPrepared = true;
          onChanged();
        });
  }

  void setSuspended(bool value) {
    if (_disposed || _suspended == value) return;
    _suspended = value;
    if (value) {
      _revision++;
      _needsPreparation = _pending;
      _pending = false;
      worker.cancel();
    }
  }

  void clear() {
    _revision++;
    worker.cancel();
    schedule = const DanmakuSchedule.empty();
    _source = null;
    _configuration = null;
    _position = null;
    _hasPrepared = false;
    _pending = false;
    _pendingAfter = null;
    _pendingRetained = const [];
    _needsPreparation = false;
    ready = Future.value();
  }

  void dispose() {
    _disposed = true;
    clear();
    worker.dispose();
  }
}
