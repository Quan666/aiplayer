import 'dart:async';

import 'package:flutter/widgets.dart';
// Share media_kit's reference count with the full player while retiring a page.
// ignore: implementation_imports
import 'package:media_kit_video/src/utils/wakelock.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'media_controls.dart';
import 'session.dart';

/// Browsing only selects a file. Explicit playback owns at most one decoder,
/// with one latest pending request behind cancellation and native retirement.
class AlbumVideoController extends ChangeNotifier with WidgetsBindingObserver {
  static final _disposals = <Future<void>>{};

  /// A route may be reopened before its predecessor finishes native teardown.
  static Future<void> waitForDisposals() async {
    while (_disposals.isNotEmpty) {
      await Future.wait(_disposals.toList());
    }
  }

  final AppModel model;
  final String sourceId;
  final Future<void> Function()? beforeOpen;
  final PlaybackSession Function(AppModel, SyncRecord) _createSession;
  PlayerMediaControls? _mediaControls;
  final bool _connectMediaControls;
  final Wakelock _wakelock = Wakelock();
  final position = ValueNotifier<Duration>(Duration.zero);
  SourceEntry? _entry;
  PlaybackSession? session;
  CancelToken? _cancel;
  ({SourceEntry entry, int revision, int pauseRevision})? _pending;
  Future<void>? _work, _closeWork, _volumeWork;
  PlaybackSession? _pendingVolumeSession;
  double? _volumeOverride;
  double _restoreVolume = 100;
  Future<void> _retiring = Future.value();
  int _revision = 0, _pauseRevision = 0;
  bool _closed = false, _visible = true, _backgrounded = false;
  bool _foreground = true;
  bool loading = false;
  String error = '';
  Object? _published;

  AlbumVideoController({
    required this.model,
    required this.sourceId,
    this.beforeOpen,
    @visibleForTesting
    PlaybackSession Function(AppModel, SyncRecord)? createSession,
    @visibleForTesting bool connectMediaControls = true,
  }) : _createSession = createSession ?? _newSession,
       _connectMediaControls = connectMediaControls,
       _mediaControls = connectMediaControls ? PlayerMediaControls() : null {
    final binding = WidgetsBinding.instance;
    _readLifecycle(binding.lifecycleState);
    binding.addObserver(this);
    model.addListener(_settingsChanged);
  }

  static PlaybackSession _newSession(AppModel model, SyncRecord record) =>
      PlaybackSession(model, record);

  SourceEntry? get entry => _entry;
  bool get closed => _closed;
  bool get playing => session?.player.state.playing == true;
  bool get buffering => session?.player.state.buffering == true;
  double get _effectiveVolume {
    final active = session;
    if (active != null && active.ready && !loading && _volumeWork == null) {
      return active.player.state.volume;
    }
    return _volumeOverride ??
        active?.player.state.volume ??
        model.preferences.volume;
  }

  bool get muted => _effectiveVolume <= 0;
  bool get firstFrameRendered => session?.firstFrameRendered == true;
  bool get presentationActive => !_closed && _visible && _foreground;
  Duration get duration => session?.player.state.duration ?? Duration.zero;
  bool get _blocked =>
      !_visible || _backgrounded && model.preferences.pauseOnBackground;
  bool get _canStart => !_closed && _visible && !_backgrounded;

  /// This is page/route visibility, independent of transient system focus.
  void setVisible(bool visible) {
    if (_closed || visible == _visible) return;
    _visible = visible;
    if (!visible) _revokeOpening();
    _applyPolicy();
    _changed();
  }

  void select(SourceEntry? entry) {
    if (_closed || _identity(entry) == _identity(_entry)) return;
    _revision++;
    _revokeOpening();
    _retireSession();
    _entry = entry;
    position.value = Duration.zero;
    loading = false;
    error = '';
    _changed();
  }

  static Object? _identity(SourceEntry? entry) =>
      entry == null ? null : (entry.path, entry.size, entry.modified);

  void _readLifecycle(AppLifecycleState? state) {
    _backgrounded = switch (state) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      _ => false,
    };
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    final wasBackgrounded = _backgrounded;
    _readLifecycle(state);
    if (_backgrounded && !wasBackgrounded) {
      // Even an explicitly enabled background-play setting cannot turn a tap
      // still preparing its source into a new background playback session.
      _revokeOpening();
      session?.checkpoint(capturePreview: false);
    }
    _applyPolicy();
    _changed();
  }

  void _settingsChanged() {
    if (_closed) return;
    _applyPolicy();
    _changed();
  }

  void _applyPolicy() {
    final active = session;
    active?.setBackgroundPlaybackBlocked(_blocked);
    active?.setDanmakuPresentationActive(presentationActive);
    if (presentationActive) _positionChanged();
    if (presentationActive && playing && model.preferences.keepScreenOn) {
      _wakelock.enable();
    } else {
      _wakelock.disable();
    }
  }

  void _revokeOpening() {
    _pauseRevision++;
    _pending = null;
    _cancel?.cancel();
    if (loading) {
      _retireSession();
      loading = false;
    }
  }

  void _retireSession() {
    final active = session;
    if (active == null) return;
    session = null;
    active.removeListener(_sessionChanged);
    active.position.removeListener(_positionChanged);
    active.setDanmakuPresentationActive(false);
    active.setBackgroundPlaybackBlocked(true);
    // close revokes source/native startup before yielding, without a frame.
    final closing = active.close().catchError((Object failure) {
      AppLog.instance.warning('关闭相册视频', safeFailure(failure).message);
    });
    _retiring = Future.wait([_retiring, closing]).then((_) {});
    _disposals.add(closing);
    unawaited(closing.then((_) => _disposals.remove(closing)));
    _wakelock.disable();
  }

  Future<void> toggle() => setPlaying(!(playing || loading));

  /// A viewer-local mute preserves the previous level without saving settings
  /// or opening a decoder just to change the next video's sound.
  Future<void> toggleMute() async {
    if (!_canStart) return;
    final volume = _effectiveVolume;
    if (volume > 0) _restoreVolume = volume;
    _volumeOverride = volume > 0 ? 0 : _restoreVolume;
    final active = session;
    if (active != null && active.ready && !loading) {
      final changing = _command(() => _applyVolume(active));
      _changed();
      await changing;
    } else {
      _changed();
    }
  }

  Future<void> _applyVolume(PlaybackSession active) {
    _pendingVolumeSession = active;
    return _volumeWork ??= _drainVolume();
  }

  Future<void> _drainVolume() async {
    try {
      while (_pendingVolumeSession != null) {
        final active = _pendingVolumeSession!;
        _pendingVolumeSession = null;
        bool current() =>
            !_closed &&
            identical(session, active) &&
            !active.closed &&
            active.ready;
        if (!current()) continue;
        final volume = _volumeOverride;
        if (volume == null) continue;
        // media_kit uses its asynchronous native property command here. Keep
        // one write in flight and coalesce quick toggles to the latest level.
        await active.player.setVolume(volume);
        if (current() && _volumeOverride != volume) {
          _pendingVolumeSession = active;
        }
      }
    } finally {
      _volumeWork = null;
      _changed();
    }
  }

  /// Give the full player the existing decoder and exact position. The native
  /// session is paused during ownership transfer; a cancelled route must close
  /// the returned session. This controller can subsequently play a new one.
  Future<PlaybackSession?> takeSession() async {
    if (_closed) return null;
    _revision++;
    _revokeOpening();
    final active = session;
    if (active == null) return null;
    if (!active.ready || active.error.isNotEmpty) {
      _retireSession();
      _changed();
      return null;
    }
    final revision = _revision;
    await _volumeWork;
    if (_closed || revision != _revision || !identical(session, active)) {
      return null;
    }
    session = null;
    active.removeListener(_sessionChanged);
    active.position.removeListener(_positionChanged);
    active.setDanmakuPresentationActive(false);
    active.setBackgroundPlaybackBlocked(true);
    _wakelock.disable();
    final controls = _mediaControls;
    _mediaControls = _connectMediaControls ? PlayerMediaControls() : null;
    _changed();
    try {
      await active.setPlaying(false);
      await controls?.close();
      return active;
    } catch (_) {
      await Future.wait<void>([
        active.close(),
        if (controls != null) controls.close(),
      ]);
      rethrow;
    }
  }

  Future<void> setPlaying(bool value) async {
    if (_closed) return;
    if (!value) {
      _revokeOpening();
      final active = session;
      if (active != null) await _command(() => active.setPlaying(false));
      _changed();
      return;
    }
    final entry = _entry;
    if (!_canStart || entry == null) return;
    final active = session;
    if (active != null && active.ready && active.error.isEmpty) {
      final revision = _revision, pauseRevision = _pauseRevision;
      await _command(() async {
        if (active.player.state.completed) await active.seek(Duration.zero);
        if (!_canStart ||
            revision != _revision ||
            pauseRevision != _pauseRevision ||
            !identical(active, session)) {
          return;
        }
        await active.setPlaying(true);
      });
      return;
    }
    if (loading) return;
    _retireSession();
    _pending = (
      entry: entry,
      revision: _revision,
      pauseRevision: _pauseRevision,
    );
    loading = true;
    error = '';
    _changed();
    await (_work ??= _drain());
  }

  Future<void> _drain() async {
    try {
      while (!_closed && _pending != null) {
        final request = _pending!;
        _pending = null;
        final cancel = _cancel = CancelToken();
        bool current() =>
            _canStart &&
            !cancel.cancelled &&
            request.revision == _revision &&
            request.pauseRevision == _pauseRevision;
        try {
          await waitForDisposals();
          if (!current()) continue;
          await beforeOpen?.call();
          if (!current()) continue;
          final record = await model.preparePersonalMediaForPlayback(
            sourceId,
            request.entry,
            cancel: cancel,
          );
          if (!current()) continue;
          final active = session = _createSession(model, record);
          active.addListener(_sessionChanged);
          active.position.addListener(_positionChanged);
          _mediaControls?.bindSession(active);
          _mediaControls?.configure(
            title: request.entry.name,
            seekStepSeconds: model.preferences.seekStepSeconds,
          );
          _applyPolicy();
          _changed();
          // Apply a preselected mute before the first audible sample. Default
          // playback keeps the existing one-step open path.
          final openPaused = _volumeOverride != null;
          await active.open(play: current() && !openPaused, resume: false);
          if (!current()) {
            if (identical(active, session)) _retireSession();
            continue;
          }
          if (_volumeOverride != null && active.ready && active.error.isEmpty) {
            await _applyVolume(active);
            if (!current()) {
              if (identical(active, session)) _retireSession();
              continue;
            }
            if (openPaused) await active.setPlaying(true);
            if (!current()) {
              if (identical(active, session)) _retireSession();
              continue;
            }
          }
          loading = false;
          error = active.error;
          _sessionChanged();
        } on Cancelled {
          // The next explicit action can reuse the selected cover.
        } catch (failure) {
          if (current()) {
            error = safeFailure(failure, action: '播放失败').message;
            loading = false;
            _retireSession();
            _changed();
          }
        } finally {
          if (identical(_cancel, cancel)) _cancel = null;
        }
      }
    } finally {
      _work = null;
      if (!_closed && _pending != null) _work = _drain();
      if (!_closed && _pending == null && session == null && loading) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> seek(Duration target) async {
    final active = session;
    if (!_canStart || loading || active == null || !active.ready) return;
    final milliseconds = target.inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );
    await _command(() => active.seek(Duration(milliseconds: milliseconds)));
  }

  Future<void> _command(Future<void> Function() action) async {
    final revision = _revision, owner = session;
    try {
      await action();
    } catch (failure) {
      if (!_closed && revision == _revision && identical(owner, session)) {
        error = safeFailure(failure, action: '播放失败').message;
        _changed();
      }
    }
  }

  void _positionChanged() {
    if (presentationActive && session != null) {
      position.value = session!.position.value;
    }
  }

  void _sessionChanged() {
    if (_closed) return;
    error = session?.error ?? error;
    _applyPolicy();
    _changed();
  }

  void _changed() {
    if (_closed) return;
    final snapshot = (
      _identity(_entry),
      session,
      loading,
      error,
      playing,
      buffering,
      muted,
      firstFrameRendered,
      duration,
      session?.player.state.videoParams,
      presentationActive,
    );
    if (snapshot == _published) return;
    _published = snapshot;
    notifyListeners();
  }

  Future<void> close() => _closeWork ??= _close();

  Future<void> _close() async {
    _closed = true;
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_settingsChanged);
    _revokeOpening();
    _retireSession();
    _wakelock.disable();
    await _mediaControls?.close();
    await _work;
    try {
      await _volumeWork;
    } catch (_) {
      // Retiring the decoder can reject its last pending volume command.
      // The interactive caller owns that error; teardown still completes.
    }
    await _retiring;
  }

  @override
  void dispose() {
    unawaited(close());
    position.dispose();
    super.dispose();
  }
}
