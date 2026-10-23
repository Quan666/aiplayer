import 'dart:async';
import 'dart:isolate';
import 'failure.dart';

/// Supervises the native worker without trying to kill an active FFI call.
/// A timed-out startup keeps a listener solely to close a late connection.
class SmbWorkerChannel {
  final ReceivePort _events = ReceivePort();
  final Completer<SmbWorkerChannel> _ready = Completer();
  final Set<Completer<dynamic>> _pending = {};
  int? _exitCode;
  final Duration timeout;
  SendPort? _port;
  int dialect = 0;
  bool _abandoned = false;
  bool _closed = false;
  Future<void>? _closing;

  SmbWorkerChannel._(this.timeout) {
    _events.listen(_onEvent);
  }

  static Future<SmbWorkerChannel> start(
    void Function(List<dynamic>) entry,
    List<dynamic> arguments, {
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final worker = SmbWorkerChannel._(timeout);
    unawaited(worker._spawn(entry, arguments));
    try {
      return await worker._ready.future.timeout(timeout);
    } on TimeoutException {
      worker._abandoned = true;
      throw const SmbFailure(-110);
    }
  }

  Future<void> _spawn(
    void Function(List<dynamic>) entry,
    List<dynamic> arguments,
  ) async {
    try {
      await Isolate.spawn(
        entry,
        [_events.sendPort, ...arguments],
        onError: _events.sendPort,
        onExit: _events.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      _stop(-9001);
    }
  }

  void _onEvent(dynamic event) {
    if (event is List &&
        event.length == 2 &&
        event[0] is SendPort &&
        event[1] is int) {
      _port = event[0] as SendPort;
      dialect = event[1] as int;
      if (_abandoned) {
        // The caller has already received its timeout. Let the native worker
        // dispose its context normally when the outstanding FFI call returns.
        unawaited(close().catchError((Object _) {}));
      } else if (!_ready.isCompleted) {
        _ready.complete(this);
      }
    } else if (event is int) {
      _stop(event);
    } else {
      // null is onExit; a list of strings is onError. Never expose native
      // stack/error text, which may contain server names or credentials.
      _stop(-9003);
    }
  }

  void _stop(int code) {
    if (!_ready.isCompleted) _ready.completeError(SmbFailure(code));
    _exitCode ??= code;
    for (final response in _pending) {
      if (!response.isCompleted) {
        response.complete({'error': true, 'code': _exitCode});
      }
    }
    _events.close();
  }

  Future<dynamic> call(String method, List<dynamic> args) async {
    if (_closed) throw StateError('SMB 连接已关闭');
    if (_exitCode != null) throw SmbFailure(_exitCode!);
    final reply = ReceivePort();
    final response = Completer<dynamic>();
    _pending.add(response);
    reply.listen((dynamic value) {
      if (!response.isCompleted) response.complete(value);
    });
    _port!.send([method, args, reply.sendPort]);
    try {
      final value = await response.future.timeout(timeout);
      if (value is Map && value['error'] == true) {
        throw SmbFailure(value['code'] as int? ?? 0);
      }
      return value;
    } on TimeoutException {
      throw const SmbFailure(-110);
    } finally {
      _pending.remove(response);
      reply.close();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    try {
      await call('close', []);
    } on SmbFailure catch (failure) {
      // onExit and the close reply use different ports and may race.
      if (failure.code != -9003) rethrow;
    } finally {
      _closed = true;
    }
  }
}
