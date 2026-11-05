import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as images;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
// Reuse media_kit's platform-specific resolved native library.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../core/logger.dart';
import '../playback/native_property_reader.dart';
import '../sources/range_bridge.dart';
import '../sources/source.dart';
import 'preview_quality.dart';
import 'source_preview.dart';

export 'preview_quality.dart';

/// Local image metadata. SyncArtwork shares portable images and reconstructs
/// cache paths on the receiving device.
class MediaPreview {
  static const formatVersion = 3;
  final Uint8List bytes;
  final double duration;
  final int? width, height;
  final double? capturedPosition;
  const MediaPreview(
    this.bytes,
    this.duration,
    this.width,
    this.height, {
    this.capturedPosition,
  });
}

class MediaPreviewRequest {
  final String id, source, path;
  final String revision;
  final int size;
  final double? position;
  const MediaPreviewRequest(
    this.id,
    this.source,
    this.path,
    this.size, {
    this.revision = '',
    this.position,
  });

  /// Album covers stay at the start, independently of film resume
  /// positions. A solid/black first frame is still a valid album thumbnail.
  bool get firstFrame => id.startsWith('browse-album-') && position == null;
  bool get originalResolution =>
      firstFrame && id.startsWith('browse-album-original-');

  String get contentFingerprint => sha256
      .convert(utf8.encode(jsonEncode([source, path, size, revision])))
      .toString();
  String get fingerprint {
    if (firstFrame) {
      return albumPreviewFingerprint(
        contentFingerprint,
        originalResolution: originalResolution,
      );
    }
    return position == null
        ? contentFingerprint
        : sha256
              .convert(utf8.encode('$contentFingerprint:${position!.round()}'))
              .toString();
  }
}

typedef PreviewCapture = Future<MediaPreview> Function(
  String uri,
  CancelToken cancel,
);

/// One decoder at a time, at most 64 pending requests. Playback cancels the
/// current request and waits for its native resources to close before opening.
class MediaPreviewQueue {
  final Directory directory;
  final Future<SourceAdapter> Function(String) openSource;
  final bool Function(MediaPreviewRequest) isCurrent;
  final FutureOr<void> Function(MediaPreviewRequest, String, MediaPreview)
  onReady;
  final void Function(Object) onError;
  final VoidCallback? onCapacity;
  final List<Duration> retryDelays;
  final PreviewCapture capture;
  final bool _defaultCapture;
  final _pending = <String, MediaPreviewRequest>{};
  final _failed = <String, ({String source, int attempts, DateTime retryAt})>{};
  final _retries = <String, MediaPreviewRequest>{};
  CancelToken? _cancel;
  MediaPreviewRequest? _active;
  Future<void>? _working;
  Timer? _startTimer;
  Timer? _retryTimer;
  int _paused = 0;
  bool _closed = false;
  bool _requeueActive = false;

  /// The persistence callback joins the current attempt, so lifecycle pause,
  /// cache maintenance and close cancel a blocked commit without a new frame.
  CancelToken? get activeCancellation => _cancel;
  bool get isFull => _pending.length >= 64;

  MediaPreviewQueue({
    required this.directory,
    required this.openSource,
    required this.isCurrent,
    required this.onReady,
    required this.onError,
    this.onCapacity,
    this.retryDelays = const [Duration(seconds: 5), Duration(seconds: 30)],
    PreviewCapture? capture,
  }) : capture = capture ?? captureMediaPreview,
       _defaultCapture = capture == null;

  bool schedule(MediaPreviewRequest request, {bool priority = false}) {
    final failureKey = _failureKey(request);
    final failure = _failed[failureKey];
    if (!_closed && failure != null) {
      // A scroll cancels demand, not its backoff. A later visible visit can
      // rejoin the same bounded retry without resetting the attempt budget.
      if (failure.attempts <= retryDelays.length &&
          !_retries.containsKey(failureKey) &&
          _retries.length < 64 &&
          _active?.fingerprint != request.fingerprint &&
          _pending[request.id]?.fingerprint != request.fingerprint) {
        _retries[failureKey] = request;
        _armRetry();
        return true;
      }
      return false;
    }
    final pending = _pending[request.id];
    if (_closed ||
        pending?.fingerprint == request.fingerprint ||
        (_active?.id == request.id &&
            _active?.fingerprint == request.fingerprint &&
            _cancel?.cancelled != true) ||
        _failed.containsKey('${request.id}:${request.fingerprint}') ||
        (pending == null && _pending.length >= 64 && !priority)) {
      return false;
    }
    if (priority) {
      final older = Map<String, MediaPreviewRequest>.from(_pending)
        ..remove(request.id);
      _pending.clear();
      _pending[request.id] = request;
      for (final entry in older.entries.take(63)) {
        _pending[entry.key] = entry.value;
      }
    } else {
      _pending[request.id] = request;
    }
    if (_active?.id == request.id &&
        _active?.fingerprint != request.fingerprint) {
      _requeueActive = false;
      _cancel?.cancel();
    }
    _start();
    return true;
  }

  void _start() {
    if (_closed ||
        _paused > 0 ||
        _active != null ||
        _working != null ||
        _startTimer != null ||
        _pending.isEmpty) {
      return;
    }
    // A pending start is cancellable, so tapping play never waits for this
    // debounce before the foreground decoder can begin opening the video.
    _startTimer = Timer(const Duration(milliseconds: 120), () {
      _startTimer = null;
      _working = _drain()
          .catchError((Object error) => onError(error))
          .whenComplete(() {
            _working = null;
            _start();
          });
    });
  }

  Future<void> _drain() async {
    while (!_closed && _paused == 0 && _pending.isNotEmpty) {
      final request = _pending.remove(_pending.keys.first)!;
      if (!isCurrent(request)) continue;
      final cancel = _cancel = CancelToken();
      _active = request;
      _capacityAvailable();
      _requeueActive = false;
      var timedOut = false;
      final deadline = Timer(const Duration(seconds: 30), () {
        if (cancel.cancelled) return;
        timedOut = true;
        _requeueActive = false;
        cancel.cancel();
      });
      void cancelled() {
        if (!_closed && _requeueActive && isCurrent(request)) {
          // A new path or credential retry may already be waiting for this ID.
          // The cancelled generation must never overwrite that request.
          _pending.putIfAbsent(request.id, () => request);
        } else if (timedOut) {
          _rememberFailure(request);
          onError(const AppFailure('生成视频封面超时，仍可正常播放。'));
        }
      }

      SourceAdapter? source;
      RangeBridge? bridge;
      var sourceClosed = false;
      Future<void> closeSource() async {
        final value = source;
        if (value == null || sourceClosed) return;
        sourceClosed = true;
        try {
          await value.close();
        } catch (_) {
          // A disconnected network source can also fail while closing.
        }
      }

      try {
        // Connecting SMB can outlast a cancellation. Close any late connection
        // without making the foreground player wait for that network attempt.
        final connecting = openSource(request.source).then((value) async {
          if (cancel.cancelled) {
            await value.close();
            throw const Cancelled();
          }
          return value;
        });
        source = await Future.any([
          connecting,
          cancel.whenCancelled.then<SourceAdapter>(
            (_) => throw const Cancelled(),
          ),
        ]);
        unawaited(cancel.whenCancelled.then((_) => closeSource()));
        cancel.check();
        String uri;
        if (source is LocalSource) {
          await source.stat(request.path);
          uri = request.path;
        } else {
          final opening =
              RangeBridge.open(source!, request.path, cancel: cancel).then((
                value,
              ) async {
                if (cancel.cancelled) {
                  await value.close();
                  throw const Cancelled();
                }
                return value;
              });
          bridge = await Future.any([
            opening,
            cancel.whenCancelled.then<RangeBridge>(
              (_) => throw const Cancelled(),
            ),
          ]);
          uri = bridge!.uri.toString();
        }
        cancel.check();
        final result = _defaultCapture
            ? await captureMediaPreview(
                uri,
                cancel,
                position: request.position,
                firstFrame: request.firstFrame,
                originalResolution: request.originalResolution,
              )
            : await capture(uri, cancel);
        cancel.check();
        if (!isCurrent(request)) continue;
        await directory.create(recursive: true);
        final name = sha256.convert(utf8.encode(request.id)).toString();
        final destination = p.join(
          directory.path,
          '$name-${request.fingerprint.substring(0, 12)}.jpg',
        );
        final temporary = File('$destination.tmp');
        await temporary.writeAsBytes(result.bytes, flush: true);
        if (!cancel.cancelled && !_closed && isCurrent(request)) {
          await temporary.rename(destination);
          if (!_closed && !cancel.cancelled && isCurrent(request)) {
            await onReady(request, destination, result);
            cancel.check();
            if (_closed || !isCurrent(request)) continue;
            // Persisting is part of the attempt. Clearing its failure budget
            // at decode completion would retry a failing database forever.
            _failed.remove(_failureKey(request));
            // Retire the old native-PNG cache only after the replacement has
            // been persisted and published successfully.
            try {
              final legacy = File(p.join(directory.path, '$name.png'));
              if (await legacy.exists()) await legacy.delete();
            } on FileSystemException {
              // A leftover cache is harmless and removal still handles it.
            }
          }
        } else if (await temporary.exists()) {
          await temporary.delete();
        }
      } on Cancelled {
        cancelled();
      } catch (error) {
        if (cancel.cancelled) {
          // Closing HTTP/SMB to cancel an operation can report a transport
          // error instead of Cancelled. Do not poison an explicit retry.
          cancelled();
        } else {
          _rememberFailure(request);
          onError(error);
        }
      } finally {
        deadline.cancel();
        try {
          await bridge?.close();
        } catch (_) {
          // The player may already have abandoned its bridge request.
        }
        // A native SMB worker may still be unwinding a disconnected read. Its
        // close can finish in the background once playback requests priority;
        // the thumbnail decoder itself has already been disposed by capture.
        await Future.any([closeSource(), cancel.whenCancelled]);
        _active = null;
        _cancel = null;
      }
    }
  }

  Future<void> pause() async {
    _paused++;
    _startTimer?.cancel();
    _startTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_cancel != null && !_cancel!.cancelled) _requeueActive = true;
    _cancel?.cancel();
    await _working;
  }

  /// The caller pauses and awaits native work before clearing its disk cache.
  void clearPending() {
    _pending.clear();
    _failed.clear();
    _retries.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _requeueActive = false;
  }

  void resume() {
    if (_paused > 0) _paused--;
    _retryReady();
    _start();
  }

  void forget(String id) {
    _failed.removeWhere((entry, _) => entry.startsWith('$id:'));
    cancelPending(id);
  }

  void _rememberFailure(MediaPreviewRequest request) {
    final key = _failureKey(request);
    final attempts = (_failed[key]?.attempts ?? 0) + 1;
    while (_failed.length >= 256) {
      final retired = _failed.keys.first;
      _failed.remove(retired);
      _retries.remove(retired);
    }
    final retry = attempts <= retryDelays.length;
    _failed[key] = (
      source: request.source,
      attempts: attempts,
      retryAt: DateTime.now().add(
        retry ? retryDelays[attempts - 1] : Duration.zero,
      ),
    );
    if (retry && (_retries.containsKey(key) || _retries.length < 64)) {
      _retries[key] = request;
    }
    _armRetry();
  }

  String _failureKey(MediaPreviewRequest request) =>
      '${request.id}:${request.fingerprint}';

  void _capacityAvailable() {
    if (_closed) return;
    _retryReady();
    onCapacity?.call();
  }

  void _armRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_closed || _paused > 0 || isFull || _retries.isEmpty) return;
    DateTime? first;
    for (final key in _retries.keys) {
      final date = _failed[key]?.retryAt;
      if (date != null && (first == null || date.isBefore(first))) first = date;
    }
    if (first == null) return;
    final delay = first.difference(DateTime.now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, _retryReady);
  }

  void _retryReady() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_closed || _paused > 0) return;
    final now = DateTime.now();
    for (final key in _retries.keys.toList(growable: false)) {
      if (isFull) break;
      final failure = _failed[key];
      if (failure == null || failure.retryAt.isAfter(now)) continue;
      final request = _retries.remove(key)!;
      if (!isCurrent(request)) continue;
      _pending.putIfAbsent(request.id, () => request);
    }
    _armRetry();
    _start();
  }

  /// Source edits revoke active captures and bounded pending work immediately.
  /// A corrected address or credential can retry its previous failures.
  void cancelSource(String source) {
    _pending.removeWhere((_, request) => request.source == source);
    _failed.removeWhere((_, failure) => failure.source == source);
    _retries.removeWhere((_, request) => request.source == source);
    if (_active?.source == source) {
      _requeueActive = false;
      _cancel?.cancel();
    }
    _capacityAvailable();
  }

  void cancelPending(String id) {
    _pending.remove(id);
    _retries.removeWhere((_, request) => request.id == id);
    if (_active?.id == id) {
      _requeueActive = false;
      _cancel?.cancel();
    }
    _capacityAvailable();
  }

  Future<void> close() async {
    _closed = true;
    _startTimer?.cancel();
    _startTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retries.clear();
    _requeueActive = false;
    _pending.clear();
    _cancel?.cancel();
    await _working;
  }
}

/// mpv's null video output keeps this decoder invisible. Explicitly enabling
/// video is needed because media_kit disables it until a controller attaches.
Future<MediaPreview> captureMediaPreview(
  String uri,
  CancelToken cancel, {
  double? position,
  bool firstFrame = false,
  bool originalResolution = false,
}) async {
  cancel.check();
  final player = Player(
    configuration: const PlayerConfiguration(
      vo: 'null',
      muted: true,
      bufferSize: 2 * 1024 * 1024,
      title: 'AIPlayer preview',
      logLevel: MPVLogLevel.error,
    ),
  );
  final native = player.platform as NativePlayer;
  NativePropertyReader? properties;
  var stage = '初始化封面解码器';
  final decoderMessages = <String>[];
  void rememberDecoderMessage(String message) {
    // mpv may echo its input. Remove this exact URL/path before applying the
    // global credential sanitizer; diagnostics must never reveal file paths.
    var clean = message.replaceAll(uri, '[视频位置已隐藏]');
    if (!uri.contains('://')) {
      clean = clean.replaceAll(Uri.file(uri).toString(), '[视频位置已隐藏]');
    }
    clean = AppLog.instance
        .sanitize(clean)
        .replaceAll(RegExp(r'''(?:[A-Za-z]:[\\/]|/)[^\s<>"']+'''), '[路径已隐藏]')
        .trim();
    if (clean.isEmpty || decoderMessages.contains(clean)) return;
    decoderMessages.add(
      clean.length > 180 ? '${clean.substring(0, 180)}…' : clean,
    );
    if (decoderMessages.length > 3) decoderMessages.removeAt(0);
  }

  final errors = player.stream.error.listen(rememberDecoderMessage);
  final logs = player.stream.log.listen(
    (log) => rememberDecoderMessage(log.text),
  );
  try {
    for (final option in {
      'vid': 'auto',
      'aid': 'no',
      'sid': 'no',
      'hwdec': 'no',
      'cache': 'no',
      'demuxer-readahead-secs': '0',
      'network-timeout': '5',
      'vd-lavc-threads': '2',
      'hr-seek': 'yes',
      'hr-seek-framedrop': 'no',
    }.entries) {
      cancel.check();
      await native.setProperty(option.key, option.value);
    }
    cancel.check();
    stage = '读取视频轨道';
    await player.open(Media(uri), play: false);
    Future<void> tick() async {
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 100)),
        cancel.whenCancelled,
      ]);
      cancel.check();
    }

    for (var i = 0; i < 100; i++) {
      cancel.check();
      if ((player.state.videoParams.w ?? 0) > 0 &&
          (firstFrame || player.state.duration > Duration.zero)) {
        break;
      }
      await tick();
    }
    final duration = player.state.duration.inMilliseconds / 1000;
    final dimensions = player.state.videoParams;
    if ((dimensions.w ?? 0) <= 0) {
      throw const AppFailure('未能读取视频画面。');
    }
    // mpv's built-in format filter uses libswscale directly. Older Android
    // binaries omit FFmpeg's lavfi scale filter, so installing that filter
    // before open can disable video output entirely. Read source dimensions
    // first, then bound pixels before screenshot-raw copies and JPEG-encodes
    // them in media_kit's helper isolate.
    final width = firstFrame ? dimensions.dw ?? dimensions.w! : dimensions.w!;
    final height = firstFrame
        ? dimensions.dh ?? dimensions.h ?? 0
        : dimensions.h ?? 0;
    if (height <= 0) throw const AppFailure('未能读取视频画面。');
    properties = NativePropertyReader(
      libraryPath: NativeLibrary.path,
      handleAddress: await player.handle,
    );
    final original = firstFrame && originalResolution;
    var rotation = 0;
    if (firstFrame) {
      // video-params includes container orientation as well as frame metadata.
      // video-dec-params alone misses container-only rotation on some codecs.
      final values = await properties.read(const ['video-params/rotate']);
      cancel.check();
      rotation =
          ((int.tryParse(values['video-params/rotate'] ?? '') ?? 0) % 360 +
              360) %
          360;
    }
    // One decoder and one screenshot worker are shared by the whole queue.
    // Reject oversized rasters instead of silently reducing an original.
    if (original && width * height > 40 * 1024 * 1024) {
      throw const AppFailure('视频画面超过 4000 万像素，无法生成原分辨率封面。');
    }
    final scale = original ? 1.0 : math.min(1.0, 480 / math.max(width, height));
    await native.setProperty(
      'vf',
      'format=w=${math.max(1, (width * scale).round())}'
          ':h=${math.max(1, (height * scale).round())}:convert=yes',
    );
    cancel.check();
    final positions = firstFrame
        ? const [0.0]
        : previewCapturePositions(duration, position: position);
    for (final target in positions) {
      stage = '定位封面画面';
      await player.seek(Duration(milliseconds: (target * 1000).round()));
      // The seek command completes when queued, not when its frame is ready.
      // Especially with MKV/B-frames, time-pos can already show the requested
      // position while screenshot-raw still returns the previous black frame.
      // Require the native seek to finish and the position to remain settled
      // through two polls before touching the screenshot buffer.
      var settled = 0;
      double? actual;
      for (var i = 0; i < 40; i++) {
        await tick();
        // media_kit's Future getter performs a synchronous native lock wait;
        // share a bounded reader worker for every poll of this decoder.
        final values = await properties.read(const ['seeking', 'time-pos']);
        cancel.check();
        actual = double.tryParse(values['time-pos'] ?? '');
        if (values['seeking'] == 'no' &&
            actual != null &&
            (actual - target).abs() < .5 &&
            !player.state.buffering) {
          if (++settled >= 2) break;
        } else {
          settled = 0;
        }
      }
      if (settled < 2) continue;
      for (var attempt = 0; attempt < 3; attempt++) {
        cancel.check();
        stage = '截取视频画面';
        if (firstFrame) {
          final frame = await captureNativeAlbumJpeg(
            NativeLibrary.path,
            await player.handle,
            originalResolution: original,
          );
          cancel.check();
          if (frame == null) {
            await tick();
            continue;
          }
          final quarterTurn = rotation == 90 || rotation == 270;
          return MediaPreview(
            frame.$1,
            duration,
            quarterTurn ? height : width,
            quarterTurn ? width : height,
            capturedPosition: actual ?? target,
          );
        }
        final bytes = await player.screenshot(
          format: 'image/jpeg',
          includeLibassSubtitles: false,
        );
        if (bytes == null || bytes.isEmpty) {
          await tick();
          continue;
        }
        cancel.check();
        stage = '检查视频封面';
        final image = await _preparePreviewImage(
          bytes,
          rejectBlank: !firstFrame,
          requireBounded: true,
        );
        cancel.check();
        // A paused blank frame will stay blank. Try the next candidate instead
        // of publishing it or repeatedly encoding the same unusable picture.
        if (image == null) break;
        return MediaPreview(
          image,
          duration,
          dimensions.dw ?? dimensions.w,
          dimensions.dh ?? dimensions.h,
          capturedPosition: actual ?? target,
        );
      }
    }
    throw const AppFailure('附近画面为黑场、白场或尚未就绪，保留已有封面。');
  } on Cancelled {
    rethrow;
  } catch (error) {
    final detail = safeFailure(error).message;
    throw AppFailure(
      '$stage失败：$detail${decoderMessages.isEmpty ? '' : ' 解码器：${decoderMessages.join('；')}'}',
    );
  } finally {
    // NativePlayer serializes open/seek/screenshot/dispose, so cancellation
    // never frees a handle while the screenshot isolate is still using it.
    await errors.cancel();
    await logs.cancel();
    await properties?.close();
    await player.dispose();
  }
}

/// Borrow the paused decoder only for the native snapshot. Pixel conversion,
/// quarter-turn rotation and JPEG encoding all run in this one worker, with
/// one RGB allocation and no full-size decode/encode round trip on the UI.
/// The caller awaits completion before disposing the native handle; a pause
/// can cancel publication but cannot free memory while this worker uses it.
@visibleForTesting
Future<(Uint8List, int, int)?> captureNativeAlbumJpeg(
  String library,
  int handleAddress, {
  required bool originalResolution,
}) => compute(_captureAlbumJpeg, (library, handleAddress, originalResolution));

(Uint8List, int, int)? _captureAlbumJpeg((String, int, bool) request) {
  final (library, address, original) = request;
  final api = mpv.MPV(DynamicLibrary.open(library));
  final handle = Pointer<mpv.mpv_handle>.fromAddress(address);
  // The software filter may already have made the screenshot upright. Only
  // consume rotation still attached to its output, never the source angle.
  // Android builds without a rotate filter retain that angle on the output.
  final property = 'video-out-params/rotate'.toNativeUtf8();
  late final int rotation;
  try {
    final value = api.mpv_get_property_string(handle, property.cast());
    try {
      if (value == nullptr) return null;
      final pending = int.tryParse(value.cast<Utf8>().toDartString());
      if (pending == null) return null;
      rotation = (pending % 360 + 360) % 360;
    } finally {
      if (value != nullptr) api.mpv_free(value.cast());
    }
  } finally {
    calloc.free(property);
  }
  final node = calloc<mpv.mpv_node>();
  final strings = [
    'screenshot-raw',
    'video',
  ].map((s) => s.toNativeUtf8()).toList();
  // The client API requires a null-terminated pointer array, not a byte count
  // based on command text length.
  final arguments = calloc<Pointer<Utf8>>(strings.length + 1);
  images.Image? pixels;
  try {
    for (var i = 0; i < strings.length; i++) {
      arguments[i] = strings[i];
    }
    if (api.mpv_command_ret(handle, arguments.cast(), node) < 0 ||
        node.ref.format != mpv.mpv_format.MPV_FORMAT_NODE_MAP) {
      return null;
    }
    var width = 0, height = 0, stride = 0, length = 0;
    Pointer<Uint8> data = nullptr;
    final values = node.ref.u.list;
    for (var i = 0; i < values.ref.num; i++) {
      final key = values.ref.keys[i].cast<Utf8>().toDartString();
      final value = values.ref.values[i];
      if (value.format == mpv.mpv_format.MPV_FORMAT_INT64) {
        switch (key) {
          case 'w':
            width = value.u.int64;
          case 'h':
            height = value.u.int64;
          case 'stride':
            stride = value.u.int64;
        }
      } else if (key == 'data' &&
          value.format == mpv.mpv_format.MPV_FORMAT_BYTE_ARRAY) {
        data = value.u.ba.ref.data.cast();
        length = value.u.ba.ref.size;
      }
    }
    if (data == nullptr ||
        width <= 0 ||
        height <= 0 ||
        stride.abs() < width * 4 ||
        length < stride.abs() * (height - 1) + width * 4) {
      return null;
    }
    if (width * height > 40 * 1024 * 1024 ||
        !original && (width > 480 || height > 480)) {
      throw const AppFailure('封面输出尺寸不符合请求，已停止处理。');
    }
    final quarterTurn = rotation == 90 || rotation == 270;
    pixels = images.Image(
      width: quarterTurn ? height : width,
      height: quarterTurn ? width : height,
      numChannels: 3,
    );
    final rows = List<Uint8List>.generate(
      height,
      (y) => (data + y * stride).asTypedList(width * 4),
      growable: false,
    );
    for (final pixel in pixels) {
      final (x, y) = switch (rotation) {
        90 => (pixel.y, height - 1 - pixel.x),
        180 => (width - 1 - pixel.x, height - 1 - pixel.y),
        270 => (width - 1 - pixel.y, pixel.x),
        _ => (pixel.x, pixel.y),
      };
      final row = rows[y], offset = x * 4;
      pixel
        ..b = row[offset]
        ..g = row[offset + 1]
        ..r = row[offset + 2];
    }
  } finally {
    api.mpv_free_node_contents(node);
    calloc.free(node);
    calloc.free(arguments);
    for (final string in strings) {
      calloc.free(string);
    }
  }
  if (rotation % 90 != 0) {
    pixels = images.copyRotate(pixels, angle: rotation);
  }
  final result = pixels;
  return (
    Uint8List.fromList(images.encodeJpg(result, quality: 95)),
    result.width,
    result.height,
  );
}

/// Decode to a bounded size in the engine; encoding only the small output
/// avoids a second full-resolution pixel buffer on Dart's UI isolate.
Future<Uint8List> encodePreviewImage(Uint8List bytes) async {
  return (await _preparePreviewImage(bytes, rejectBlank: false))!;
}

/// Shared by the background decoder and the foreground playback snapshot.
/// A rejected frame must not overwrite a previously useful cover.
Future<Uint8List?> encodeUsablePreviewImage(Uint8List bytes) =>
    _preparePreviewImage(bytes, rejectBlank: true);

Future<Uint8List?> _preparePreviewImage(
  Uint8List bytes, {
  required bool rejectBlank,
  bool requireBounded = false,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (requireBounded && (descriptor.width > 480 || descriptor.height > 480)) {
      throw const AppFailure('封面缩放未生效，已停止处理过大的截图。');
    }
    final scale = math.min(
      1.0,
      480 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    // The Android test emulator produced PNG streams with invalid checksums.
    // Keep native resizing, then encode only the small RGBA result using the
    // same portable JPEG encoder media_kit uses for its original screenshot.
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixels == null) throw const AppFailure('封面像素读取失败。');
    return await compute(_encodePreviewJpeg, (
      pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      image.width,
      image.height,
      rejectBlank,
    ));
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Uint8List? _encodePreviewJpeg((Uint8List, int, int, bool) frame) {
  if (frame.$4 && !inspectPreviewRgba(frame.$1, frame.$2, frame.$3).usable) {
    return null;
  }
  final image = images.Image.fromBytes(
    width: frame.$2,
    height: frame.$3,
    bytes: frame.$1.buffer,
    bytesOffset: frame.$1.offsetInBytes,
    numChannels: 4,
    order: images.ChannelOrder.rgba,
  );
  return images.encodeJpg(image, quality: 85);
}
