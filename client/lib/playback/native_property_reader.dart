import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;

/// Reads a borrowed libmpv handle outside the caller's isolate.
///
/// Native property reads can wait for the playback core even though media_kit's
/// getProperty returns a Future. Keep one worker and at most four accepted
/// requests, including the active request. The owner must await [close] before
/// destroying the handle; this reader never owns or destroys the player.
class NativePropertyReader {
  static const maxPendingRequests = 4;
  static const maxPropertiesPerRequest = 32;

  final String libraryPath;
  final int handleAddress;
  final _pending = <int, Completer<Map<String, String>>>{};
  final _outbox = <List<Object?>>[];
  final _closed = Completer<void>();
  ReceivePort? _messages;
  SendPort? _commands;
  int _serial = 0;
  bool _started = false, _closing = false, _stopped = false;

  NativePropertyReader({
    required this.libraryPath,
    required this.handleAddress,
  }) {
    if (libraryPath.isEmpty) {
      throw ArgumentError.value(libraryPath, 'libraryPath');
    }
    if (handleAddress == 0) {
      throw ArgumentError.value(handleAddress, 'handleAddress');
    }
  }

  Future<Map<String, String>> read(List<String> names) {
    if (_closing) return Future.error(StateError('Property reader is closed.'));
    if (names.length > maxPropertiesPerRequest ||
        names.any((name) => name.isEmpty || name.length > 256)) {
      return Future.error(ArgumentError.value(names, 'names'));
    }
    if (_pending.length >= maxPendingRequests) {
      return Future.error(StateError('Property reader is busy.'));
    }
    final result = Completer<Map<String, String>>();
    final id = ++_serial;
    _pending[id] = result;
    _send(['read', id, List<String>.of(names)]);
    if (!_started) {
      _started = true;
      unawaited(_start());
    }
    return result.future;
  }

  void _send(List<Object?> message) {
    final commands = _commands;
    if (commands == null) {
      _outbox.add(message);
    } else {
      commands.send(message);
    }
  }

  Future<void> _start() async {
    final messages = _messages = ReceivePort();
    messages.listen(_receive);
    try {
      await Isolate.spawn(
        _nativePropertyWorker,
        (messages.sendPort, libraryPath, handleAddress),
        onError: messages.sendPort,
        onExit: messages.sendPort,
        errorsAreFatal: true,
        debugName: 'native-properties',
      );
    } catch (error) {
      // Spawn failed, so no worker can still be using the borrowed handle.
      _fail(StateError('Could not start property reader: $error'));
      _finish();
    }
  }

  void _receive(dynamic message) {
    if (message == null) {
      // Results and the exit notification share a port, preserving their order.
      // Only exit releases close(), never a timeout or an error notification.
      _fail(StateError('Property reader stopped.'));
      _finish();
    } else if (message is SendPort) {
      _commands = message;
      for (final command in _outbox) {
        message.send(command);
      }
      _outbox.clear();
    } else if (message is List && message.first == 'result') {
      final result = _pending.remove(message[1] as int);
      result?.complete(Map<String, String>.unmodifiable(message[2] as Map));
    } else if (message is List && message.first == 'error') {
      _pending
          .remove(message[1] as int)
          ?.completeError(StateError(message[2] as String));
    } else {
      // Initialization failures and uncaught isolate errors still wait for the
      // worker's exit before close() completes and the owner frees the handle.
      _fail(StateError('Property reader failed: $message'));
    }
  }

  void _fail(Object error) {
    _closing = true;
    for (final result in _pending.values) {
      result.completeError(error);
    }
    _pending.clear();
    _outbox.clear();
  }

  void _finish() {
    if (_stopped) return;
    _stopped = true;
    _messages?.close();
    _commands = null;
    _closed.complete();
  }

  /// Rejects new reads and drains every accepted read before the worker exits.
  Future<void> close() {
    if (!_closing) {
      _closing = true;
      if (_started) {
        _send(['close']);
      } else {
        _finish();
      }
    }
    return _closed.future;
  }
}

void _nativePropertyWorker((SendPort, String, int) request) {
  final (reply, libraryPath, handleAddress) = request;
  final commands = ReceivePort();
  try {
    final api = mpv.MPV(DynamicLibrary.open(libraryPath));
    final handle = Pointer<mpv.mpv_handle>.fromAddress(handleAddress);
    commands.listen((dynamic command) {
      final values = command as List;
      if (values.first == 'close') {
        commands.close();
        Isolate.exit();
      }
      final id = values[1] as int;
      try {
        final result = <String, String>{};
        for (final name in values[2] as List<String>) {
          final nativeName = name.toNativeUtf8();
          Pointer<Int8> value = nullptr;
          try {
            value = api.mpv_get_property_string(handle, nativeName.cast());
            result[name] = value == nullptr
                ? ''
                : value.cast<Utf8>().toDartString();
          } finally {
            if (value != nullptr) api.mpv_free(value.cast());
            calloc.free(nativeName);
          }
        }
        reply.send(['result', id, result]);
      } catch (error) {
        reply.send(['error', id, '$error']);
      }
    });
    reply.send(commands.sendPort);
  } catch (error) {
    reply.send(['fatal', '$error']);
    commands.close();
    Isolate.exit();
  }
}
