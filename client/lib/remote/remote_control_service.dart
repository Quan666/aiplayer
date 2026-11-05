import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:qr/qr.dart';

import 'remote_control_page.dart';

class RemoteCommand {
  final int id;
  final String action;
  final String? text;
  final int? editSession, positionMs;
  final bool Function() _current;
  const RemoteCommand(
    this.id,
    this.action,
    this.text,
    this.editSession,
    this.positionMs,
    this._current,
  );
  bool get isCurrent => _current();
}

class RemoteCommandResult {
  final bool ok;
  final String message;
  const RemoteCommandResult(this.ok, [this.message = '']);
  static const unavailable = RemoteCommandResult(false, '当前操作不可用');
}

class RemoteControlStatus {
  final bool playing, active, editing, obscured;
  final int editSession, positionMs, durationMs;
  const RemoteControlStatus({
    this.playing = false,
    this.active = false,
    this.editing = false,
    this.obscured = false,
    this.editSession = 0,
    this.positionMs = 0,
    this.durationMs = 0,
  });
  Map<String, Object> toMessage() => {
    'type': 'status',
    'playing': playing,
    'active': active,
    'editing': editing,
    'obscured': obscured,
    'editSession': editSession,
    'positionMs': positionMs,
    'durationMs': durationMs,
  };
}

class RemoteControlState {
  final String phase, message;
  final Uri? pairingUrl;
  final List<String> addresses;
  final Uint8List? qr;
  final int qrSize;
  const RemoteControlState({
    this.phase = 'stopped',
    this.message = '',
    this.pairingUrl,
    this.addresses = const [],
    this.qr,
    this.qrSize = 0,
  });
  bool get running => const {
    'starting',
    'pairing',
    'connected',
    'reconnecting',
  }.contains(phase);
  bool get connected => phase == 'connected';
}

/// The UI receives only validated small commands; all sockets, parsing, token
/// creation and QR encoding belong to one explicitly started worker isolate.
class RemoteControlService extends ValueNotifier<RemoteControlState> {
  final Future<RemoteCommandResult> Function(RemoteCommand command) onCommand;
  Isolate? _isolate;
  ReceivePort? _port;
  StreamSubscription<dynamic>? _subscription;
  SendPort? _requests;
  Completer<void>? _finished;
  Completer<void>? _ready;
  int _generation = 0, _connectionRevision = 0;
  bool _disposed = false, _handling = false;
  RemoteControlStatus _status = const RemoteControlStatus();
  RemoteControlStatus get status => _status;

  RemoteControlService({required this.onCommand})
    : super(const RemoteControlState());

  Future<void> start({
    String? address,
    @visibleForTesting bool allowLoopback = false,
    @visibleForTesting Duration pairingLifetime = const Duration(minutes: 2),
    @visibleForTesting Duration sessionLifetime = const Duration(hours: 2),
  }) async {
    final stopping = stop();
    final expectedGeneration = _generation;
    await stopping;
    if (_disposed || expectedGeneration != _generation) return;
    final generation = ++_generation;
    value = const RemoteControlState(phase: 'starting');
    final port = _port = ReceivePort();
    final finished = _finished = Completer<void>();
    final ready = _ready = Completer<void>();
    // A stop can arrive while Isolate.spawn is still completing.
    unawaited(ready.future.catchError((Object _) {}));
    _subscription = port.listen((dynamic event) {
      if (event == null || event is List) {
        if (!finished.isCompleted) finished.complete();
        if (!ready.isCompleted) ready.completeError(StateError('手机控制启动失败'));
        if (generation == _generation && !_disposed) {
          _generation++;
          _releaseEndedWorker();
          value = const RemoteControlState(message: '手机控制已结束');
        }
        return;
      }
      if (event is! Map) return;
      if (event['type'] == 'stopped') {
        if (!finished.isCompleted) finished.complete();
        if (!ready.isCompleted) ready.completeError(StateError('手机控制启动失败'));
      }
      if (generation != _generation || _disposed) return;
      switch (event['type']) {
        case 'port':
          _requests = event['port'] as SendPort;
        case 'ready':
          value = RemoteControlState(
            phase: 'pairing',
            pairingUrl: Uri.parse(event['url'] as String),
            addresses: List<String>.unmodifiable(event['addresses'] as List),
            qr: event['qr'] as Uint8List,
            qrSize: event['qrSize'] as int,
          );
          _requests?.send(('status', _status.toMessage()));
          if (!ready.isCompleted) ready.complete();
        case 'connected':
        case 'reconnecting':
          _connectionRevision++;
          value = RemoteControlState(
            phase: event['type'] as String,
            pairingUrl: value.pairingUrl,
            addresses: value.addresses,
          );
        case 'command':
          unawaited(_dispatch(event, generation));
        case 'stopped':
          _generation++;
          _releaseEndedWorker();
          value = RemoteControlState(
            message: event['message'] as String? ?? '手机控制已结束',
          );
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _remoteWorker,
        (
          port.sendPort,
          address,
          allowLoopback,
          pairingLifetime.inMilliseconds,
          sessionLifetime.inMilliseconds,
        ),
        debugName: 'phone-remote',
        onExit: port.sendPort,
        onError: port.sendPort,
      );
      if (generation != _generation || _disposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
      await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      if (generation == _generation && !_disposed) {
        await stop();
        if (!_disposed) {
          value = const RemoteControlState(message: '无法启动手机控制，请检查局域网连接与权限');
        }
      }
    }
  }

  Future<void> _dispatch(Map<dynamic, dynamic> data, int generation) async {
    final requestId = data['id'] as int;
    if (_handling) {
      _requests?.send(('result', requestId, false, '请等待上一项操作完成'));
      return;
    }
    _handling = true;
    final connection = _connectionRevision;
    final command = RemoteCommand(
      requestId,
      data['action'] as String,
      data['text'] as String?,
      data['editSession'] as int?,
      data['positionMs'] as int?,
      () =>
          !_disposed &&
          generation == _generation &&
          connection == _connectionRevision &&
          value.connected,
    );
    try {
      if (!command.isCurrent) return;
      final result = await onCommand(command);
      if (command.isCurrent) {
        _requests?.send(('result', requestId, result.ok, result.message));
      }
    } catch (_) {
      if (command.isCurrent) {
        _requests?.send(('result', requestId, false, '操作未完成，请重试'));
      }
    } finally {
      _handling = false;
    }
  }

  void publish(RemoteControlStatus status) {
    _status = status;
    if (!_disposed && value.running) {
      _requests?.send(('status', status.toMessage()));
    }
  }

  void _releaseEndedWorker() {
    _requests = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _port?.close();
    _port = null;
    _finished = null;
    _ready = null;
  }

  /// Invalidation happens before the first await, including paused lifecycle
  /// callbacks on devices that will never draw another frame.
  Future<void> stop() async {
    _generation++;
    _connectionRevision++;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('手机控制已取消'));
    }
    final port = _port, subscription = _subscription, isolate = _isolate;
    final finished = _finished;
    _requests?.send('stop');
    _requests = null;
    _port = null;
    _subscription = null;
    _isolate = null;
    _finished = null;
    if (!_disposed) value = const RemoteControlState();
    if (isolate != null && finished != null) {
      try {
        await finished.future.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        /* Force a bounded native socket teardown. */
      }
      isolate.kill(priority: Isolate.immediate);
    }
    await subscription?.cancel();
    port?.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

Future<void> _remoteWorker(
  (SendPort, String?, bool, int, int) configuration,
) async {
  final (owner, requestedAddress, allowLoopback, pairingMs, sessionMs) =
      configuration;
  final requests = ReceivePort();
  final host = _RemoteHost(owner, requests, pairingMs, sessionMs);
  owner.send({'type': 'port', 'port': requests.sendPort});
  requests.listen(host.message);
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: allowLoopback,
      includeLinkLocal: false,
    );
    final addresses = <String>{
      for (final interface in interfaces)
        if (!RegExp(
          r'^(tun|tap|utun|wg)',
          caseSensitive: false,
        ).hasMatch(interface.name))
          for (final address in interface.addresses)
            if (_privateAddress(address, allowLoopback)) address.address,
    }.toList();
    if (requestedAddress != null &&
        allowLoopback &&
        InternetAddress.tryParse(requestedAddress)?.isLoopback == true &&
        !addresses.contains(requestedAddress)) {
      addresses.add(requestedAddress);
    }
    final address = requestedAddress ?? addresses.firstOrNull;
    if (address == null || !addresses.contains(address)) {
      await host.close('没有可用的局域网地址');
      return;
    }
    await host.start(address, addresses);
  } catch (_) {
    await host.close('无法启动手机控制，请检查局域网连接与权限');
  }
}

bool _privateAddress(InternetAddress address, bool loopback) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return loopback && address.isLoopback ||
      b[0] == 10 ||
      b[0] == 192 && b[1] == 168 ||
      b[0] == 172 && b[1] >= 16 && b[1] <= 31;
}

class _RemoteHost {
  final SendPort owner;
  final ReceivePort requests;
  final int pairingMs, sessionMs;
  final _random = Random.secure();
  final _pending = <Map<String, Object?>>[];
  final _connections = <HttpResponse>{};
  HttpServer? _server;
  WebSocket? _socket;
  Timer? _expiry, _reconnect, _commandDeadline;
  String _origin = '', _authority = '', _pairToken = '', _session = '';
  String? _clientAddress;
  bool _closed = false, _paired = false, _upgrading = false;
  int _requestCount = 0, _lastId = 0, _windowCommands = 0, _serial = 0;
  int? _inFlight, _inFlightClientId;
  DateTime _commandWindow = DateTime.now();
  Map<String, Object> _status = const {'type': 'status', 'editing': false};

  _RemoteHost(this.owner, this.requests, this.pairingMs, this.sessionMs);
  String _token() =>
      base64UrlEncode(List<int>.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  Future<void> start(String address, List<String> addresses) async {
    final server = await HttpServer.bind(address, 0);
    if (_closed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.idleTimeout = const Duration(seconds: 8);
    _authority = '$address:${server.port}';
    _origin = 'http://$_authority';
    _pairToken = _token();
    final url = '$_origin/#$_pairToken';
    final code = QrImage(
      QrCode(
        payload: QrPayload.fromString(url),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    final bits = Uint8List(code.moduleCount * code.moduleCount);
    for (var row = 0; row < code.moduleCount; row++) {
      for (var column = 0; column < code.moduleCount; column++) {
        if (code.isDark(row, column)) bits[row * code.moduleCount + column] = 1;
      }
    }
    owner.send({
      'type': 'ready',
      'url': url,
      'addresses': addresses,
      'qr': bits,
      'qrSize': code.moduleCount,
    });
    _expiry = Timer(Duration(milliseconds: pairingMs), () {
      unawaited(close('二维码已过期，请重新配对'));
    });
    server.listen(
      (request) => unawaited(_request(request)),
      onError: (_) => unawaited(close('局域网连接已关闭')),
    );
  }

  void message(dynamic message) {
    if (message == 'stop') {
      unawaited(close('手机控制已关闭'));
      return;
    }
    if (_closed) return;
    if (message is (String, Map<String, Object>) && message.$1 == 'status') {
      if (jsonEncode(_status) == jsonEncode(message.$2)) return;
      _status = message.$2;
      _send(_status);
    } else if (message is (String, int, bool, String) &&
        message.$1 == 'result') {
      if (_inFlight != message.$2) return;
      _commandDeadline?.cancel();
      _commandDeadline = null;
      _inFlight = null;
      _send({
        'type': 'result',
        'id': _inFlightClientId,
        'ok': message.$3,
        'message': message.$4.length > 120 ? '操作未完成' : message.$4,
      });
      _drain();
    }
  }

  Future<void> _request(HttpRequest request) async {
    final response = request.response;
    var ownsUpgrade = false;
    _connections.add(response);
    _requestCount++;
    if (_closed || _requestCount > 8) {
      _requestCount--;
      _connections.remove(response);
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
      if (request.headers.value(HttpHeaders.hostHeader) != _authority) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method == 'GET' &&
          const {'/', '/app.js', '/style.css'}.contains(request.uri.path)) {
        final path = request.uri.path;
        response.headers.contentType = ContentType(
          path == '/app.js' ? 'application' : 'text',
          path == '/app.js'
              ? 'javascript'
              : path == '/style.css'
              ? 'css'
              : 'html',
          charset: 'utf-8',
        );
        response.write(
          path == '/app.js'
              ? remoteControlJs
              : path == '/style.css'
              ? remoteControlCss
              : remoteControlHtml,
        );
        return;
      }
      if (request.headers.value('origin') != _origin) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/pair') {
        if (_paired ||
            request.headers.contentType?.mimeType != 'application/json') {
          response.statusCode = HttpStatus.conflict;
          return;
        }
        final body = await _body(request);
        // Another request may finish pairing while this body is arriving.
        // Recheck after the await so the cleared one-use token can never be
        // accepted by an already-open request carrying an empty token.
        if (_closed ||
            _paired ||
            _pairToken.isEmpty ||
            body['token'] != _pairToken) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        _paired = true;
        _pairToken = '';
        _session = _token();
        _clientAddress = request.connectionInfo?.remoteAddress.address;
        _expiry?.cancel();
        _expiry = Timer(Duration(milliseconds: sessionMs), () {
          unawaited(close('控制会话已结束，请重新配对'));
        });
        _reconnect = Timer(const Duration(seconds: 30), () {
          unawaited(close('手机未连接，请重新配对'));
        });
        response.cookies.add(
          Cookie('aiplayer_remote', _session)
            ..httpOnly = true
            ..sameSite = SameSite.strict
            ..path = '/',
        );
        response.headers.contentType = ContentType.json;
        response.write('{"paired":true}');
      } else if (request.method == 'GET' && request.uri.path == '/control') {
        final cookie = request.cookies
            .where((c) => c.name == 'aiplayer_remote')
            .firstOrNull
            ?.value;
        if (!_paired ||
            cookie != _session ||
            _socket != null ||
            _upgrading ||
            request.connectionInfo?.remoteAddress.address != _clientAddress ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        _upgrading = true;
        ownsUpgrade = true;
        _connections.remove(response);
        final socket = await WebSocketTransformer.upgrade(
          request,
          compression: CompressionOptions.compressionOff,
        );
        if (_closed) {
          await socket.close();
          return;
        }
        _socket = socket;
        _upgrading = false;
        _lastId = 0;
        _reconnect?.cancel();
        _reconnect = null;
        owner.send({'type': 'connected'});
        _send(_status);
        socket.listen(
          _command,
          onDone: () => _disconnected(socket),
          onError: (_) => _disconnected(socket),
        );
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      if (_connections.contains(response)) {
        response.statusCode = HttpStatus.badRequest;
      }
      if (ownsUpgrade) _upgrading = false;
    } finally {
      _requestCount--;
      if (_connections.remove(response)) {
        try {
          await response.close().timeout(const Duration(seconds: 3));
        } catch (_) {
          /* Socket deadline or stop already owns teardown. */
        }
      }
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.contentLength > 8192) {
      throw const FormatException('Request too large');
    }
    final done = Completer<Map<String, dynamic>>();
    final bytes = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> subscription;
    late Timer timer;
    void fail() {
      unawaited(subscription.cancel());
      timer.cancel();
      if (!done.isCompleted) {
        done.completeError(const FormatException('Invalid request'));
      }
    }

    subscription = request.listen(
      (chunk) {
        if (bytes.length + chunk.length > 8192) {
          fail();
          return;
        }
        bytes.add(chunk);
      },
      onDone: () {
        timer.cancel();
        if (done.isCompleted) return;
        try {
          final value = jsonDecode(utf8.decode(bytes.takeBytes()));
          if (value is! Map<String, dynamic>) throw const FormatException();
          done.complete(value);
        } catch (_) {
          fail();
        }
      },
      onError: (_) => fail(),
    );
    timer = Timer(const Duration(seconds: 3), fail);
    return done.future;
  }

  void _command(dynamic raw) {
    if (_closed || raw is! String || raw.length > 8192) {
      unawaited(close('无效控制消息'));
      return;
    }
    final now = DateTime.now();
    if (now.difference(_commandWindow) >= const Duration(seconds: 1)) {
      _commandWindow = now;
      _windowCommands = 0;
    }
    if (++_windowCommands > 24) {
      unawaited(close('控制请求过于频繁'));
      return;
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();
      final id = value['id'], action = value['action'];
      if (id is! int ||
          id <= _lastId ||
          id > 9007199254740991 ||
          action is! String ||
          !const {
            'up',
            'down',
            'left',
            'right',
            'select',
            'back',
            'text',
            'submit',
            'play',
            'pause',
            'toggle',
            'next',
            'previous',
            'seek',
            'seekForward',
            'seekBackward',
            'zoomIn',
            'zoomOut',
            'rotate',
          }.contains(action)) {
        throw const FormatException();
      }
      final text = value['text'],
          edit = value['editSession'],
          position = value['positionMs'];
      if (action == 'text' &&
              (text is! String ||
                  text.length > 4096 ||
                  text.contains('\x00')) ||
          const {'text', 'submit'}.contains(action) &&
              (edit is! int || edit < 0) ||
          action == 'seek' &&
              (position is! int || position < 0 || position > 604800000)) {
        throw const FormatException();
      }
      _lastId = id;
      if (_pending.length >= 8) {
        _send({
          'type': 'result',
          'id': id,
          'ok': false,
          'message': '请等待上一项操作完成',
        });
        return;
      }
      _pending.add({
        'type': 'command',
        'id': ++_serial,
        'clientId': id,
        'action': action,
        'text': action == 'text' ? text : null,
        'editSession': const {'text', 'submit'}.contains(action) ? edit : null,
        'positionMs': action == 'seek' ? position : null,
      });
      _drain();
    } catch (_) {
      unawaited(close('无效控制消息'));
    }
  }

  void _drain() {
    if (_closed || _socket == null || _inFlight != null || _pending.isEmpty) {
      return;
    }
    final command = _pending.removeAt(0);
    _inFlight = command['id'] as int;
    _inFlightClientId = command['clientId'] as int;
    owner.send(command);
    _commandDeadline = Timer(const Duration(seconds: 10), () {
      unawaited(close('操作超时，请重新连接'));
    });
  }

  void _send(Map<String, Object?> value) {
    final socket = _socket;
    if (socket == null || _closed || socket.readyState != WebSocket.open) {
      return;
    }
    socket.add(jsonEncode(value));
  }

  void _disconnected(WebSocket socket) {
    if (_closed || _socket != socket) return;
    _socket = null;
    _pending.clear();
    _commandDeadline?.cancel();
    _commandDeadline = null;
    _inFlight = null;
    owner.send({'type': 'reconnecting'});
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 30), () {
      unawaited(close('手机已断开，请重新配对'));
    });
  }

  Future<void> close(String message) async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    _expiry?.cancel();
    _reconnect?.cancel();
    _commandDeadline?.cancel();
    _session = '';
    _pairToken = '';
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _connections.clear();
    owner.send({'type': 'stopped', 'message': message});
    requests.close();
  }
}
