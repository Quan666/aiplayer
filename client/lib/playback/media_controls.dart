import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';
import '../core/network.dart';
import 'session.dart';

/// One owner for headset, remote and system transport controls. Native position
/// displays extrapolate from state changes; this bridge never polls playback.
class PlayerMediaControls {
  static const _channel = MethodChannel('app.aiplayer/media_controls');
  static PlayerMediaControls? _owner;
  static int _nextSessionId = DateTime.now().microsecondsSinceEpoch;
  PlaybackSession? _session;
  Future<void> Function()? _closeHook;
  int _sessionId = 0;
  bool _closed = false, _nativePip = false, _navigationBusy = false;
  bool _nativeSupported;
  final bool _keyboardEnabled;
  String _title = '';
  int _seekStepSeconds = 10;
  Future<void> Function()? _next, _previous;
  Object? _published;
  Map<String, Object>? _pendingUpdate;
  Future<void>? _updateWork, _seekWork;
  (PlaybackSession, int, int, Duration)? _pendingSeek;
  Duration? _seekingTo;
  int? _timelineRevision;
  bool _awaitingSeekPosition = false;

  PlayerMediaControls({
    @visibleForTesting bool? nativeSupported,
    @visibleForTesting bool? keyboardEnabled,
  }) : _nativeSupported = nativeSupported ?? !Platform.isLinux,
       _keyboardEnabled = keyboardEnabled ?? Platform.isLinux;

  void bindSession(PlaybackSession session) {
    if (_closed || identical(session, _session)) return;
    if (_owner != this) {
      unawaited(_owner?.close());
      _owner = this;
      _channel.setMethodCallHandler(_nativeCommand);
      if (_keyboardEnabled) HardwareKeyboard.instance.addHandler(_keyEvent);
    }
    if (_session != null) {
      unawaited(_invoke('clear', {'sessionId': _sessionId}));
    }
    _detachSession();
    _session = session;
    _sessionId = ++_nextSessionId;
    _nativePip = false;
    _next = _previous = null;
    session.addListener(refresh);
    session.position.addListener(_positionChanged);
    final id = _sessionId;
    _closeHook = () async {
      // An old close may already have copied its hooks before a rebind.
      if (_session != session || _sessionId != id) return;
      _detachSession();
      await _invoke('clear', {'sessionId': id});
    };
    session.addCloseHook(_closeHook!);
    refresh();
  }

  void configure({
    required String title,
    required int seekStepSeconds,
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
  }) {
    _title = title;
    _seekStepSeconds = seekStepSeconds;
    _next = onNext;
    _previous = onPrevious;
    refresh();
  }

  void setNativePictureInPicture(bool active) {
    if (_nativePip == active) return;
    _nativePip = active;
    refresh();
  }

  void refresh() {
    final session = _session;
    if (_closed || session == null) return;
    if (_timelineRevision != null &&
        _timelineRevision != session.timelineRevision) {
      _awaitingSeekPosition = true;
    }
    _timelineRevision = session.timelineRevision;
    final state = session.player.state;
    final active =
        !session.closed &&
        session.ready &&
        session.error.isEmpty &&
        (!session.remotePlayback || _nativePip);
    final snapshot = (
      _sessionId,
      active,
      _title,
      state.playing,
      state.buffering,
      state.completed,
      state.duration,
      state.rate,
      session.timelineRevision,
      _next != null,
      _previous != null,
      _nativePip,
      session.backgroundPauseRevision,
      _seekStepSeconds,
    );
    if (_published == snapshot) return;
    _published = snapshot;
    _pendingUpdate = {
      'sessionId': _sessionId,
      'active': active,
      'title': _title,
      'playing': state.playing,
      'buffering': state.buffering,
      'completed': state.completed,
      'positionMs': (_seekingTo ?? state.position).inMilliseconds,
      'durationMs': state.duration.inMilliseconds,
      'speed': state.rate,
      'canGoNext': _next != null,
      'canGoPrevious': _previous != null,
      'nativePip': _nativePip,
      'pauseRevision': session.backgroundPauseRevision,
      'seekStepSeconds': _seekStepSeconds,
    };
    _updateWork ??= _flushUpdates();
  }

  void _positionChanged() {
    // mpv may acknowledge seek before publishing its new position. Correct
    // that anchor once; ordinary playback ticks never cross the channel.
    if (!_awaitingSeekPosition) return;
    _awaitingSeekPosition = false;
    _published = null;
    refresh();
  }

  Future<void> _flushUpdates() async {
    // Bound a slow platform channel to the in-flight state and one latest state.
    try {
      while (!_closed && _pendingUpdate != null) {
        final update = _pendingUpdate!;
        _pendingUpdate = null;
        await _invoke('update', update);
      }
    } finally {
      _updateWork = null;
    }
  }

  /// AVKit uses a different channel: publish its ownership before it attaches
  /// the native player, including any state coalesced behind an earlier update.
  Future<void> settleNativeState() async {
    while (!_closed && _updateWork != null) {
      await _updateWork;
    }
    if (_closed) throw const Cancelled();
  }

  Future<void> _invoke(String method, Map<String, Object> values) async {
    if (!_nativeSupported) return;
    try {
      await _channel.invokeMethod<void>(method, values);
    } on MissingPluginException {
      _nativeSupported = false;
    } on PlatformException catch (error) {
      AppLog.instance.warning('媒体控制', safeFailure(error).message);
    }
  }

  Future<void> _nativeCommand(MethodCall call) async {
    final values = call.arguments;
    if (call.method != 'command' ||
        values is! Map ||
        values['sessionId'] != _sessionId ||
        values['pauseRevision'] != _session?.backgroundPauseRevision ||
        values['action'] is! String) {
      return;
    }
    final position = values['positionMs'];
    await _command(
      values['action'] as String,
      positionMs: position is int ? position : null,
    );
  }

  bool _keyEvent(KeyEvent event) {
    final action = switch (event.logicalKey) {
      LogicalKeyboardKey.mediaPlayPause => 'toggle',
      LogicalKeyboardKey.mediaPlay => 'play',
      LogicalKeyboardKey.mediaPause => 'pause',
      LogicalKeyboardKey.mediaStop => 'stop',
      LogicalKeyboardKey.mediaTrackNext => 'next',
      LogicalKeyboardKey.mediaTrackPrevious => 'previous',
      LogicalKeyboardKey.mediaFastForward => 'seekForward',
      LogicalKeyboardKey.mediaRewind => 'seekBackward',
      _ => null,
    };
    if (action == null || !_acceptsCommands) return false;
    // Consume key-up and repeats without applying a second toggle/skip.
    if (event is KeyDownEvent) unawaited(_command(action));
    return true;
  }

  bool get _acceptsCommands =>
      !_closed &&
      !_nativePip &&
      _session != null &&
      !_session!.closed &&
      _session!.ready &&
      !_session!.remotePlayback &&
      _session!.error.isEmpty;

  Future<void> _command(String action, {int? positionMs}) async {
    if (!_acceptsCommands) return;
    final session = _session!;
    try {
      switch (action) {
        case 'play':
          await session.setPlaying(true);
        case 'pause':
        case 'stop':
          await session.setPlaying(false);
          if (!session.closed) session.checkpoint();
        case 'toggle':
          await session.togglePlayback();
        case 'next':
        case 'previous':
          final select = action == 'next' ? _next : _previous;
          if (_navigationBusy ||
              select == null ||
              session.backgroundPlaybackBlocked) {
            return;
          }
          _navigationBusy = true;
          try {
            await select();
          } finally {
            _navigationBusy = false;
          }
        case 'seek':
        case 'seekForward':
        case 'seekBackward':
          final duration = session.player.state.duration;
          if (duration <= Duration.zero || session.backgroundPlaybackBlocked) {
            return;
          }
          if (action == 'seek' && positionMs == null) return;
          final base =
              _pendingSeek?.$4 ?? _seekingTo ?? session.player.state.position;
          final requested = action == 'seek'
              ? positionMs!
              : base.inMilliseconds +
                    (action == 'seekBackward' ? -1 : 1) *
                        _seekStepSeconds *
                        1000;
          _pendingSeek = (
            session,
            _sessionId,
            session.backgroundPauseRevision,
            Duration(milliseconds: requested.clamp(0, duration.inMilliseconds)),
          );
          await (_seekWork ??= _flushSeeks());
      }
    } catch (error) {
      AppLog.instance.warning('媒体控制', safeFailure(error).message);
    } finally {
      if (identical(session, _session)) refresh();
    }
  }

  Future<void> _flushSeeks() async {
    try {
      while (_pendingSeek != null) {
        final (session, id, revision, target) = _pendingSeek!;
        _pendingSeek = null;
        if (!_acceptsCommands ||
            id != _sessionId ||
            session.backgroundPlaybackBlocked ||
            session.backgroundPauseRevision != revision) {
          continue;
        }
        _seekingTo = target;
        try {
          await session.seek(target);
        } finally {
          if (_sessionId == id) _seekingTo = null;
        }
      }
    } finally {
      _seekWork = null;
    }
  }

  void _detachSession() {
    _session?.removeListener(refresh);
    _session?.position.removeListener(_positionChanged);
    if (_closeHook != null) _session?.removeCloseHook(_closeHook!);
    _closeHook = null;
    _session = null;
    _pendingSeek = null;
    _seekingTo = null;
    _timelineRevision = null;
    _awaitingSeekPosition = false;
    _pendingUpdate = null;
    _published = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final id = _sessionId;
    _detachSession();
    if (_owner == this) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      if (_keyboardEnabled) HardwareKeyboard.instance.removeHandler(_keyEvent);
    }
    await _invoke('clear', {'sessionId': id});
  }
}
