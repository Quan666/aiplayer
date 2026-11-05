import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/network.dart';
import '../core/logger.dart';
import '../core/system_proxy.dart';
import '../sources/configuration.dart';
import '../sources/source.dart';

const textFileExtensions = {
  'txt',
  'text',
  'html',
  'htm',
  'xhtml',
  'py',
  'pyw',
  'js',
  'mjs',
  'cjs',
  'jsx',
  'ts',
  'tsx',
  'json',
  'jsonl',
  'ndjson',
  'md',
  'markdown',
  'mdx',
  'xml',
  'nfo',
  'csv',
  'tsv',
  'log',
  'yaml',
  'yml',
  'toml',
  'ini',
  'conf',
  'cfg',
  'config',
  'properties',
  'env',
  'css',
  'scss',
  'sass',
  'less',
  'dart',
  'java',
  'kt',
  'kts',
  'swift',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'go',
  'rs',
  'rb',
  'php',
  'lua',
  'sh',
  'bash',
  'zsh',
  'fish',
  'bat',
  'cmd',
  'ps1',
  'sql',
  'graphql',
  'gql',
  'vue',
  'svelte',
  'r',
  'tex',
  'rst',
  'srt',
  'ass',
  'ssa',
  'vtt',
  'lrc',
  'cue',
  'm3u',
  'm3u8',
  'pls',
  'gitignore',
  'gitattributes',
  'editorconfig',
  'dockerignore',
};

bool isTextFile(String name) {
  final leaf = p.basename(name).toLowerCase();
  if (const {
    'readme',
    'license',
    'licence',
    'changelog',
    'makefile',
    'dockerfile',
    '.gitignore',
    '.gitattributes',
    '.editorconfig',
    '.dockerignore',
    '.env',
  }.contains(leaf)) {
    return true;
  }
  return textFileExtensions.contains(p.extension(leaf).replaceFirst('.', ''));
}

class TextDocumentSnapshot {
  final List<String> lines;
  final int maxColumns;
  const TextDocumentSnapshot({required this.lines, required this.maxColumns});
}

class TextMatch {
  final int row, start, end;

  /// Parts of a match spanning visual rows share the same identity.
  final int id;
  const TextMatch(this.row, this.start, this.end, {this.id = -1});
}

class TextSearchResult {
  final List<TextMatch> matches;
  final Map<int, List<TextMatch>> matchesByRow;
  final bool truncated;
  const TextSearchResult({
    this.matches = const [],
    this.matchesByRow = const {},
    this.truncated = false,
  });
}

/// One foreground document owns one worker and one independent source
/// connection. Reading, decoding, line splitting, searching and cache IO never
/// run on the Flutter isolate. Only the newest waiting request is retained.
class TextDocumentService {
  final Map<String, dynamic> source;
  final String password, documentsPath;
  final int maxTextBytes, maxExternalBytes;
  final Duration smbSlotWaitTimeout, requestIdleTimeout;
  Timer? _requestDeadline;
  @visibleForTesting
  final DocumentSourceConnector? testConnector;
  ReceivePort? _replies;
  StreamSubscription<dynamic>? _subscription;
  ReceivePort? _exitPort;
  Completer<void>? _exited;
  Isolate? _isolate;
  SendPort? _commands;
  Completer<void>? _starting;
  _DocumentRequest? _active, _pending;
  bool _disposed = false;
  bool _smbSlotHeld = false;
  int _serial = 0;

  TextDocumentService({
    required Map<String, dynamic> source,
    this.password = '',
    required this.documentsPath,
    this.maxTextBytes = 16 * 1024 * 1024,
    this.maxExternalBytes = 256 * 1024 * 1024,
    this.smbSlotWaitTimeout = const Duration(seconds: 15),
    this.requestIdleTimeout = const Duration(seconds: 45),
    this.testConnector,
  }) : source = Map.unmodifiable(source);

  @visibleForTesting
  static int get activeSmbWorkers => _SmbDocumentSlots.active;

  @visibleForTesting
  static int get waitingSmbWorkers => _SmbDocumentSlots.waiting.length;

  Future<TextDocumentSnapshot> load(SourceEntry entry) async =>
      await _submit('load', entry) as TextDocumentSnapshot;

  Future<TextSearchResult> search(String query) async =>
      await _submit('search', query) as TextSearchResult;

  /// Local files retain their original path. Remote files are materialized in
  /// a dedicated directory. A successful handoff must keep that file available
  /// because another app can read it after the launch call returns.
  Future<String> prepareExternal(
    SourceEntry entry, {
    required String cacheDirectory,
    int maxCacheBytes = 512 * 1024 * 1024,
    void Function(int received, int total)? onProgress,
  }) async {
    if (maxCacheBytes <= 0) {
      throw ArgumentError.value(maxCacheBytes, 'maxCacheBytes');
    }
    final staging = source['kind'] == 'local'
        ? null
        : p.join(
            cacheDirectory,
            'open-${DateTime.now().microsecondsSinceEpoch}-${++_serial}',
          );
    return await _submit(
      'external',
      (entry, cacheDirectory, staging, maxCacheBytes),
      staging: staging,
      onProgress: onProgress,
    ) as String;
  }

  Future<Object> _submit(
    String operation,
    Object argument, {
    String? staging,
    void Function(int received, int total)? onProgress,
  }) {
    if (_disposed) return Future.error(const Cancelled());
    final request = _DocumentRequest(
      ++_serial,
      operation,
      argument,
      staging,
      onProgress,
    );
    final pending = _pending;
    if (pending != null && !pending.result.isCompleted) {
      pending.result.completeError(const Cancelled());
    }
    _pending = request;
    unawaited(_dispatch());
    return request.result.future;
  }

  Future<void> _start() async {
    if (_commands != null) return;
    final existing = _starting;
    if (existing != null) return existing.future;
    final starting = _starting = Completer<void>();
    // Disposal can arrive while Isolate.spawn is still completing, before the
    // startup await has attached. The requesting operation receives that same
    // cancellation through its own future.
    starting.future.ignore();
    if (source['kind'] == 'smb') {
      try {
        await _SmbDocumentSlots.acquire(this);
        _smbSlotHeld = true;
        if (_disposed) {
          _releaseSmbSlot();
          throw const Cancelled();
        }
      } catch (error, stack) {
        if (!starting.isCompleted) starting.completeError(error, stack);
        rethrow;
      }
    }
    final port = _replies = ReceivePort();
    final exitPort = _exitPort = ReceivePort();
    final exited = _exited = Completer<void>();
    exitPort.listen((_) {
      _releaseSmbSlot();
      if (!exited.isCompleted) exited.complete();
      exitPort.close();
      if (!_disposed) _fail(const AppFailure('文件后台任务已退出，请重试。'));
    });
    _subscription = port.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (!starting.isCompleted) starting.complete();
      } else if (message is _DocumentActivity) {
        _requestActivity(message.id);
      } else if (message is _DocumentProgress) {
        final request = _active;
        if (!_disposed &&
            request != null &&
            request.id == message.id &&
            !request.result.isCompleted) {
          _requestActivity(message.id);
          request.onProgress?.call(message.received, message.total);
        }
      } else if (message is _DocumentReply) {
        final request = _active;
        if (request == null || request.id != message.id) return;
        _requestDeadline?.cancel();
        _requestDeadline = null;
        if (message.error != null && source['kind'] == 'smb') {
          // A timed-out native connect can retain an abandoned channel until
          // its late result is closed. Retire this parent instead of spawning
          // another child inside the same slot after repeated retries.
          _fail(AppFailure(message.error!));
          return;
        }
        _active = null;
        if (!request.result.isCompleted) {
          if (message.error != null) {
            request.result.completeError(AppFailure(message.error!));
          } else {
            request.result.complete(message.value!);
          }
        }
        unawaited(_dispatch());
      } else {
        _fail(const AppFailure('文件后台任务已退出，请重试。'));
      }
    });
    try {
      final worker = await Isolate.spawn(
        _documentMain,
        (
          port.sendPort,
          source,
          password,
          maxTextBytes,
          maxExternalBytes,
          SystemProxyWorkerConfiguration.capture(),
          testConnector,
        ),
        debugName: 'text-document',
        onError: port.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      _isolate = worker;
      if (_disposed) {
        worker.kill(priority: Isolate.immediate);
        throw const Cancelled();
      }
      await starting.future;
    } catch (error, stack) {
      if (!starting.isCompleted) starting.completeError(error, stack);
      if (_isolate == null) {
        _releaseSmbSlot();
        if (!exited.isCompleted) exited.complete();
        exitPort.close();
      }
      rethrow;
    }
  }

  Future<void> _dispatch() async {
    if (_disposed || _active != null || _pending == null) return;
    _active = _pending;
    _pending = null;
    try {
      await _start();
      if (_disposed) return;
      final request = _active!;
      _requestActivity(request.id);
      _commands!.send((request.id, request.operation, request.argument));
    } catch (error, stack) {
      _requestDeadline?.cancel();
      _requestDeadline = null;
      final request = _active;
      _active = null;
      if (request != null && !request.result.isCompleted) {
        request.result.completeError(error, stack);
      }
      if (!_disposed) unawaited(_dispatch());
    }
  }

  void _requestActivity(int id) {
    if (_disposed || _active?.id != id) return;
    _requestDeadline?.cancel();
    // await-for waits for async* cancellation, which can itself be blocked on
    // native IO. The parent must own this deadline so it can report failure
    // without waiting for that subscription or terminating an active FFI call.
    _requestDeadline = Timer(requestIdleTimeout, () {
      if (!_disposed && _active?.id == id) {
        _fail(const AppFailure('文件读取超时，请检查网络后重试。'));
      }
    });
  }

  void _fail(Object error) {
    _requestDeadline?.cancel();
    _requestDeadline = null;
    final starting = _starting;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(error);
    }
    final stages = <String>[];
    for (final request in [_active, _pending]) {
      if (request != null && !request.result.isCompleted) {
        request.result.completeError(error);
      }
      final staging = request?.staging;
      if (staging != null) stages.add(staging);
    }
    _active = _pending = null;
    _disposed = true;
    _SmbDocumentSlots.cancel(this);
    if (source['kind'] == 'smb' && _commands != null) {
      // Native SMB owns a child isolate. Keep this parent alive until close has
      // released that child, including connections that finish after stop.
      _commands!.send('stop');
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    if (stages.isNotEmpty) unawaited(_cleanupAfterExit(stages));
    _replies?.close();
    unawaited(_subscription?.cancel());
  }

  Future<void> _cleanupAfterExit(List<String> stages) async {
    // Graceful SMB teardown may outlive its bounded native read. A separate
    // first cleanup removes partial data promptly; repeat after exit to cover
    // an already-started filesystem operation without releasing the slot early.
    if (source['kind'] == 'smb') {
      for (final staging in stages) {
        await _discardStaging(staging);
      }
      await _exited?.future;
    } else {
      await _exited?.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      _exitPort?.close();
    }
    for (final staging in stages) {
      await _discardStaging(staging);
    }
  }

  void _releaseSmbSlot() {
    if (!_smbSlotHeld) return;
    _smbSlotHeld = false;
    _SmbDocumentSlots.release();
  }

  /// Cancellation is immediate and does not depend on another UI frame.
  /// Download staging paths are removed by the dedicated cache cleanup.
  void dispose() {
    if (_disposed) return;
    _fail(const Cancelled());
  }
}

typedef DocumentSourceConnector = Future<SourceAdapter> Function(
  Map<String, dynamic> source,
  String password,
);

class _SmbDocumentSlots {
  static int active = 0;
  static final waiting = <(TextDocumentService, Completer<void>)>[];

  static Future<void> acquire(TextDocumentService owner) {
    if (active < 2) {
      active++;
      return Future.value();
    }
    if (waiting.length >= 4) {
      return Future.error(const AppFailure('文件任务繁忙，请稍后重试。'));
    }
    final ready = Completer<void>();
    waiting.add((owner, ready));
    return ready.future.timeout(
      owner.smbSlotWaitTimeout,
      onTimeout: () {
        waiting.removeWhere((entry) => identical(entry.$2, ready));
        throw const AppFailure('SMB 文件任务等待超时，请稍后重试。');
      },
    );
  }

  static void cancel(TextDocumentService owner) {
    final index = waiting.indexWhere((entry) => identical(entry.$1, owner));
    if (index >= 0) waiting.removeAt(index).$2.completeError(const Cancelled());
  }

  static void release() {
    if (waiting.isNotEmpty) {
      waiting.removeAt(0).$2.complete();
    } else {
      active--;
    }
  }
}

class _DocumentRequest {
  final int id;
  final String operation;
  final Object argument;
  final String? staging;
  final void Function(int received, int total)? onProgress;
  final result = Completer<Object>();
  _DocumentRequest(
    this.id,
    this.operation,
    this.argument,
    this.staging,
    this.onProgress,
  );
}

class _DocumentActivity {
  final int id;
  const _DocumentActivity(this.id);
}

class _DocumentProgress {
  final int id, received, total;
  const _DocumentProgress(this.id, this.received, this.total);
}

class _DocumentReply {
  final int id;
  final Object? value;
  final String? error;
  const _DocumentReply(this.id, {this.value, this.error});
}

typedef _WorkerArguments = (
  SendPort,
  Map<String, dynamic>,
  String,
  int,
  int,
  SystemProxyWorkerConfiguration,
  DocumentSourceConnector?,
);

Future<void> _documentMain(_WorkerArguments arguments) async {
  final (
    replies,
    configuration,
    password,
    maxText,
    maxExternal,
    proxy,
    connector,
  ) = arguments;
  initializeSystemProxyWorker(proxy);
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  SourceAdapter? adapter;
  _LoadedText? document;
  final cancel = CancelToken();
  var busy = false;
  Future<void>? closing;

  Future<void> closeSource() async {
    final current = adapter;
    adapter = null;
    try {
      await current?.close();
    } catch (_) {}
  }

  Future<void> finishStop() async {
    if (busy) return;
    await closing;
    await closeSource();
    commands.close();
  }

  Future<SourceAdapter> open() async {
    cancel.check();
    if (adapter != null) return adapter!;
    final connected = connector != null
        ? await connector(configuration, password)
        : configuration['kind'] == 'local'
        ? LocalSource()
        : await connectSource(configuration, password: password);
    if (cancel.cancelled) {
      await connected.close();
      throw const Cancelled();
    }
    return adapter = connected;
  }

  Future<void> run(dynamic message) async {
    final (id, operation, argument) = message as (int, String, Object);
    void activity() {
      if (!cancel.cancelled) replies.send(_DocumentActivity(id));
    }

    activity();
    String? staging;
    try {
      Object result;
      switch (operation) {
        case 'load':
          document = null;
          final entry = argument as SourceEntry;
          final source = await open();
          cancel.check();
          activity();
          final bytes = await _readBounded(
            source,
            entry,
            maxText,
            cancel,
            activity,
          );
          cancel.check();
          final loaded = _decodeDocument(bytes);
          document = loaded;
          result = loaded.snapshot;
        case 'search':
          result = _searchDocument(document, argument as String);
        case 'external':
          final (entry, cacheDirectory, requestedStaging, maxCacheBytes) =
              argument as (SourceEntry, String, String?, int);
          if (configuration['kind'] == 'local') {
            final stat = await File(entry.path).stat();
            cancel.check();
            if (stat.type != FileSystemEntityType.file) {
              throw const AppFailure('文件不可访问，请重新关联位置。');
            }
            result = entry.path;
          } else {
            await _cleanupExternalCache(cacheDirectory);
            cancel.check();
            final source = await open();
            cancel.check();
            activity();
            final stat = await source
                .stat(entry.path)
                .timeout(const Duration(seconds: 30));
            cancel.check();
            activity();
            _checkSize(stat.size, maxExternal, external: true);
            final used = await _externalCacheSize(cacheDirectory);
            cancel.check();
            if (used + stat.size > maxCacheBytes) {
              throw const AppFailure('临时文件缓存已满，请先下载文件后使用其他应用打开。');
            }
            staging = requestedStaging!;
            final directory = await Directory(staging).create(recursive: true);
            cancel.check();
            final safeName = p
                .basename(entry.name)
                .replaceAll(RegExp(r'[\\/\x00-\x1f\x7f]'), '_');
            final payload = await Directory(p.join(directory.path, 'payload'))
                .create();
            cancel.check();
            final target = File(
              p.join(
                payload.path,
                safeName.isEmpty || safeName == '.' || safeName == '..'
                    ? 'file'
                    : safeName,
              ),
            );
            final partial = File(p.join(directory.path, '.download.part'));
            final sink = partial.openWrite();
            var received = 0;
            final progressClock = Stopwatch()..start();
            // Show the first completed block immediately, then coalesce by
            // elapsed time without scheduling a periodic timer.
            var lastProgress = -250;
            replies.send(_DocumentProgress(id, 0, stat.size));
            try {
              if (stat.size > 0) {
                await for (final bytes
                    in source
                        .read(entry.path, 0, stat.size - 1)
                        .timeout(const Duration(seconds: 30))) {
                  cancel.check();
                  received += bytes.length;
                  _checkSize(received, maxExternal, external: true);
                  sink.add(bytes);
                  // Await flush for bounded file IO backpressure.
                  await sink.flush();
                  cancel.check();
                  final elapsed = progressClock.elapsedMilliseconds;
                  if (received < stat.size && elapsed - lastProgress >= 250) {
                    lastProgress = elapsed;
                    replies.send(_DocumentProgress(id, received, stat.size));
                  }
                }
              }
            } finally {
              await sink.close();
            }
            cancel.check();
            if (received != stat.size) {
              throw const AppFailure('文件未读取完整，请重试。');
            }
            await partial.rename(target.path);
            cancel.check();
            await File(p.join(directory.path, '.complete')).writeAsString('');
            cancel.check();
            replies.send(_DocumentProgress(id, received, stat.size));
            result = target.path;
            staging = null;
          }
        default:
          throw const AppFailure('未知文件操作。');
      }
      cancel.check();
      replies.send(_DocumentReply(id, value: result));
    } catch (error) {
      final reply = _DocumentReply(
        id,
        error: safeFailure(error, action: '读取文件失败').message,
      );
      final smb = configuration['kind'] == 'smb';
      // Report the failure before native shutdown: close may wait behind the
      // very FFI operation that timed out. The parent retires an SMB service on
      // error but retains its slot until this worker and its child really exit.
      if (smb && !cancel.cancelled) replies.send(reply);
      if (staging != null) {
        try {
          await Directory(staging).delete(recursive: true);
        } catch (_) {}
      }
      if (smb) {
        closing ??= closeSource();
        await closing;
      } else {
        await closeSource();
        if (!cancel.cancelled) replies.send(reply);
      }
    } finally {
      busy = false;
      if (cancel.cancelled) await finishStop();
    }
  }

  commands.listen((message) {
    if (message == 'stop') {
      cancel.cancel();
      // Closing synchronously marks SmbSource closed before awaiting native
      // teardown, preventing retry or the next sequential read from starting.
      closing ??= closeSource();
      unawaited(finishStop());
    } else if (!cancel.cancelled && !busy) {
      busy = true;
      unawaited(run(message));
    }
  });
}

void _checkSize(int size, int maximum, {bool external = false}) {
  if (size < 0 || size > maximum) {
    throw AppFailure(
      external
          ? '文件过大，请先下载后使用其他应用打开。'
          : '文本超过 ${maximum ~/ (1024 * 1024)} MB，请使用其他应用打开。',
    );
  }
}

Future<Uint8List> _readBounded(
  SourceAdapter source,
  SourceEntry entry,
  int maximum,
  CancelToken cancel,
  void Function() activity,
) async {
  cancel.check();
  final stat = await source
      .stat(entry.path)
      .timeout(const Duration(seconds: 30));
  cancel.check();
  activity();
  if (stat.directory) throw const AppFailure('无法将文件夹作为文本读取。');
  _checkSize(stat.size, maximum);
  final builder = BytesBuilder(copy: false);
  final activityClock = Stopwatch()..start();
  var lastActivity = -250;
  if (stat.size > 0) {
    await for (final bytes
        in source
            .read(entry.path, 0, stat.size - 1)
            .timeout(const Duration(seconds: 30))) {
      cancel.check();
      _checkSize(builder.length + bytes.length, maximum);
      builder.add(bytes);
      final elapsed = activityClock.elapsedMilliseconds;
      if (elapsed - lastActivity >= 250) {
        lastActivity = elapsed;
        activity();
      }
    }
  }
  cancel.check();
  if (builder.length != stat.size) {
    throw const AppFailure('文件未读取完整，请重试。');
  }
  return builder.takeBytes();
}

class _LoadedText {
  final TextDocumentSnapshot snapshot;
  final String text;
  final List<int> rowOffsets;
  const _LoadedText(this.snapshot, this.text, this.rowOffsets);
}

_LoadedText _decodeDocument(Uint8List bytes) {
  String text;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) throw const AppFailure('文本编码无效。');
    final data = ByteData.sublistView(bytes);
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    text = String.fromCharCodes([
      for (var index = 2; index < bytes.length; index += 2)
        data.getUint16(index, endian),
    ]);
  } else {
    final start =
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? 3
        : 0;
    try {
      text = utf8.decode(bytes.sublist(start));
    } on FormatException {
      throw const AppFailure('文本编码暂不支持，请转换为 UTF-8 或使用其他应用打开。');
    }
  }
  if (text.contains('\u0000')) {
    throw const AppFailure('文件包含二进制内容，请使用其他应用打开。');
  }
  text = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\t', '    ');
  final lines = <String>[];
  final offsets = <int>[];
  var maxColumns = 1;
  var lineOffset = 0;
  while (true) {
    final newline = text.indexOf('\n', lineOffset);
    final line = text.substring(
      lineOffset,
      newline < 0 ? text.length : newline,
    );
    if (line.isEmpty) {
      lines.add('');
      offsets.add(lineOffset);
    }
    for (var start = 0; start < line.length;) {
      var end = math.min(start + 2048, line.length);
      if (end < line.length && _highSurrogate(line.codeUnitAt(end - 1))) end--;
      final row = line.substring(start, end);
      lines.add(row);
      offsets.add(lineOffset + start);
      var columns = 0;
      for (final rune in row.runes) {
        columns += rune >= 0x1100 ? 2 : 1;
      }
      maxColumns = math.max(maxColumns, columns);
      start = end;
    }
    if (lines.length > 200000) {
      throw const AppFailure('文本行数过多，请使用其他应用打开。');
    }
    if (newline < 0) break;
    lineOffset = newline + 1;
  }
  return _LoadedText(
    TextDocumentSnapshot(
      lines: List.unmodifiable(lines),
      maxColumns: maxColumns,
    ),
    text,
    offsets,
  );
}

bool _highSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

TextSearchResult _searchDocument(_LoadedText? document, String query) {
  if (document == null || query.isEmpty) return const TextSearchResult();
  final pattern = RegExp(
    RegExp.escape(query),
    caseSensitive: false,
    unicode: true,
  );
  final matches = <TextMatch>[];
  final byRow = <int, List<TextMatch>>{};
  TextSearchResult result({bool truncated = false}) => TextSearchResult(
    matches: List.unmodifiable(matches),
    matchesByRow: Map.unmodifiable({
      for (final entry in byRow.entries)
        entry.key: List<TextMatch>.unmodifiable(entry.value),
    }),
    truncated: truncated,
  );
  for (final match in pattern.allMatches(document.text)) {
    if (matches.length == 10000) return result(truncated: true);
    var low = 0, high = document.rowOffsets.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (document.rowOffsets[middle] <= match.start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final first = math.max(0, low - 1);
    TextMatch? representative;
    for (
      var row = first;
      row < document.rowOffsets.length && document.rowOffsets[row] < match.end;
      row++
    ) {
      final offset = document.rowOffsets[row];
      final start = math.max(0, match.start - offset);
      final end = math.min(
        document.snapshot.lines[row].length,
        match.end - offset,
      );
      if (end <= start) continue;
      final value = TextMatch(row, start, end, id: matches.length);
      representative ??= value;
      (byRow[row] ??= []).add(value);
    }
    matches.add(
      representative ??
          TextMatch(
            first,
            document.snapshot.lines[first].length,
            document.snapshot.lines[first].length,
            id: matches.length,
          ),
    );
  }
  return result();
}

/// Event-driven cleanup: call at application startup and before another
/// external handoff. There is no maintenance timer or idle polling.
Future<void> cleanupExternalFileCache(
  String cacheDirectory, {
  Duration maxAge = const Duration(hours: 24),
  bool removeIncomplete = false,
  DateTime? incompleteBefore,
}) {
  // Capture on the caller before scheduling the worker. A startup cleanup may
  // race with a newer user download and must never remove that new staging.
  final cutoff = incompleteBefore ?? DateTime.now();
  return Isolate.run(
    () => _cleanupExternalCache(
      cacheDirectory,
      maxAge: maxAge,
      removeIncomplete: removeIncomplete,
      incompleteBefore: cutoff,
    ),
  );
}

Future<void> _cleanupExternalCache(
  String path, {
  Duration maxAge = const Duration(hours: 24),
  bool removeIncomplete = false,
  DateTime? incompleteBefore,
}) async {
  final directory = Directory(path);
  if (!await directory.exists()) return;
  final now = DateTime.now();
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory || !p.basename(entity.path).startsWith('open-')) {
      continue;
    }
    final complete = File(p.join(entity.path, '.complete'));
    final stat = await entity.stat();
    final expired = now.difference(stat.modified) >= maxAge;
    final staleIncomplete =
        removeIncomplete &&
        !stat.modified.isAfter(incompleteBefore ?? now) &&
        !await complete.exists();
    if (expired || staleIncomplete) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<int> _externalCacheSize(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) return 0;
  var bytes = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      bytes += (await entity.stat()).size;
    }
  }
  return bytes;
}

Future<void> _discardStaging(String path) => Isolate.run(() async {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
});

/// Only deletes an owned staging directory; callers must not pass source
/// paths. The completion marker distinguishes it from an ordinary folder.
Future<void> discardExternalFile(String path) => Isolate.run(() async {
  final parent = p.dirname(path);
  if (p.basename(parent) != 'payload') return;
  final directory = Directory(p.dirname(parent));
  if (!p.basename(directory.path).startsWith('open-') ||
      !await File(p.join(directory.path, '.complete')).exists()) {
    return;
  }
  try {
    await directory.delete(recursive: true);
  } catch (_) {}
});
