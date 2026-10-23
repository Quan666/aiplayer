import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
// Reuse media_kit's resolved library on every platform without initializing a
// second player or duplicating Android/iOS library-discovery rules.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../sources/range_bridge.dart';
import '../sources/source.dart';
import 'media_technical_info.dart';

/// A fresh file snapshot. It deliberately does not update catalogue metadata.
class MediaFileDetails {
  final String fileName, sourceName, format;
  final int size, modified;
  final bool seekable;
  final Map<String, String> properties, metadata;
  final List<MediaFileTrackDetails> tracks;

  MediaFileDetails({
    required this.fileName,
    this.sourceName = '',
    required this.size,
    this.modified = 0,
    this.seekable = true,
    this.format = '',
    Map<String, String> properties = const {},
    List<MediaFileTrackDetails> tracks = const [],
    Map<String, String> metadata = const {},
  }) : properties = Map.unmodifiable(properties),
       tracks = List.unmodifiable(tracks),
       metadata = Map.unmodifiable(metadata);
}

class MediaFileTrackDetails {
  final String type;
  final int id;
  final Map<String, String> properties, metadata;

  MediaFileTrackDetails({
    required this.type,
    required this.id,
    Map<String, String> properties = const {},
    Map<String, String> metadata = const {},
  }) : properties = Map.unmodifiable(properties),
       metadata = Map.unmodifiable(metadata);
}

class MediaFileProbeResult {
  final String container;
  final Map<String, String> properties, metadata;
  final List<MediaFileTrackDetails> tracks;

  MediaFileProbeResult({
    this.container = '',
    Map<String, String> properties = const {},
    List<MediaFileTrackDetails> tracks = const [],
    Map<String, String> metadata = const {},
  }) : properties = Map.unmodifiable(properties),
       tracks = List.unmodifiable(tracks),
       metadata = Map.unmodifiable(metadata);
}

typedef MediaFileProbe =
    Future<MediaFileProbeResult> Function(String uri, CancelToken cancel);

/// One inspection at a time, with no pending queue or persistent player.
/// Each request owns its source connection; cancelling never touches playback.
class MediaFileDetailsService {
  static final instance = MediaFileDetailsService();

  final MediaFileProbe _probe;
  final Duration requestTimeout;
  bool _busy = false;
  Completer<void>? _idle;

  MediaFileDetailsService({
    MediaFileProbe? probe,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _probe = probe ?? probeMediaFile;

  /// Await the existing retirement signal without enqueuing a new inspection.
  /// A sheet returning from the background can resume after its old probe has
  /// released native resources. Closing that sheet cancels this wait promptly.
  Future<void> waitUntilIdle(CancelToken cancel) async {
    cancel.check();
    final current = _idle;
    if (current == null) return;
    try {
      await _cancelable(current.future, cancel).timeout(requestTimeout);
    } on TimeoutException {
      throw const AppFailure('上次文件读取尚未结束，请稍后重试。');
    }
    cancel.check();
  }

  Future<MediaFileDetails> inspect({
    required Future<SourceAdapter> Function() openSource,
    required String path,
    required CancelToken cancel,
    String fileName = '',
    String sourceName = '',
  }) async {
    cancel.check();
    if (_busy) {
      throw const AppFailure('正在读取其它文件的信息，请稍后重试。');
    }
    _busy = true;
    final idle = _idle = Completer<void>();
    final operation = CancelToken();
    var timedOut = false;
    var finished = false;
    final deadline = Timer(requestTimeout, () {
      timedOut = true;
      operation.cancel();
    });
    unawaited(cancel.whenCancelled.then((_) => operation.cancel()));
    SourceAdapter? source;
    RangeBridge? bridge;
    Future<void>? sourceClosing, bridgeClosing;
    final acquisitions = <Future<void>>[];

    Future<void> closeSource() {
      final current = source;
      return current == null
          ? Future.value()
          : sourceClosing ??= current.close().catchError((Object _) {});
    }

    Future<void> closeBridge() {
      final current = bridge;
      return current == null
          ? Future.value()
          : bridgeClosing ??= current.close().catchError((Object _) {});
    }

    unawaited(
      operation.whenCancelled.then((_) {
        if (finished) return;
        unawaited(closeBridge());
        unawaited(closeSource());
      }),
    );

    try {
      // Retain a late connection until it has closed. The admission slot stays
      // occupied during retirement, so repeated cancellations cannot accumulate
      // disconnected SMB workers or native probes.
      final connecting = openSource().then((value) async {
        source = value;
        if (operation.cancelled) {
          await closeSource();
          throw const Cancelled();
        }
        return value;
      });
      acquisitions.add(connecting.then<void>((_) {}, onError: (Object _) {}));
      final opened = await _cancelable(connecting, operation);
      final SourceEntry entry;
      final String uri;
      if (opened is LocalSource) {
        entry = await _cancelable(opened.stat(path), operation);
        uri = path;
      } else {
        final opening = RangeBridge.open(opened, path, cancel: operation).then((
          value,
        ) async {
          bridge = value;
          if (operation.cancelled) {
            await closeBridge();
            throw const Cancelled();
          }
          return value;
        });
        acquisitions.add(opening.then<void>((_) {}, onError: (Object _) {}));
        final serving = await _cancelable(opening, operation);
        entry = serving.entry;
        uri = serving.uri.toString();
      }
      operation.check();
      if (entry.directory || entry.size <= 0) {
        throw const AppFailure('无法读取空文件或目录的媒体信息。');
      }
      Future<MediaFileProbeResult> readParameters() async {
        try {
          return await _probe(uri, operation);
        } catch (_) {
          operation.check();
          return MediaFileProbeResult(
            properties: {'读取状态': '未能读取媒体轨道参数，请稍后重试。'},
          );
        }
      }

      final probing = readParameters();
      acquisitions.add(probing.then<void>((_) {}, onError: (Object _) {}));
      final result = await _cancelable(probing, operation);
      operation.check();
      final displayName = _safeFileName(
        isVideo(entry.name) || fileName.isEmpty ? entry.name : fileName,
      );
      return MediaFileDetails(
        fileName: displayName,
        sourceName: _safeText(sourceName),
        size: entry.size,
        modified: entry.modified,
        seekable: entry.seekable,
        format: videoContainerLabel(
          result.container,
          fileName: isVideo(entry.name) ? entry.name : displayName,
        ),
        properties: {
          if (path.isNotEmpty) '文件路径': _safeText(path),
          ...result.properties,
        },
        tracks: result.tracks,
        metadata: result.metadata,
      );
    } on Cancelled {
      if (timedOut && !cancel.cancelled) {
        throw const AppFailure('读取文件信息超时，请稍后重试。');
      }
      rethrow;
    } catch (_) {
      // Native and transport errors can contain private paths or signed URLs.
      // Deliberately keep those errors out of both the dialog and the log.
      if (cancel.cancelled) throw const Cancelled();
      if (timedOut) throw const AppFailure('读取文件信息超时，请稍后重试。');
      throw const AppFailure('无法读取文件信息，请检查文件和来源是否可访问。');
    } finally {
      deadline.cancel();
      finished = true;
      operation.cancel();
      Future<void> retire() async {
        try {
          await Future.wait([closeBridge(), closeSource()]);
          await Future.wait(acquisitions);
          // A connection that completed after cancellation owns its close, but
          // await again to also cover a source acquired during cancellation.
          await Future.wait([closeBridge(), closeSource()]);
        } finally {
          _busy = false;
          _idle = null;
          idle.complete();
        }
      }

      // Closing a slow source must not delay cancellation or a timeout notice.
      // New inspections stay bounded until its resources have actually closed.
      if (cancel.cancelled || timedOut) {
        unawaited(retire());
      } else {
        // A slow SMB close cannot hold a ready snapshot indefinitely. Retain
        // its admission slot while allowing the file sheet to display facts.
        await retire().timeout(
          const Duration(milliseconds: 250),
          onTimeout: () {},
        );
      }
    }
  }
}

Future<T> _cancelable<T>(Future<T> work, CancelToken cancel) => Future.any([
  work,
  cancel.whenCancelled.then<T>((_) => throw const Cancelled()),
]);

/// All libmpv calls, native waits, node traversal and metadata sanitization run
/// in this dedicated isolate. NativePlayer.getProperty is a synchronous FFI
/// call despite returning a Future, so it is intentionally not used on the UI.
Future<MediaFileProbeResult> probeMediaFile(
  String uri,
  CancelToken cancel,
) async {
  cancel.check();
  final responses = ReceivePort();
  final done = Completer<MediaFileProbeResult>();
  SendPort? commands;
  var finished = false;
  final subscription = responses.listen((dynamic message) {
    if (message is SendPort) {
      commands = message;
      if (cancel.cancelled) commands!.send('cancel');
    } else if (message is MediaFileProbeResult) {
      if (!done.isCompleted) done.complete(message);
    } else if (message == 'cancelled') {
      if (!done.isCompleted) done.completeError(const Cancelled());
    } else if (message == 'failed' || message is List || message == null) {
      if (!done.isCompleted) {
        done.completeError(const AppFailure('无法读取媒体参数。'));
      }
    }
  });
  unawaited(
    cancel.whenCancelled.then((_) {
      if (!finished) commands?.send('cancel');
    }),
  );
  try {
    await Isolate.spawn(
      _probeWorker,
      (responses.sendPort, NativeLibrary.path, uri),
      onError: responses.sendPort,
      onExit: responses.sendPort,
      errorsAreFatal: true,
      debugName: 'file-details',
    );
    // The worker replies only after mpv_terminate_destroy has finished. Never
    // kill a worker while it owns a native handle; that would leak resources.
    final result = await done.future;
    cancel.check();
    return result;
  } finally {
    finished = true;
    await subscription.cancel();
    responses.close();
  }
}

void _probeWorker((SendPort, String, String) request) async {
  final (reply, libraryPath, uri) = request;
  final commands = ReceivePort();
  var cancelled = false;
  commands.listen((_) => cancelled = true);
  reply.send(commands.sendPort);
  mpv.MPV? api;
  Pointer<mpv.mpv_handle>? handle;
  Object result = 'failed';
  try {
    api = mpv.MPV(DynamicLibrary.open(libraryPath));
    final context = handle = api.mpv_create();
    if (context == nullptr) throw const AppFailure('媒体内核不可用。');
    for (final option in const {
      'config': 'no',
      'load-scripts': 'no',
      'terminal': 'no',
      'msg-level': 'all=no',
      'idle': 'yes',
      'pause': 'yes',
      'vo': 'null',
      'ao': 'null',
      'vid': 'no',
      'aid': 'no',
      'sid': 'no',
      'audio-file-auto': 'no',
      'sub-auto': 'no',
      'autoload-files': 'no',
      'cache': 'no',
      'demuxer-readahead-secs': '0',
      'demuxer-max-bytes': '4194304',
      'network-timeout': '5',
    }.entries) {
      final name = option.key.toNativeUtf8();
      final value = option.value.toNativeUtf8();
      try {
        api.mpv_set_option_string(context, name.cast(), value.cast());
      } finally {
        calloc.free(name);
        calloc.free(value);
      }
    }
    if (api.mpv_initialize(context) < 0) {
      throw const AppFailure('媒体内核初始化失败。');
    }
    // Capture the header after demuxing and before decoder selection. This
    // reads video/audio/subtitle facts without decoding a single video frame,
    // playing audio, opening a window or scanning for neighbouring subtitles.
    final hook = 'on_preloaded'.toNativeUtf8();
    try {
      if (api.mpv_hook_add(context, 1, hook.cast(), 0) < 0) {
        throw const AppFailure('媒体内核不支持文件参数读取。');
      }
    } finally {
      calloc.free(hook);
    }
    _command(api, context, ['loadfile', uri, 'replace']);
    final clock = Stopwatch()..start();
    while (!cancelled && clock.elapsed < const Duration(seconds: 20)) {
      final event = api.mpv_wait_event(context, .05).ref;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_HOOK) {
        final hookEvent = event.data.cast<mpv.mpv_event_hook>().ref;
        final hookId = hookEvent.id;
        try {
          result = _readProbe(api, context);
        } finally {
          api.mpv_hook_continue(context, hookId);
        }
        break;
      }
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_END_FILE ||
          event.event_id == mpv.mpv_event_id.MPV_EVENT_SHUTDOWN) {
        break;
      }
      // The only bounded native wait occurs on this worker. Yield here to
      // receive cancellation; no main-isolate event-loop splitting is needed.
      await Future<void>.delayed(Duration.zero);
    }
    if (cancelled) result = 'cancelled';
  } catch (_) {
    result = cancelled ? 'cancelled' : 'failed';
  } finally {
    if (handle != null && handle != nullptr) {
      api?.mpv_terminate_destroy(handle);
    }
    commands.close();
  }
  reply.send(result);
}

void _command(mpv.MPV api, Pointer<mpv.mpv_handle> handle, List<String> args) {
  final strings = args.map((arg) => arg.toNativeUtf8()).toList();
  final pointers = calloc<Pointer<Int8>>(strings.length + 1);
  try {
    for (var i = 0; i < strings.length; i++) {
      pointers[i] = strings[i].cast();
    }
    if (api.mpv_command_async(handle, 1, pointers) < 0) {
      throw const AppFailure('媒体参数读取失败。');
    }
  } finally {
    for (final string in strings) {
      calloc.free(string);
    }
    calloc.free(pointers);
  }
}

Object? _property(
  mpv.MPV api,
  Pointer<mpv.mpv_handle> handle,
  String name,
  _NodeBudget budget,
) {
  final key = name.toNativeUtf8();
  final node = calloc<mpv.mpv_node>();
  try {
    final status = api.mpv_get_property(
      handle,
      key.cast(),
      mpv.mpv_format.MPV_FORMAT_NODE,
      node.cast(),
    );
    if (status < 0) return null;
    try {
      return _readNode(node.ref, budget, 0);
    } finally {
      api.mpv_free_node_contents(node);
    }
  } finally {
    calloc.free(key);
    calloc.free(node);
  }
}

class _NodeBudget {
  int remaining = 8192;
  int textBytes = 256 * 1024;
  bool truncated = false;
}

Object? _readNode(mpv.mpv_node node, _NodeBudget budget, int depth) {
  if (budget.remaining-- <= 0 || depth > 8) {
    budget.truncated = true;
    return null;
  }
  switch (node.format) {
    case mpv.mpv_format.MPV_FORMAT_STRING:
      return _nativeString(node.u.string, budget);
    case mpv.mpv_format.MPV_FORMAT_FLAG:
      return node.u.flag != 0;
    case mpv.mpv_format.MPV_FORMAT_INT64:
      return node.u.int64;
    case mpv.mpv_format.MPV_FORMAT_DOUBLE:
      return node.u.double_;
    case mpv.mpv_format.MPV_FORMAT_NODE_ARRAY:
      final list = node.u.list.ref;
      if (list.num > 512) budget.truncated = true;
      final values = <Object?>[];
      for (var i = 0; i < list.num && i < 512; i++) {
        if (budget.remaining <= 0 || budget.textBytes <= 0) {
          budget.truncated = true;
          break;
        }
        values.add(_readNode(list.values[i], budget, depth + 1));
      }
      return values;
    case mpv.mpv_format.MPV_FORMAT_NODE_MAP:
      final list = node.u.list.ref;
      if (list.num > 512) budget.truncated = true;
      final values = <String, Object?>{};
      for (var i = 0; i < list.num && i < 512; i++) {
        if (budget.remaining <= 0 || budget.textBytes <= 0) {
          budget.truncated = true;
          break;
        }
        final key = _nativeString(list.keys[i], budget, limit: 256);
        values[key] = _readNode(list.values[i], budget, depth + 1);
      }
      return values;
    default:
      return null;
  }
}

String _nativeString(
  Pointer<Int8> text,
  _NodeBudget budget, {
  int limit = 8192,
}) {
  if (text == nullptr) return '';
  if (limit > budget.textBytes) limit = budget.textBytes;
  var length = 0;
  while (length < limit && text[length] != 0) {
    length++;
  }
  if (length == limit) budget.truncated = true;
  budget.textBytes -= length;
  return utf8.decode(
    text.cast<Uint8>().asTypedList(length),
    allowMalformed: true,
  );
}

MediaFileProbeResult _readProbe(mpv.MPV api, Pointer<mpv.mpv_handle> handle) {
  final budget = _NodeBudget();
  Object? read(String key) => _property(api, handle, key, budget);
  final properties = <String, String>{};
  final container = '${read('file-format') ?? ''}';
  final duration = _positive(read('duration'));
  if (duration != null) properties['时长'] = _duration(duration);
  final tracks = <MediaFileTrackDetails>[];
  final trackList = read('track-list');
  if (trackList is List) {
    for (final value in trackList) {
      if (value is! Map) continue;
      final fields = <String, String>{};
      final width = _positive(value['demux-w']);
      final height = _positive(value['demux-h']);
      if (width != null && height != null) {
        fields['分辨率'] = '${width.round()} × ${height.round()}';
      }
      for (final entry in value.entries) {
        final key = '${entry.key}';
        if (const {
          'id',
          'type',
          'metadata',
          'demux-w',
          'demux-h',
          'selected',
          'main-selection',
          'external-filename',
        }.contains(key)) {
          continue;
        }
        final display = _trackValue(key, entry.value);
        if (display.isNotEmpty) {
          fields[_trackLabels[key] ?? _safeText(key)] = display;
        }
      }
      tracks.add(
        MediaFileTrackDetails(
          type: '${value['type'] ?? ''}',
          id: (value['id'] as num?)?.toInt() ?? tracks.length + 1,
          properties: fields,
          metadata: _metadata(value['metadata']),
        ),
      );
    }
  }
  final chapters = read('chapter-list');
  if (chapters is List && chapters.isNotEmpty) {
    properties['章节数'] = '${chapters.length}';
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      if (chapter is! Map) continue;
      final time = chapter['time'];
      final title = _safeText('${chapter['title'] ?? ''}');
      properties['章节 ${i + 1}'] = [
        if (time is num && time.isFinite && time >= 0)
          _duration(time.toDouble()),
        if (title.isNotEmpty) title,
      ].join(' · ');
    }
  }
  final metadata = _metadata(read('metadata'));
  if (budget.truncated) properties['读取状态'] = '参数内容过多，部分字段已省略。';
  return MediaFileProbeResult(
    container: container,
    properties: properties,
    tracks: tracks,
    metadata: metadata,
  );
}

const _trackLabels = {
  'codec': '编码',
  'codec-desc': '编码名称',
  'codec-profile': '编码规格',
  'codec-tag': '编码标识',
  'title': '标题',
  'lang': '语言',
  'default': '默认轨道',
  'forced': '强制轨道',
  'dependent': '依赖轨道',
  'visual-impaired': '视觉辅助',
  'hearing-impaired': '听觉辅助',
  'demux-fps': '帧率',
  'demux-bitrate': '码率',
  'hls-bitrate': 'HLS 码率',
  'demux-samplerate': '采样率',
  'demux-channel-count': '声道数',
  'demux-channels': '声道布局',
  'audio-channels': '声道数',
  'demux-rotation': '旋转角度',
  'demux-par': '像素宽高比',
  'format-name': '像素或采样格式',
  'image': '静态图片',
  'albumart': '内嵌封面',
  'external': '外部轨道',
  'src-id': '源轨道 ID',
  'ff-index': '流序号',
  'program-id': '节目 ID',
  'decoder': '解码器',
  'decoder-desc': '解码器名称',
  'dolby-vision-profile': '杜比视界 Profile',
  'dolby-vision-level': '杜比视界 Level',
  'replaygain-track-peak': '轨道峰值',
  'replaygain-track-gain': '轨道增益',
  'replaygain-album-peak': '专辑峰值',
  'replaygain-album-gain': '专辑增益',
};

double? _positive(Object? value) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite && number > 0 ? number : null;
}

String _trackValue(String key, Object? value) {
  if (value is bool) return value ? '是' : '否';
  if (value == null || value is Map || value is List) return '';
  if (key == 'codec') return videoCodecLabel(_safeText('$value'));
  final number = _positive(value);
  if (const {'demux-bitrate', 'hls-bitrate'}.contains(key)) {
    return number == null ? '' : '${_decimal(number / 1000)} kb/s';
  }
  if (key == 'demux-fps') {
    return number == null ? '' : '${_decimal(number)} fps';
  }
  if (key == 'demux-samplerate') {
    return number == null ? '' : '${_decimal(number)} Hz';
  }
  return _safeText('$value');
}

String _decimal(double number) => number
    .toStringAsFixed(3)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String _duration(double seconds) {
  final duration = Duration(milliseconds: (seconds * 1000).round());
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final secs = (duration.inSeconds % 60).toString().padLeft(2, '0');
  final milliseconds = (duration.inMilliseconds % 1000).toString().padLeft(
    3,
    '0',
  );
  return '$hours:$minutes:$secs.$milliseconds';
}

Map<String, String> _metadata(Object? raw) {
  if (raw is! Map) return const {};
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final key = _safeText('${entry.key}');
    if (RegExp(
      r'password|passwd|authorization|cookie|secret|token|api.?key',
      caseSensitive: false,
    ).hasMatch(key)) {
      continue;
    }
    final value = entry.value;
    if (value is String || value is num || value is bool) {
      final text = _safeText('$value');
      if (text.isNotEmpty && key.isNotEmpty) result[key] = text;
    }
  }
  return result;
}

String _safeFileName(String value) {
  final uri = Uri.tryParse(value);
  final name = uri != null && uri.hasScheme && uri.host.isNotEmpty
      ? directLinkDisplayName(value)
      : p.posix.basename(value.replaceAll('\\', '/'));
  return _safeText(name);
}

String _safeText(String value) => value
    .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
    .replaceAll(
      RegExp(r'\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=_\-.]+', caseSensitive: false),
      '[认证信息已隐藏]',
    )
    .replaceAllMapped(RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"']+'''), (
      match,
    ) {
      final uri = Uri.tryParse(match[0]!);
      if (uri == null) return '[链接已隐藏]';
      return uri
          .replace(userInfo: '')
          .removeFragment()
          .toString()
          .split('?')
          .first;
    })
    .trim();
