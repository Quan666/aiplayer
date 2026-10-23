import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:media_kit/media_kit.dart';

import '../core/network.dart';
import '../core/logger.dart';
import '../data/media_previews.dart';
import '../sources/range_bridge.dart';
import '../sources/source.dart';

enum SeekPreviewStatus { idle, loading, ready, unavailable }

typedef SeekPreviewCapture =
    Future<SeekPreviewFrame> Function(Duration position, CancelToken cancel);

class SeekPreviewFrame {
  final Duration position;
  final Uint8List bytes;
  const SeekPreviewFrame(this.position, this.bytes);
}

/// A single, silent software decoder, separate from the playing video. Drag
/// events replace one pending target while the current frame finishes decoding.
/// Network credentials stay inside the client-owned range bridge.
class SeekPreviewController extends ValueNotifier<SeekPreviewFrame?> {
  final Future<SourceAdapter> Function() openSource;
  final String path;
  final void Function(Object)? onError;
  final SeekPreviewCapture? capture;
  final Duration requestTimeout;
  SeekPreviewStatus status = SeekPreviewStatus.idle;
  Duration? _capturing;
  int _retryAfterMs = 0;
  Timer? _debounce, _idle;
  Player? _player;
  SourceAdapter? _source;
  RangeBridge? _bridge;
  CancelToken? _cancel;
  Future<void>? _work;
  Future<void>? _retiring;
  Duration? _target;
  int _generation = 0;
  final _clock = Stopwatch()..start();
  int _lastCaptureMs = -200;
  bool _closed = false;
  SeekPreviewController({
    required this.openSource,
    required this.path,
    this.onError,
    this.capture,
    this.requestTimeout = const Duration(seconds: 8),
  }) : super(null);

  void request(Duration target) {
    if (_closed) return;
    _idle?.cancel();
    target = target.isNegative
        ? Duration.zero
        : Duration(milliseconds: (target.inMilliseconds ~/ 500) * 500);
    if (_clock.elapsedMilliseconds < _retryAfterMs) return;
    if (_retiring != null) {
      _target = target;
      status = SeekPreviewStatus.unavailable;
      notifyListeners();
      return;
    }
    if (_target == target) return;
    if (_capturing == target && _cancel?.cancelled == false) {
      // Reversing a drag back to the frame in flight discards the queued seek.
      _target = null;
      return;
    }
    if (_capturing == null && value?.position == target) {
      _target = null;
      _debounce?.cancel();
      _debounce = null;
      return;
    }
    _target = target;
    // Requests during a drag replace only the queued target. Let the current
    // decode finish, otherwise continuous finger movement starves every frame.
    status = value == null
        ? SeekPreviewStatus.loading
        : SeekPreviewStatus.ready;
    notifyListeners();
    _debounce ??= Timer(const Duration(milliseconds: 100), () {
      _debounce = null;
      _start();
    });
  }

  void _start() {
    if (_closed || _work != null || _retiring != null || _target == null) {
      return;
    }
    status = value == null
        ? SeekPreviewStatus.loading
        : SeekPreviewStatus.ready;
    notifyListeners();
    _work = _drain().whenComplete(() {
      _work = null;
      if (!_closed && _target != null) _start();
    });
  }

  Future<void> _open(CancelToken cancel) async {
    if (_player != null) return;
    final connecting = openSource().then((source) async {
      if (cancel.cancelled) {
        await source.close();
        throw const Cancelled();
      }
      return source;
    });
    final source = await Future.any([
      connecting,
      cancel.whenCancelled.then<SourceAdapter>((_) => throw const Cancelled()),
    ]);
    _source = source;
    String uri;
    if (source is LocalSource) {
      uri = path;
    } else {
      final opening = RangeBridge.open(source, path, cancel: cancel).then((
        bridge,
      ) async {
        if (cancel.cancelled) {
          await bridge.close();
          throw const Cancelled();
        }
        return bridge;
      });
      _bridge = await Future.any([
        opening,
        cancel.whenCancelled.then<RangeBridge>((_) => throw const Cancelled()),
      ]);
      cancel.check();
      uri = _bridge!.uri.toString();
    }
    final player = _player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        muted: true,
        bufferSize: 1024 * 1024,
        title: 'AIPlayer seek preview',
        logLevel: MPVLogLevel.error,
      ),
    );
    final native = player.platform as NativePlayer;
    for (final option in const {
      'vid': 'auto',
      'aid': 'no',
      'sid': 'no',
      'hwdec': 'no',
      'cache': 'no',
      'demuxer-readahead-secs': '0',
      'network-timeout': '4',
      'vd-lavc-threads': '2',
      'hr-seek': 'yes',
      'hr-seek-framedrop': 'no',
    }.entries) {
      cancel.check();
      await native.setProperty(option.key, option.value);
    }
    await player.open(Media(uri), play: false);
    for (var i = 0; i < 60; i++) {
      cancel.check();
      if ((player.state.videoParams.w ?? 0) > 0) return;
      await _tick(cancel);
    }
    throw const AppFailure('预览画面尚未就绪');
  }

  Future<void> _tick(CancelToken cancel) async {
    await Future.any([
      Future<void>.delayed(const Duration(milliseconds: 50)),
      cancel.whenCancelled,
    ]);
    cancel.check();
  }

  Future<SeekPreviewFrame> _captureNative(
    Duration target,
    CancelToken cancel,
  ) async {
    await _open(cancel);
    cancel.check();
    final player = _player!;
    final native = player.platform as NativePlayer;
    final duration = player.state.duration;
    if (duration > Duration.zero && target >= duration) {
      target = Duration(
        milliseconds: (duration.inMilliseconds - 250).clamp(
          0,
          duration.inMilliseconds,
        ),
      );
    }
    await player.seek(target);
    var settled = 0;
    for (var i = 0; i < 80; i++) {
      await _tick(cancel);
      final seeking = await native.getProperty('seeking');
      final seconds = double.tryParse(await native.getProperty('time-pos'));
      if (seeking == 'no' &&
          seconds != null &&
          (seconds * 1000 - target.inMilliseconds).abs() < 600) {
        if (++settled >= 2) break;
      } else {
        settled = 0;
      }
    }
    if (settled < 2) throw const AppFailure('预览定位超时');
    for (var attempt = 0; attempt < 3; attempt++) {
      cancel.check();
      final bytes = await player.screenshot(includeLibassSubtitles: false);
      if (bytes != null && bytes.isNotEmpty) {
        cancel.check();
        final encoded = await encodePreviewImage(bytes);
        cancel.check();
        return SeekPreviewFrame(target, encoded);
      }
      await _tick(cancel);
    }
    throw const AppFailure('暂时无法读取预览画面');
  }

  Future<void> _drain() async {
    while (!_closed && _target != null) {
      final generation = _generation;
      final target = _capturing = _target!;
      _target = null;
      final cancel = _cancel = CancelToken();
      final deadline = Timer(requestTimeout, cancel.cancel);
      try {
        while (_clock.elapsedMilliseconds - _lastCaptureMs < 200) {
          await _tick(cancel);
        }
        _lastCaptureMs = _clock.elapsedMilliseconds;
        final frame = await Future.any([
          (capture ?? _captureNative)(target, cancel),
          cancel.whenCancelled.then<SeekPreviewFrame>(
            (_) => throw const Cancelled(),
          ),
        ]);
        cancel.check();
        if (!_closed && generation == _generation) {
          final previous = value;
          status = SeekPreviewStatus.ready;
          value = frame;
          if (previous != null) unawaited(MemoryImage(previous.bytes).evict());
        }
      } catch (error) {
        if (!_closed && generation == _generation) {
          _target = null;
          _retryAfterMs = _clock.elapsedMilliseconds + 2000;
          status = SeekPreviewStatus.unavailable;
          notifyListeners();
          onError?.call(error);
          AppLog.instance.info('预览', '拖动预览暂不可用，播放不受影响。');
        }
        // Close the bridge first to unblock remote reads. NativePlayer queues
        // dispose behind in-flight native work, so its handle stays valid.
        unawaited(_retireDecoder());
        break;
      } finally {
        deadline.cancel();
        _capturing = null;
        if (identical(_cancel, cancel)) _cancel = null;
      }
    }
  }

  void end() {
    if (_closed) return;
    _generation++;
    _target = null;
    status = SeekPreviewStatus.idle;
    _retryAfterMs = 0;
    _cancel?.cancel();
    _debounce?.cancel();
    _debounce = null;
    final previous = value;
    value = null;
    if (previous == null) notifyListeners();
    if (previous != null) unawaited(MemoryImage(previous.bytes).evict());
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 2), () {
      _cancel?.cancel();
      unawaited(_retireDecoder());
    });
  }

  Future<void> _retireDecoder() {
    if (!_closed && status == SeekPreviewStatus.loading) {
      // A new drag can arrive before cancellation starts native cleanup. Do not
      // show an unbounded spinner while a disconnected decoder is retiring.
      status = SeekPreviewStatus.unavailable;
      notifyListeners();
    }
    return _retiring ??= _closeDecoder().whenComplete(() {
      _retiring = null;
      _start();
    });
  }

  Future<void> _closeDecoder() async {
    final player = _player;
    final bridge = _bridge;
    final source = _source;
    final cancelled = _cancel?.cancelled == true;
    _player = null;
    _bridge = null;
    _source = null;
    _cancel = null;
    for (final close in [
      if (bridge != null) bridge.close,
      if (player != null) player.dispose,
    ]) {
      try {
        await close();
      } catch (_) {
        /* Optional preview cleanup. */
      }
    }
    if (source != null) {
      Future<void> closeSource() async {
        try {
          await source.close();
        } catch (_) {
          /* Disconnected source. */
        }
      }

      if (cancelled) {
        // A disconnected SMB operation can still be unwinding in its worker.
        // The decoder and bridge are gone; do not delay the next video for it.
        unawaited(closeSource());
      } else {
        await closeSource();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _target = null;
    _debounce?.cancel();
    _idle?.cancel();
    _cancel?.cancel();
    await _work;
    try {
      await _retireDecoder().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Decoder cleanup may still be waiting on a remote read; never hold the
      // playback route open for an optional thumbnail.
    }
    final previous = value;
    if (previous != null) await MemoryImage(previous.bytes).evict();
    super.dispose();
  }
}
