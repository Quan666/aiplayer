import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/network.dart';
import '../core/logger.dart';
import '../cast/position.dart';
import 'session.dart';
import 'remote_progress.dart';

/// System picture-in-picture on mobile; a reversible floating window on desktop.
class PlayerWindowMode extends ChangeNotifier {
  static const _channel = MethodChannel('app.aiplayer/window_mode');
  final bool _isIOS;
  bool _active = false, _supported = false, _closed = false;
  PlaybackSession? _session;
  _IosPlaybackTransfer? _iosTransfer;
  static int _iosRequest = 0;
  void bindSession(PlaybackSession session) {
    if (_closed || identical(_session, session)) return;
    final previous = _session;
    if (previous != null) unbindSession(previous);
    _session = session;
    if (_isIOS) session.addCloseHook(close);
  }

  /// A player page retains its native window while switching episodes. Detach
  /// the old session before closing its decoder so its iOS cleanup cannot also
  /// close the window controller needed by the next episode.
  void unbindSession(PlaybackSession session) {
    if (!identical(_session, session)) return;
    if (_isIOS) session.removeCloseHook(close);
    _session = null;
  }

  bool get active => _active;
  bool get supported => _supported;
  bool get systemPip => Platform.isAndroid || _isIOS;
  late final Future<void> _ready = _initialize();
  PlayerWindowMode({@visibleForTesting bool? isIOS})
    : _isIOS = isIOS ?? Platform.isIOS {
    unawaited(_ready);
  }
  Future<void> _initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (_isIOS && (call.method == 'progress' || call.method == 'restored')) {
        final transfer = _iosTransfer;
        final values = call.arguments;
        if (transfer == null ||
            values is! Map ||
            values['requestId'] != transfer.requestId ||
            transfer.restoring != null) {
          return;
        }
        transfer.update(values);
        if (values['error'] is String) {
          transfer.session.notice = values['error'] as String;
        }
        if (call.method == 'restored') {
          await _restoreIOS(transfer);
        } else {
          await transfer.persist();
        }
        return;
      }
      if (_closed) return;
      if (call.method == 'changed') {
        _active = call.arguments == true;
        notifyListeners();
      }
    });
    try {
      _supported = await _channel.invokeMethod<bool>('supported') ?? false;
    } on MissingPluginException {
      _supported = false;
    } on PlatformException {
      _supported = false;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> enter({required double aspectRatio}) async {
    await _ready;
    if (_closed) return;
    if (!_supported) {
      throw AppFailure(
        Platform.isAndroid
            ? '系统画中画需要 Android 8.0 或更新版本，并允许此应用使用画中画。'
            : '当前系统或播放器内核尚不支持系统小窗。',
      );
    }
    if (_isIOS) {
      await _enterIOS(aspectRatio);
      return;
    }
    // Android sends inactive before the PiP state callback. Mark the pending
    // transition now so the lifecycle observer does not pause the video.
    _active = true;
    notifyListeners();
    try {
      final entered = await _channel.invokeMethod<bool>('enter', {
        'aspectRatio': aspectRatio.isFinite
            ? aspectRatio.clamp(.42, 2.39)
            : 16 / 9,
      });
      if (entered != true) throw const AppFailure('系统未允许进入小窗，请检查画中画权限。');
    } catch (_) {
      _active = false;
      if (!_closed) notifyListeners();
      rethrow;
    }
  }

  Future<void> exit() async {
    if (_isIOS && _iosTransfer != null) {
      final transfer = _iosTransfer!;
      try {
        final value = await _channel
            .invokeMethod<dynamic>('exit', {'requestId': transfer.requestId})
            .timeout(const Duration(seconds: 7));
        if (value is Map &&
            value['requestId'] == transfer.requestId &&
            transfer.restoring == null) {
          transfer.update(value);
        }
      } on PlatformException {
        // The retained last native snapshot still provides a safe resume point.
      } on MissingPluginException {
        // The engine may already have detached during application shutdown.
      } on TimeoutException {
        AppLog.instance.warning('小窗', '系统小窗退出超时，保留最近播放进度。');
      } finally {
        await _restoreIOS(transfer);
      }
      return;
    }
    if (!_active) return;
    try {
      await _channel.invokeMethod<void>('exit');
    } on MissingPluginException {
      /* Platform has already detached. */
    } finally {
      _active = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final session = _session;
    if (session != null) unbindSession(session);
    await _ready;
    try {
      await exit();
    } finally {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _enterIOS(double aspectRatio) async {
    final session = _session;
    if (_iosTransfer != null) return;
    if (session == null ||
        session.closed ||
        !session.ready ||
        session.playbackUri == null) {
      throw const AppFailure('请等待视频加载完成后再开启小窗。');
    }
    if (session.remotePlayback) throw const AppFailure('请先结束当前投屏，再开启系统小窗。');
    final transfer = _IosPlaybackTransfer(++_iosRequest, session);
    _iosTransfer = transfer;
    _active = true;
    session.remotePlayback = true;
    notifyListeners();
    try {
      await session.player.pause();
      if (_closed || session.closed) throw const Cancelled();
      final entered = await _channel
          .invokeMethod<bool>('enter', {
            'requestId': transfer.requestId,
            'uri': session.playbackUri,
            'position': transfer.position,
            'playing': transfer.playing,
            'rate': transfer.rate,
            'volume': session.player.state.volume / 100,
            'aspectRatio': aspectRatio.isFinite
                ? aspectRatio.clamp(.42, 2.39)
                : 16 / 9,
          })
          .timeout(const Duration(seconds: 23));
      if (entered != true) throw const AppFailure('系统未允许进入画中画。');
    } catch (error) {
      // Explicitly stop a delayed native start before returning to mpv.
      try {
        final value = await _channel
            .invokeMethod<dynamic>('exit', {'requestId': transfer.requestId})
            .timeout(const Duration(seconds: 7));
        if (value is Map &&
            value['requestId'] == transfer.requestId &&
            transfer.restoring == null) {
          transfer.update(value);
        }
      } catch (_) {
        /* Original error is more useful than cleanup failure. */
      }
      await _restoreIOS(transfer);
      if (error is PlatformException) {
        throw AppFailure(error.message ?? '系统播放器无法开启此视频的小窗。');
      }
      if (error is TimeoutException) {
        throw const AppFailure('系统小窗准备超时，已恢复应用内播放。');
      }
      rethrow;
    }
  }

  Future<void> _restoreIOS(
    _IosPlaybackTransfer transfer,
  ) => transfer.restoring ??= () async {
    final session = transfer.session;
    try {
      // When close() originated in the session, the native player must no
      // longer be touched. Keep remotePlayback true so its final save cannot
      // overwrite the native PiP snapshot with the old inline position.
      if (!session.closed) {
        final restored = await restoreCastPosition(
          target: Duration(milliseconds: (transfer.position * 1000).round()),
          seek: session.seek,
          position: () => session.player.state.position,
          cancelled: () => session.closed,
        );
        if (!session.closed) {
          if (!restored) {
            throw StateError('Inline playback position was not restored');
          }
          await session.player.setRate(transfer.rate);
          session.remotePlayback = false;
          if (!_closed && transfer.playing) {
            await session.player.play();
          } else {
            await session.player.pause();
          }
        }
      }
    } catch (_) {
      session.notice = '小窗进度已保存。恢复播放失败，请从观看历史重新打开视频。';
      // Preserve the native snapshot until the player is reopened.
      session.remotePlayback = true;
      AppLog.instance.warning('小窗', '恢复应用内播放失败，已保留系统小窗进度。');
    } finally {
      await transfer.persist();
      if (identical(_iosTransfer, transfer)) {
        _iosTransfer = null;
        _active = false;
        if (!_closed) notifyListeners();
      }
    }
  }();
}

class _IosPlaybackTransfer {
  final int requestId;
  final PlaybackSession session;
  double position, duration, rate;
  bool playing;
  Future<void>? restoring;
  late final _progress = RemotePlaybackProgress(
    store: session.model.store,
    progressId: session.model.progressKey(session.media),
    watchedId: session.model.watchedKey(session.media),
    enabled: session.media.data['transient'] != true,
    onSaved: session.model.requestProgressSync,
    onError: (_) => AppLog.instance.warning('小窗', '系统小窗播放进度未能写入本机。'),
  );
  _IosPlaybackTransfer(this.requestId, this.session)
    : position = session.player.state.position.inMilliseconds / 1000,
      duration = session.player.state.duration.inMilliseconds / 1000,
      rate = session.player.state.rate,
      playing = session.player.state.playing;

  void update(Map values) {
    final time = values['position'],
        length = values['duration'],
        speed = values['rate'];
    if (time is num && time.isFinite && time >= 0) position = time.toDouble();
    if (length is num && length.isFinite && length > 0) {
      duration = length.toDouble();
    }
    if (speed is num && speed.isFinite && speed > 0 && speed <= 4) {
      rate = speed.toDouble();
    }
    if (values['playing'] is bool) playing = values['playing'] as bool;
  }

  Future<void> persist() =>
      _progress.save(position: position, duration: duration);
}
