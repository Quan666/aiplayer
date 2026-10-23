import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as images;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../core/logger.dart';
import '../sources/range_bridge.dart';
import '../sources/source.dart';
import 'preview_quality.dart';

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

  String get contentFingerprint => sha256
      .convert(utf8.encode(jsonEncode([source, path, size, revision])))
      .toString();
  String get fingerprint => position == null
      ? contentFingerprint
      : sha256
            .convert(utf8.encode('$contentFingerprint:${position!.round()}'))
            .toString();
}

typedef PreviewCapture =
    Future<MediaPreview> Function(String uri, CancelToken cancel);

/// One decoder at a time, at most 64 pending requests. Playback cancels the
/// current request and waits for its native resources to close before opening.
class MediaPreviewQueue {
  final Directory directory;
  final Future<SourceAdapter> Function(String) openSource;
  final bool Function(MediaPreviewRequest) isCurrent;
  final void Function(MediaPreviewRequest, String, MediaPreview) onReady;
  final void Function(Object) onError;
  final PreviewCapture capture;
  final bool _defaultCapture;
  final _pending = <String, MediaPreviewRequest>{};
  final _failed = <String>{};
  CancelToken? _cancel;
  MediaPreviewRequest? _active;
  Future<void>? _working;
  Timer? _startTimer;
  int _paused = 0;
  bool _closed = false;
  bool _requeueActive = false;

  MediaPreviewQueue({
    required this.directory,
    required this.openSource,
    required this.isCurrent,
    required this.onReady,
    required this.onError,
    PreviewCapture? capture,
  }) : capture = capture ?? captureMediaPreview,
       _defaultCapture = capture == null;

  bool schedule(MediaPreviewRequest request, {bool priority = false}) {
    final pending = _pending[request.id];
    if (_closed ||
        pending?.fingerprint == request.fingerprint ||
        (_active?.id == request.id &&
            _active?.fingerprint == request.fingerprint &&
            _cancel?.cancelled != true) ||
        _failed.contains('${request.id}:${request.fingerprint}') ||
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
          _failed.add('${request.id}:${request.fingerprint}');
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
            ? await captureMediaPreview(uri, cancel, position: request.position)
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
            onReady(request, destination, result);
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
          _failed.add('${request.id}:${request.fingerprint}');
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
    if (_cancel != null && !_cancel!.cancelled) _requeueActive = true;
    _cancel?.cancel();
    await _working;
  }

  /// The caller pauses and awaits native work before clearing its disk cache.
  void clearPending() {
    _pending.clear();
    _failed.clear();
    _requeueActive = false;
  }

  void resume() {
    if (_paused > 0) _paused--;
    _start();
  }

  void forget(String id) {
    _pending.remove(id);
    _failed.removeWhere((entry) => entry.startsWith('$id:'));
    if (_active?.id == id) {
      _requeueActive = false;
      _cancel?.cancel();
    }
  }

  Future<void> close() async {
    _closed = true;
    _startTimer?.cancel();
    _startTimer = null;
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
}) async {
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
          player.state.duration > Duration.zero) {
        break;
      }
      await tick();
    }
    final duration = player.state.duration.inMilliseconds / 1000;
    final dimensions = player.state.videoParams;
    if ((dimensions.w ?? 0) <= 0) {
      throw const AppFailure('未能读取视频画面。');
    }
    for (final target in previewCapturePositions(
      duration,
      position: position,
    )) {
      stage = '定位封面画面';
      await player.seek(Duration(milliseconds: (target * 1000).round()));
      // The seek command completes when queued, not when its frame is ready.
      // Especially with MKV/B-frames, time-pos can already show the requested
      // position while screenshot-raw still returns the previous black frame.
      // Require the native seek to finish and the position to remain settled
      // through two polls before touching the screenshot buffer.
      var settled = 0;
      for (var i = 0; i < 40; i++) {
        await tick();
        final seeking = await native.getProperty('seeking');
        final actual = double.tryParse(await native.getProperty('time-pos'));
        if (seeking == 'no' &&
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
        final image = await encodeUsablePreviewImage(bytes);
        cancel.check();
        // A paused blank frame will stay blank. Try the next candidate instead
        // of publishing it or repeatedly encoding the same unusable picture.
        if (image == null) break;
        return MediaPreview(
          image,
          duration,
          dimensions.dw ?? dimensions.w,
          dimensions.dh ?? dimensions.h,
          capturedPosition:
              double.tryParse(await native.getProperty('time-pos')) ?? target,
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
    await player.dispose();
  }
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
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
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
