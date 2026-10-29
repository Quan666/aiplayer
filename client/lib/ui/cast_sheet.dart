import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../cast/dlna.dart';
import '../cast/bridge.dart';
import '../cast/position.dart';
import '../cast/start_guard.dart';
import '../core/network.dart';
import '../core/logger.dart';
import '../playback/session.dart';
import '../playback/remote_progress.dart';
import '../playback/fullscreen_transition.dart';
import '../sources/source.dart';
import 'player_theme.dart';
import 'theme/app_theme.dart';

Future<void> showCastSheet(BuildContext context, PlaybackSession session) =>
    showModalBottomSheet<void>(
      context: PlayerTheme.routeContext(context),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: PlayerTheme.of(context).barrierColor,
      enableDrag: false,
      builder: (_) => PlayerTheme.surface(_CastSheet(session: session)),
    );

class _CastSheet extends StatefulWidget {
  final PlaybackSession session;
  const _CastSheet({required this.session});
  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> with WidgetsBindingObserver {
  PlaybackSession get session => widget.session;
  final _cancel = CancelToken(), _client = DlnaClient();
  final _startGuard = CastStartGuard();
  final _address = TextEditingController();
  List<DlnaDevice> _devices = [];
  DlnaDevice? _device;
  SourceAdapter? _source;
  CastBridge? _bridge;
  Timer? _timer;
  bool _foreground = true;
  int _pollFailures = 0;
  final _progressClock = Stopwatch();
  late final _progress = RemotePlaybackProgress(
    store: session.model.store,
    progressId: session.model.progressKey(session.media),
    watchedId: session.model.watchedKey(session.media),
    enabled: session.media.data['transient'] != true,
    onSaved: session.model.requestProgressSync,
    onError: (error) =>
        AppLog.instance.warning('观看记录', safeFailure(error).message),
  );
  bool _scanning = false,
      _starting = false,
      _active = false,
      _closing = false,
      _polling = false,
      _playing = true,
      _wasPlaying = false,
      _manual = false,
      _localPaused = false,
      _remoteAssigned = false,
      _restoreFailed = false;
  String _error = '';
  Duration _position = Duration.zero, _duration = Duration.zero;
  double? _seekDraft;
  double _volume = 50;
  Future<void>? _stopping;
  ScaffoldMessengerState? _messenger;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = !playbackIsBackgrounded(
      WidgetsBinding.instance.lifecycleState,
    );
    session.addCloseHook(_close);
    unawaited(_scan());
  }

  void _refresh() {
    if (mounted && !_closing && _foreground) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = !playbackIsBackgrounded(state);
    if (_foreground == foreground) return;
    _foreground = foreground;
    _timer?.cancel();
    if (foreground) {
      unawaited(_poll());
      _refresh();
    } else {
      unawaited(_saveRemoteProgress());
      _schedulePoll();
    }
  }

  void _schedulePoll() {
    _timer?.cancel();
    if (!_active || _closing) return;
    final baseSeconds = !_foreground
        ? 30
        : !_playing
        ? 15
        : 3;
    final seconds = _pollFailures > 0
        ? (3 * (1 << _pollFailures.clamp(0, 5))).clamp(baseSeconds, 60)
        : baseSeconds;
    _timer = Timer(Duration(seconds: seconds), _poll);
  }

  void _failure(Object error) {
    if (_closing) return;
    _error = safeFailure(error, action: '投屏失败').message;
    AppLog.instance.warning('投屏', _error);
    _refresh();
  }

  Future<void> _scan() async {
    if (_scanning || _closing) return;
    _scanning = true;
    _error = '';
    _refresh();
    try {
      _devices = await DlnaDiscovery().scan(cancel: _cancel);
    } on Cancelled {
      /* Sheet was dismissed. */
    } catch (e) {
      _failure(e);
    } finally {
      _scanning = false;
      _refresh();
    }
  }

  Future<void> _addManual() async {
    try {
      final uri = Uri.tryParse(_address.text.trim());
      if (uri == null) throw const AppFailure('请输入设备的 HTTP 描述地址。');
      final device = await _client.describe(uri);
      if (_closing) return;
      _devices.removeWhere((d) => d.id == device.id);
      _devices.add(device);
      _refresh();
    } catch (e) {
      _failure(e);
    }
  }

  Future<void> _start(DlnaDevice device) {
    if (_starting || _active || _closing || _restoreFailed) {
      return Future.value();
    }
    return _startGuard.run(() => _startDevice(device));
  }

  Future<void> _startDevice(DlnaDevice device) async {
    _starting = true;
    _error = '';
    _refresh();
    try {
      final location = await _startGuard.acquire(
        session.resolvePlaybackLocation(),
        (_) {},
      );
      if (location == null) throw const AppFailure('视频尚未关联本机来源。');
      final connection = await _startGuard.acquire(
        Socket.connect(
          device.control.host,
          device.control.port,
          timeout: const Duration(seconds: 5),
        ),
        (value) => value.destroy(),
      );
      final local = connection.address, remote = connection.remoteAddress;
      connection.destroy();
      final source = await _startGuard.acquire(
        session.model.adapter(location['source'] as String),
        (value) => value.close(),
      );
      _source = source;
      final bridge = await _startGuard.acquire(
        CastBridge.open(
          source,
          location['path'] as String,
          localAddress: local,
          renderer: remote,
          onError: (error) {
            if (_closing) return;
            session.notice = error.message;
            _failure(error);
          },
        ),
        (value) => value.close(),
      );
      _bridge = bridge;
      _device = device;
      if (_closing || session.closed) throw const Cancelled();
      _position = session.player.state.position;
      _duration = session.player.state.duration;
      _wasPlaying = session.player.state.playing;
      await session.player.pause();
      _localPaused = true;
      session.remotePlayback = true;
      if (_closing || session.closed) throw const Cancelled();
      // Assignment may have reached the renderer even if its HTTP reply is
      // cancelled. Always issue Stop after cancelling this in-flight request.
      _remoteAssigned = true;
      await _client.open(
        device,
        bridge.uri,
        session.model.displayTitle(session.media),
        bridge.mime,
      );
      if (_closing || session.closed) throw const Cancelled();
      _active = true;
      if (_position > const Duration(seconds: 1)) {
        try {
          await _client.seek(device, _position);
        } catch (_) {
          if (!_closing) _error = '设备已开始播放，但不支持从当前进度定位。';
        }
      }
      if (_closing || session.closed) throw const Cancelled();
      unawaited(_poll());
      AppLog.instance.info('投屏', '已连接所选局域网设备。');
    } catch (error) {
      if (!_closing) {
        await _stopRenderer();
        await _releaseRelay();
        await _restoreLocal();
        if (error is! Cancelled) _failure(error);
      }
    } finally {
      _starting = false;
      _refresh();
    }
  }

  Future<void> _stopRenderer() async {
    if (!_remoteAssigned || _device == null) return;
    final device = _device!;
    _remoteAssigned = false;
    // The command client is aborted on close. A separate bounded client sends
    // the final Stop only after the cancelled start sequence has unwound.
    final stopClient = DlnaClient(timeout: const Duration(seconds: 2));
    try {
      await stopClient.stop(device).timeout(const Duration(seconds: 2));
    } catch (_) {
      AppLog.instance.warning('投屏', '设备未确认停止；本机视频连接已关闭。');
    } finally {
      stopClient.close();
    }
  }

  Future<void> _releaseRelay() async {
    final bridge = _bridge, source = _source;
    _bridge = null;
    _source = null;
    try {
      await bridge?.close();
    } catch (_) {}
    try {
      await source?.close();
    } catch (_) {}
  }

  Future<void> _restoreLocal() async {
    if (!_localPaused || session.closed) return;
    _localPaused = false;
    final restored = await restoreCastPosition(
      target: _position,
      seek: session.seek,
      position: () => session.player.state.position,
      cancelled: () => session.closed,
    );
    if (session.closed) return;
    if (!restored) {
      _restoreFailed = true;
      session.remotePlayback = true;
      try {
        await session.player.pause();
      } catch (_) {}
      session.notice = '恢复进度失败，请重新打开视频续播。';
      AppLog.instance.warning('投屏', session.notice);
      final messenger = _messenger;
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(session.notice)));
      }
      session.model.changed();
      return;
    }
    session.remotePlayback = false;
    if (_wasPlaying) {
      try {
        await session.player.play();
      } catch (_) {
        session.notice = '本机播放恢复失败，请重新打开视频。';
      }
    }
  }

  Future<void> _saveRemoteProgress() {
    if (!_active) return Future.value();
    _progressClock
      ..reset()
      ..start();
    return _progress.save(
      position: _position.inMilliseconds / 1000,
      duration: _duration.inMilliseconds / 1000,
    );
  }

  Future<void> _poll() async {
    if (!_active || _closing || _polling) return;
    _timer?.cancel();
    _polling = true;
    try {
      final before = (_position, _duration, _playing);
      final values = await _client.command(_device!, 'GetPositionInfo');
      if (_closing) return;
      final length = DlnaClient.parseTime(values['TrackDuration']);
      if (length > Duration.zero) _duration = length;
      final position = values['RelTime'];
      if (position != null && position != 'NOT_IMPLEMENTED') {
        _position = DlnaClient.parseTime(position);
      }
      final state = await _client.command(_device!, 'GetTransportInfo');
      if (_closing) return;
      _playing = state['CurrentTransportState'] == 'PLAYING';
      _pollFailures = 0;
      if (!_progressClock.isRunning ||
          (before != (_position, _duration, _playing) &&
              (_progressClock.elapsed >= const Duration(seconds: 10) ||
                  before.$3 != _playing))) {
        unawaited(_saveRemoteProgress());
      }
      if (before != (_position, _duration, _playing)) _refresh();
    } catch (e) {
      _pollFailures++;
      _failure(e);
    } finally {
      _polling = false;
      _schedulePoll();
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
      _error = '';
      unawaited(_poll());
      _refresh();
    } catch (e) {
      _failure(e);
    }
  }

  Future<void> _close() => _stopping ??= _stop();
  Future<void> _stop() async {
    _closing = true;
    _cancel.cancel();
    _timer?.cancel();
    _startGuard.cancel();
    final saving = _saveRemoteProgress();
    _client.close();
    await _startGuard.settle();
    await _stopRenderer();
    await _releaseRelay();
    await _restoreLocal();
    await saving;
    session.removeCloseHook(_close);
    _active = false;
    try {
      session.model.changed();
    } catch (_) {
      /* Application may already be closing. */
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close());
    _address.dispose();
    super.dispose();
  }

  String _clock(Duration value) {
    final s = value.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => PlayerSheet(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(Icons.cast_rounded, size: 22),
              ),
              Expanded(
                child: Text(
                  _active ? _device!.name : '投屏',
                  style: PlayerTheme.of(context).panelTitleStyle,
                ),
              ),
              IconButton(
                tooltip: _active ? '停止投屏并返回' : '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: _closing
                    ? null
                    : () async {
                        await _close();
                        if (context.mounted) Navigator.pop(context);
                      },
              ),
            ],
          ),
          if (!_active) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '选择同一局域网的 DLNA 设备。视频直接传给所选设备，格式由设备支持，不转码。',
                style: PlayerTheme.of(context).captionStyle,
              ),
            ),
            if (_scanning || _starting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            for (final d in _devices)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: const Icon(Icons.tv_outlined),
                title: Text(d.name),
                subtitle: Text(d.control.host),
                onTap: _starting || _restoreFailed ? null : () => _start(d),
              ),
            if (!_scanning && _devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('未发现设备，请确认电视已开启 DLNA 接收。'),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: _scanning || _starting ? null : _scan,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新查找'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _manual = !_manual),
                  icon: Icon(
                    _manual ? Icons.expand_less_rounded : Icons.link_rounded,
                    size: 18,
                  ),
                  label: const Text('手动地址'),
                ),
              ],
            ),
            if (_manual) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (_) => _addManual(),
                      decoration: const InputDecoration(
                        labelText: '设备描述地址',
                        hintText: 'http://192.168.1.10:端口/description.xml',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    style: PlayerTheme.of(context).filledIconButtonStyle,
                    tooltip: '添加投屏设备',
                    onPressed: _starting ? null : _addManual,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ],
          ] else ...[
            Text(
              session.model.displayTitle(session.media),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.of(context).secondary,
            ),
            Slider(
              value: (_seekDraft ?? _position.inMilliseconds.toDouble()).clamp(
                0,
                _duration.inMilliseconds.toDouble().clamp(1, double.maxFinite),
              ),
              max: _duration.inMilliseconds.toDouble().clamp(
                1,
                double.maxFinite,
              ),
              onChanged: (v) => setState(() => _seekDraft = v),
              onChangeEnd: (v) {
                _seekDraft = null;
                _action(
                  () =>
                      _client.seek(_device!, Duration(milliseconds: v.round())),
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(_clock(_position)), Text(_clock(_duration))],
            ),
            Center(
              child: IconButton.filledTonal(
                style: PlayerTheme.of(context).filledIconButtonStyle,
                iconSize: 42,
                tooltip: _playing ? '暂停投屏' : '继续投屏',
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                onPressed: () => _action(
                  () => _playing
                      ? _client.pause(_device!)
                      : _client.play(_device!),
                ),
              ),
            ),
            if (_device!.volumeControl != null)
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined, size: 20),
                  Expanded(
                    child: Slider(
                      value: _volume,
                      max: 100,
                      onChanged: (v) => setState(() => _volume = v),
                      onChangeEnd: (v) =>
                          _action(() => _client.volume(_device!, v.round())),
                    ),
                  ),
                ],
              ),
          ],
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error, style: AppStyles.of(context).errorCaption),
            ),
        ],
      ),
    ),
  );
}
