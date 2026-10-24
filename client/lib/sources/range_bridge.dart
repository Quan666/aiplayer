import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/services.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../core/system_proxy.dart';
import 'source.dart';

class ByteRange {
  final int start, end;
  const ByteRange(this.start, this.end);
  int get length => end - start + 1;
  static ByteRange? parse(String? header, int size) {
    if (size <= 0) return null;
    if (header == null) return ByteRange(0, size - 1);
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (m == null) return null;
    if (m[1]!.isEmpty) {
      final count = int.tryParse(m[2]!);
      if (count == null || count <= 0) return null;
      return ByteRange(max(0, size - count), size - 1);
    }
    final start = int.tryParse(m[1]!),
        requestedEnd = m[2]!.isEmpty ? size - 1 : int.tryParse(m[2]!);
    if (start == null ||
        requestedEnd == null ||
        start >= size ||
        requestedEnd < start) {
      return null;
    }
    return ByteRange(start, min(size - 1, requestedEnd));
  }
}

class RangeBridge {
  final SourceAdapter source;
  final String path;
  final SourceEntry entry;
  final HttpServer? _server;
  final String _token;
  final int _port;
  final _HttpBridgeWorker? _worker;
  bool _closed = false;
  Future<void>? _closing;
  RangeBridge._(
    this.source,
    this.path,
    this.entry,
    this._server,
    this._token,
    this._port, [
    this._worker,
  ]);

  static Future<RangeBridge> open(
    SourceAdapter source,
    String path, {
    SourceEntry? entry,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (source is HttpSource) {
      final worker = await _HttpBridgeWorker.open(source, path, entry, cancel);
      return RangeBridge._(
        source,
        path,
        worker.entry,
        null,
        worker.uri.pathSegments.first,
        worker.uri.port,
        worker,
      );
    }
    return _openServer(source, path, entry, cancel: cancel);
  }

  static Future<RangeBridge> _openServer(
    SourceAdapter source,
    String path,
    SourceEntry? knownEntry, {
    CancelToken? cancel,
  }) async {
    final entry = knownEntry ?? await source.stat(path);
    cancel?.check();
    if (entry.directory || entry.size <= 0) {
      throw const AppFailure('无法播放空文件或目录。');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (cancel?.cancelled == true) {
      await server.close(force: true);
      throw const Cancelled();
    }
    final random = Random.secure();
    final bridge = RangeBridge._(
      source,
      path,
      entry,
      server,
      base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', ''),
      server.port,
    );
    server.listen(bridge._serve);
    return bridge;
  }

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _port,
    path: '/$_token/${entry.name}',
  );
  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (_closed || request.uri.pathSegments.firstOrNull != _token) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      if (!['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 405;
        await response.close();
        return;
      }
      final header = request.headers.value('range'),
          range = ByteRange.parse(header, entry.size);
      if (range == null || !entry.seekable && range.start > 0) {
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */${entry.size}');
        await response.close();
        return;
      }
      response.statusCode = header == null ? 200 : 206;
      response.headers.set('Accept-Ranges', entry.seekable ? 'bytes' : 'none');
      response.headers.set('Cache-Control', 'no-store');
      response.headers.contentType = ContentType.binary;
      response.contentLength = range.length;
      response.bufferOutput = false;
      if (header != null) {
        response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/${entry.size}',
        );
      }
      if (request.method == 'GET') {
        await response.addStream(source.read(path, range.start, range.end));
      }
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {
        /* player abandoned the seek */
      }
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_worker case final worker?) {
      await worker.close();
    } else {
      await _server?.close(force: true);
    }
  }
}

/// Only connection configuration and lifecycle messages cross this boundary.
/// The worker owns both HTTP sockets, so video bytes never visit the UI isolate.
class _HttpBridgeWorker {
  final Isolate _isolate;
  final ReceivePort _messages;
  final StreamSubscription<dynamic> _subscription;
  final SendPort _commands;
  final Future<void> _exited;
  final SourceEntry entry;
  final Uri uri;

  _HttpBridgeWorker(
    this._isolate,
    this._messages,
    this._subscription,
    this._commands,
    this._exited,
    this.entry,
    this.uri,
  );

  static Future<_HttpBridgeWorker> open(
    HttpSource source,
    String path,
    SourceEntry? entry,
    CancelToken? cancel,
  ) async {
    final messages = ReceivePort();
    final ready = Completer<(SendPort, String, SourceEntry)>();
    final controls = Completer<SendPort>();
    final exited = Completer<void>();
    final subscription = messages.listen((dynamic message) {
      if (message case ('starting', SendPort commands)) {
        if (!controls.isCompleted) controls.complete(commands);
      } else if (message case (
        'ready',
        SendPort commands,
        String uri,
        SourceEntry entry,
      )) {
        if (!ready.isCompleted) ready.complete((commands, uri, entry));
      } else if (message case ('error', String message, int? status)) {
        if (!ready.isCompleted) {
          ready.completeError(AppFailure(message, status));
        }
      } else if (message == null) {
        if (!exited.isCompleted) exited.complete();
        if (!ready.isCompleted) {
          ready.completeError(const AppFailure('视频读取服务已停止，请重试。'));
        }
      } else if (!ready.isCompleted) {
        // Uncaught isolate errors can contain URLs or credentials; do not
        // propagate their raw text across the user-facing failure boundary.
        ready.completeError(const AppFailure('无法启动视频读取服务，请重试。'));
      }
    });
    Isolate? isolate;
    Timer? timeout;
    try {
      isolate = await Isolate.spawn(
        _serveHttpBridge,
        _HttpBridgeConfiguration(
          messages.sendPort,
          source.base.toString(),
          source.webdav,
          source.user,
          source.password,
          source.displayName,
          path,
          entry,
          ServicesBinding.rootIsolateToken,
        ),
        onError: messages.sendPort,
        onExit: messages.sendPort,
        debugName: 'video-http-bridge',
      );
      timeout = Timer(const Duration(seconds: 60), () {
        if (!ready.isCompleted) {
          ready.completeError(const AppFailure('视频来源连接超时，请重试。'));
        }
      });
      final (commands, uri, actualEntry) = await Future.any([
        ready.future,
        if (cancel != null)
          cancel.whenCancelled.then<(SendPort, String, SourceEntry)>(
            (_) => throw const Cancelled(),
          ),
      ]);
      cancel?.check();
      return _HttpBridgeWorker(
        isolate,
        messages,
        subscription,
        commands,
        exited.future,
        actualEntry,
        Uri.parse(uri),
      );
    } catch (_) {
      if (isolate != null) {
        // Closing HttpClient releases its sockets immediately; killing an
        // isolate alone can leave native socket cleanup waiting for GC.
        final commands = await Future.any<SendPort?>([
          controls.future,
          exited.future.then((_) => null),
        ]).timeout(const Duration(milliseconds: 250), onTimeout: () => null);
        commands?.send('close');
        try {
          await exited.future.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          isolate.kill(priority: Isolate.immediate);
        }
      }
      await subscription.cancel();
      messages.close();
      rethrow;
    } finally {
      timeout?.cancel();
    }
  }

  Future<void> close() async {
    _commands.send('close');
    try {
      await _exited.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A hung upstream socket must not keep an abandoned decoder alive.
      _isolate.kill(priority: Isolate.immediate);
    } finally {
      await _subscription.cancel();
      _messages.close();
    }
  }
}

class _HttpBridgeConfiguration {
  final SendPort reply;
  final String address, user, password, displayName, path;
  final bool webdav;
  final SourceEntry? entry;
  final RootIsolateToken? rootIsolateToken;
  const _HttpBridgeConfiguration(
    this.reply,
    this.address,
    this.webdav,
    this.user,
    this.password,
    this.displayName,
    this.path,
    this.entry,
    this.rootIsolateToken,
  );
}

Future<void> _serveHttpBridge(_HttpBridgeConfiguration configuration) async {
  initializeSystemProxyWorker(configuration.rootIsolateToken);
  final commands = ReceivePort();
  final stopped = Completer<void>();
  HttpSource? source;
  RangeBridge? bridge;
  commands.listen((_) {
    if (!stopped.isCompleted) stopped.complete();
    // This listener is live during the initial stat request as well as reads.
    // It must not wait for the stalled request before closing its HTTP client.
    unawaited(source?.close());
  });
  try {
    source = HttpSource(
      configuration.address,
      webdav: configuration.webdav,
      user: configuration.user,
      password: configuration.password,
      displayName: configuration.displayName,
    );
    configuration.reply.send(('starting', commands.sendPort));
    bridge = await RangeBridge._openServer(
      source,
      configuration.path,
      configuration.entry,
    );
    if (stopped.isCompleted) return;
    configuration.reply.send((
      'ready',
      commands.sendPort,
      bridge.uri.toString(),
      bridge.entry,
    ));
    await stopped.future;
  } catch (error) {
    final failure = safeFailure(error, action: '打开视频读取服务失败');
    configuration.reply.send(('error', failure.message, failure.status));
  } finally {
    commands.close();
    await bridge?.close();
    await source?.close();
  }
}
