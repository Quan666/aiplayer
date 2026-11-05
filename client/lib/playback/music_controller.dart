import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'media_controls.dart';
import 'session.dart';

enum MusicPlayMode { sequence, repeatAll, repeatOne, shuffle }

/// Queue movement is constant work; it never sorts or scans the media library.
class MusicQueue {
  final int length;
  final Random _random;
  int index;
  MusicPlayMode mode = MusicPlayMode.sequence;
  final List<int> _history = [];
  MusicQueue(this.length, {this.index = 0, Random? random})
    : _random = random ?? Random() {
    if (length <= 0 || index < 0 || index >= length) {
      throw ArgumentError('播放列表为空或位置无效。');
    }
  }

  int? next({bool automatic = false}) {
    if (automatic && mode == MusicPlayMode.repeatOne) return index;
    if (mode == MusicPlayMode.shuffle) {
      return length == 1
          ? 0
          : (index + 1 + _random.nextInt(length - 1)) % length;
    }
    if (index + 1 < length) return index + 1;
    return mode == MusicPlayMode.repeatAll ? 0 : null;
  }

  int? previous() {
    if (mode == MusicPlayMode.shuffle && _history.isNotEmpty) {
      return _history.removeLast();
    }
    if (index > 0) return index - 1;
    return mode == MusicPlayMode.repeatAll ? length - 1 : null;
  }

  void select(int next, {bool remember = true}) {
    if (next < 0 || next >= length) throw RangeError.range(next, 0, length - 1);
    if (remember && next != index) {
      if (_history.length >= 128) _history.removeAt(0);
      _history.add(index);
    }
    index = next;
  }
}

class _MusicRequest {
  final int index, revision, pauseRevision;
  final bool play, automatic;
  const _MusicRequest(
    this.index,
    this.revision,
    this.pauseRevision,
    this.play,
    this.automatic,
  );
}

/// One active decoder and one latest pending selection. Late opens/completions
/// cannot bypass a pause, replace a newer selection or revive a closed page.
class MusicPlaybackController extends ChangeNotifier {
  final AppModel model;
  final String sourceId;
  final List<SourceEntry> entries;
  final MusicQueue queue;
  final PlaybackSession Function(AppModel, SyncRecord) _createSession;
  final PlayerMediaControls? _mediaControls;
  final bool _mobileLifecycle;
  PlaybackSession? session;
  CancelToken? _cancel;
  _MusicRequest? _pending;
  Future<void>? _work, _closeWork;
  int _revision = 0, _pauseRevision = 0, _completedRevision = 0;
  bool _closed = false, _backgrounded, _blocked = false;
  bool _activeAutomatic = false;
  bool loading = false;
  String error = '';

  MusicPlaybackController({
    required this.model,
    required this.sourceId,
    required this.entries,
    int initialIndex = 0,
    this._backgrounded = false,
    bool? mobileLifecycle,
    @visibleForTesting bool connectMediaControls = true,
    @visibleForTesting
    PlaybackSession Function(AppModel, SyncRecord)? createSession,
  }) : queue = MusicQueue(entries.length, index: initialIndex),
       _mobileLifecycle =
           mobileLifecycle ?? (Platform.isAndroid || Platform.isIOS),
       _createSession = createSession ?? _audioSession,
       _mediaControls = connectMediaControls ? PlayerMediaControls() : null {
    model.addListener(_settingsChanged);
    _settingsChanged();
  }

  static PlaybackSession _audioSession(AppModel model, SyncRecord record) =>
      PlaybackSession(model, record, audioOnly: true);
  bool get backgrounded => _backgrounded;
  bool get closed => _closed;
  SourceEntry get current => entries[queue.index];
  String get title => session?.audioTitle.isNotEmpty == true
      ? session!.audioTitle
      : current.name;

  void _settingsChanged() {
    if (_closed) return;
    final blocked =
        _mobileLifecycle &&
        _backgrounded &&
        model.preferences.pauseOnBackground;
    if (_blocked != blocked) {
      _blocked = blocked;
      if (blocked) {
        _pauseRevision++;
        if (_pending?.automatic == true) _pending = null;
        if (_activeAutomatic) {
          _cancel?.cancel();
          unawaited(session?.close());
        }
      }
      session?.setBackgroundPlaybackBlocked(blocked);
      if (blocked) session?.checkpoint(capturePreview: false);
    }
    _configureControls();
  }

  void setBackgrounded(bool value) {
    if (_closed || value == _backgrounded) return;
    _backgrounded = value;
    _settingsChanged();
    notifyListeners();
  }

  void setMode(MusicPlayMode mode) {
    if (_closed || mode == queue.mode) return;
    queue.mode = mode;
    _configureControls();
    notifyListeners();
  }

  Future<void> start({bool play = true}) => select(queue.index, play: play);
  Future<void> next({bool automatic = false}) {
    if (_closed || (automatic && _blocked)) return Future.value();
    final next = queue.next(automatic: automatic);
    return next == null ? Future.value() : select(next, automatic: automatic);
  }

  Future<void> previous() {
    if (_closed) return Future.value();
    final previous = queue.previous();
    return previous == null
        ? Future.value()
        : select(previous, remember: false);
  }

  Future<void> select(
    int index, {
    bool automatic = false,
    bool remember = true,
    bool play = true,
  }) {
    if (_closed || (automatic && _blocked)) return Future.value();
    queue.select(index, remember: remember);
    final revision = ++_revision;
    _pending = _MusicRequest(index, revision, _pauseRevision, play, automatic);
    _cancel?.cancel();
    session?.setBackgroundPlaybackBlocked(true);
    // close signals the session's source/native-startup cancellation now;
    // the serial drain awaits its cleanup before creating the next decoder.
    unawaited(session?.close());
    loading = true;
    error = '';
    notifyListeners();
    return _work ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (!_closed && _pending != null) {
        final request = _pending!;
        _pending = null;
        _activeAutomatic = request.automatic;
        final cancel = _cancel = CancelToken();
        final retiring = session;
        session = null;
        retiring?.removeListener(_sessionChanged);
        await retiring?.close();
        if (_closed || cancel.cancelled || request.revision != _revision) {
          continue;
        }
        if (request.automatic &&
            (_blocked || request.pauseRevision != _pauseRevision)) {
          continue;
        }
        try {
          final record = await model.preparePersonalMediaForPlayback(
            sourceId,
            entries[request.index],
            cancel: cancel,
          );
          cancel.check();
          if (_closed || request.revision != _revision) continue;
          final active = session = _createSession(model, record);
          _completedRevision = 0;
          active.setBackgroundPlaybackBlocked(_blocked);
          active.addListener(_sessionChanged);
          _mediaControls?.bindSession(active);
          _configureControls();
          await active.open(
            play:
                !_blocked &&
                request.pauseRevision == _pauseRevision &&
                request.play,
            resume: false,
          );
          cancel.check();
          if (_closed || request.revision != _revision) continue;
          loading = false;
          error = active.error;
          _sessionChanged();
        } on Cancelled {
          final abandoned = session;
          session = null;
          abandoned?.removeListener(_sessionChanged);
          await abandoned?.close();
        } catch (failure) {
          if (!_closed && request.revision == _revision) {
            loading = false;
            error = safeFailure(failure).message;
            notifyListeners();
          }
        }
      }
    } finally {
      _activeAutomatic = false;
      _work = null;
      if (!_closed && _pending != null) _work = _drain();
      if (!_closed && _pending == null && session == null && loading) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void _sessionChanged() {
    final active = session;
    if (_closed || active == null) return;
    _configureControls();
    if (active.error.isNotEmpty) error = active.error;
    if (active.ready &&
        !loading &&
        active.completionRevision != _completedRevision) {
      _completedRevision = active.completionRevision;
      if (!_blocked && !loading) unawaited(next(automatic: true));
    }
    notifyListeners();
  }

  void _configureControls() => _mediaControls?.configure(
    title: title,
    seekStepSeconds: model.preferences.seekStepSeconds,
    onNext:
        queue.index + 1 < queue.length ||
            queue.mode == MusicPlayMode.repeatAll ||
            queue.mode == MusicPlayMode.shuffle
        ? () => next()
        : null,
    onPrevious:
        queue.index > 0 ||
            queue.mode == MusicPlayMode.repeatAll ||
            queue.mode == MusicPlayMode.shuffle
        ? previous
        : null,
  );

  Future<void> togglePlayback() async {
    if (_closed || loading) return;
    if (session == null) return start();
    try {
      await session!.togglePlayback();
    } catch (failure) {
      _report(failure);
    }
  }

  Future<void> seek(Duration position) async {
    if (_closed || loading || session == null) return;
    try {
      await session!.seek(position);
    } catch (failure) {
      _report(failure);
    }
  }

  void _report(Object failure) {
    if (_closed) return;
    error = safeFailure(failure).message;
    notifyListeners();
  }

  Future<void> close() => _closeWork ??= _close();
  Future<void> _close() async {
    _closed = true;
    _revision++;
    _pending = null;
    _cancel?.cancel();
    model.removeListener(_settingsChanged);
    final active = session;
    active?.removeListener(_sessionChanged);
    active?.setBackgroundPlaybackBlocked(true);
    // Revoke startup immediately even if native media-control cleanup waits.
    final closing = active?.close();
    await _mediaControls?.close();
    await closing;
    await _work;
    if (session != active) await session?.close();
    session = null;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
