import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'artwork_lifecycle.dart';

/// Admits a bounded number of native image reads/decodes after layout.
///
/// The queue only coordinates [ImageProvider] streams. File IO and decoding
/// remain in the providers' asynchronous platform implementation.
class ArtworkDecodeQueue extends ChangeNotifier {
  ArtworkDecodeQueue({this.maxActive = 2, this.maxPending = 64})
    : assert(maxActive > 0),
      assert(maxPending > 0) {
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
  }

  static final instance = ArtworkDecodeQueue();

  final int maxActive;
  final int maxPending;
  final _pending = <ArtworkDecodeRequest>{};
  final _active = <ArtworkDecodeRequest>{};
  final _retained = <ArtworkDecodeRequest>{};
  bool _frameScheduled = false;
  bool _dispatchScheduled = false;
  bool _dispatching = false;
  bool _capacityBlocked = false;
  bool _disposed = false;

  bool get _enabled => !_disposed && ArtworkLifecycle.instance.value;

  void _lifecycleChanged() {
    if (!_enabled) {
      for (final request in _retained.toList(growable: false)) {
        request._releaseImage();
      }
    } else if (_pending.isNotEmpty || _capacityBlocked) {
      _scheduleFrame();
    }
  }

  /// Wakes callers whose request was rejected because the pending queue was full.
  Listenable get capacity => this;

  /// Returns null when all waiting slots are occupied. Callers can retry on
  /// [capacity] or the next shared scroll update.
  ///
  /// [canStart] is checked after layout immediately before resolving the image.
  /// [priority] is evaluated again at admission: zero is visible, positive
  /// values are nearby prefetches, and negative values discard the request.
  /// Only one prefetch can run at a time, leaving a slot for visible artwork.
  /// [onStart] runs after the stream listener is attached, so a rebuilt Image
  /// widget can join the cache's existing pending stream without another decode.
  ArtworkDecodeRequest? request(
    ImageProvider provider, {
    required bool Function() canStart,
    int Function()? priority,
    required VoidCallback onStart,
    required void Function(Object error, StackTrace? stack) onError,
  }) {
    if (_disposed) return null;
    if (_pending.length >= maxPending) {
      _capacityBlocked = true;
      return null;
    }
    final request = ArtworkDecodeRequest._(
      this,
      provider,
      canStart,
      priority,
      onStart,
      onError,
    );
    _pending.add(request);
    _scheduleFrame();
    return request;
  }

  void _scheduleFrame() {
    if (!_enabled || _frameScheduled) return;
    _frameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!_enabled) return;
      for (final request in _pending) {
        request._laidOut = true;
      }
      _dispatch();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  bool get _afterLayout => switch (SchedulerBinding.instance.schedulerPhase) {
    SchedulerPhase.idle || SchedulerPhase.postFrameCallbacks => true,
    _ => false,
  };

  void _scheduleDispatch() {
    if (!_enabled || _dispatchScheduled || _dispatching) return;
    if (!_afterLayout) {
      _scheduleFrame();
      return;
    }
    _dispatchScheduled = true;
    scheduleMicrotask(() {
      _dispatchScheduled = false;
      if (!_enabled) return;
      if (_afterLayout) {
        _dispatch();
      } else {
        _scheduleFrame();
      }
    });
  }

  void _dispatch() {
    if (!_enabled || _dispatching) return;
    _dispatching = true;
    // The queue is bounded at 64 entries. Check each viewport priority once per
    // dispatch, without sorting or repeatedly measuring the same request.
    final eligible = <(ArtworkDecodeRequest, int)>[];
    for (final request in _pending.toList(growable: false)) {
      if (!request._laidOut) continue;
      final priority = request._canStart()
          ? request._priority?.call() ?? 0
          : -1;
      if (priority < 0) {
        request._completed = true;
        _pending.remove(request);
      } else {
        eligible.add((request, priority));
      }
    }
    var started = 0;
    while (_enabled && _active.length < maxActive && started < maxActive) {
      final prefetchRunning = _active.any((request) => request._prefetch);
      var selected = -1;
      for (var i = 0; i < eligible.length; i++) {
        if (!eligible[i].$1.isPending) continue;
        final priority = eligible[i].$2;
        if (priority > 0 && prefetchRunning) continue;
        if (selected < 0 || priority < eligible[selected].$2) selected = i;
      }
      if (selected < 0) break;
      final (request, priority) = eligible.removeAt(selected);
      _pending.remove(request);
      request._prefetch = priority > 0;
      _active.add(request);
      started++;
      request._start();
    }
    _dispatching = false;
    if (!_enabled) return;
    if (started == maxActive && _active.length < maxActive) {
      final prefetchRunning = _active.any((request) => request._prefetch);
      if (eligible.any(
        (entry) => entry.$1.isPending && (entry.$2 == 0 || !prefetchRunning),
      )) {
        // Synchronous cache hits/errors must not create an unbounded microtask
        // chain. Only these immediate completions yield to another frame.
        _scheduleFrame();
      }
    }
    if (_capacityBlocked && _pending.length < maxPending) {
      _capacityBlocked = false;
      notifyListeners();
    }
  }

  void _finished(ArtworkDecodeRequest request) {
    _active.remove(request);
    if (_pending.isNotEmpty || _capacityBlocked) _scheduleDispatch();
  }

  void _refreshPriority(ArtworkDecodeRequest request) {
    if (_disposed ||
        !request.isPending ||
        _active.length >= maxActive ||
        !_pending.contains(request)) {
      return;
    }
    if (request._laidOut) {
      _scheduleDispatch();
    } else {
      _scheduleFrame();
    }
  }

  void _cancel(ArtworkDecodeRequest request) {
    if (_pending.remove(request) && _capacityBlocked) _scheduleFrame();
    // A running platform decode cannot be interrupted. Its listener must stay
    // attached until completion so cancellation cannot bypass the active limit.
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    for (final request in _retained.toList(growable: false)) {
      request._releaseImage();
    }
    for (final request in [..._pending, ..._active]) {
      request._cancelled = true;
    }
    _pending.clear();
    super.dispose();
  }
}

class ArtworkDecodeRequest {
  ArtworkDecodeRequest._(
    this._queue,
    this._provider,
    this._canStart,
    this._priority,
    this._onStart,
    this._onError,
  );

  final ArtworkDecodeQueue _queue;
  final ImageProvider _provider;
  final bool Function() _canStart;
  final int Function()? _priority;
  final VoidCallback _onStart;
  final void Function(Object error, StackTrace? stack) _onError;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _retainedImage;
  bool _cancelled = false;
  bool _completed = false;
  bool _failed = false;
  bool _laidOut = false;
  bool _prefetch = false;

  /// True while waiting or decoding; false after cancellation or completion.
  bool get isPending => !_cancelled && !_completed;

  /// Reconsiders a queued cover after a shared viewport update. A nearby cover
  /// that becomes visible can use the reserved slot without waiting for the
  /// running prefetch. Active/finished requests and a full queue of decodes do
  /// not trigger another priority scan.
  void refreshPriority() => _queue._refreshPriority(this);

  void cancel() {
    if (_cancelled || _completed) return;
    _cancelled = true;
    _queue._cancel(this);
  }

  void _start() {
    _listener = ImageStreamListener(_imageReady, onError: _imageFailed);
    try {
      _stream = _provider.resolve(ImageConfiguration.empty);
      _stream!.addListener(_listener!);
    } catch (error, stack) {
      _imageFailed(error, stack);
    }
    if (!_cancelled && !_failed) _onStart();
  }

  void _imageReady(ImageInfo image, bool synchronousCall) {
    if (_completed) {
      image.dispose();
      return;
    }
    _completed = true;
    _queue._finished(this);
    if (!_queue._enabled || _cancelled) {
      _removeListener();
      image.dispose();
      return;
    }
    // Retain this listener through the next build, including when the decoded
    // image exceeds the image cache budget. Image widgets can attach first.
    _retainedImage = image;
    _queue._retained.add(this);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _releaseImage();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _releaseImage() {
    _queue._retained.remove(this);
    _removeListener();
    _retainedImage?.dispose();
    _retainedImage = null;
  }

  void _imageFailed(Object error, StackTrace? stack) {
    if (_completed) return;
    _completed = true;
    _failed = true;
    _removeListener();
    _queue._finished(this);
    if (!_cancelled) _onError(error, stack);
  }

  void _removeListener() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
  }
}
