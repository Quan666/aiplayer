import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'src/worker_channel.dart';
export 'src/failure.dart';

final class _Entry extends Struct {
  @Int64()
  external int size;
  @Int64()
  external int modified;
  @Int32()
  external int directory;
  @Array(1024)
  external Array<Uint8> name;
  @Uint32()
  external int attributes;
}

final class _Share extends Struct {
  @Uint32()
  external int type;
  @Array(1024)
  external Array<Uint8> name;
}

class SmbConnection {
  final SmbWorkerChannel _channel;
  final int dialect;
  SmbConnection._(this._channel) : dialect = _channel.dialect;
  static Future<SmbConnection> connect({
    required String host,
    required String share,
    String user = '',
    String password = '',
    String domain = '',
    String security = 'auto',
  }) async => SmbConnection._(
    await SmbWorkerChannel.start(_worker, [
      host,
      share,
      user,
      password,
      domain,
      security,
    ]),
  );

  Future<List<Map<String, dynamic>>> shares() async =>
      (await _channel.call('shares', []) as List).cast<Map<String, dynamic>>();
  Future<List<Map<String, dynamic>>> list(String path) async =>
      (await _channel.call('list', [path]) as List)
          .cast<Map<String, dynamic>>();
  Future<Map<String, dynamic>> stat(String path) async =>
      Map<String, dynamic>.from(await _channel.call('stat', [path]));
  Future<Uint8List> read(String path, int offset, int length) async =>
      (await _channel.call('read', [path, offset, length])
              as TransferableTypedData)
          .materialize()
          .asUint8List();
  Future<void> close() => _channel.close();
}

void _worker(List<dynamic> startup) {
  final ready = startup[0] as SendPort;
  try {
    final lib = Platform.isIOS || Platform.isMacOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(
            Platform.isWindows ? 'aiplayer_smb.dll' : 'libaiplayer_smb.so',
          );
    final entrySize = lib.lookupFunction<Uint32 Function(), int Function()>(
      'ap_entry_size',
    );
    if (entrySize() != sizeOf<_Entry>()) {
      throw StateError('SMB native layout mismatch');
    }
    final connect = lib
        .lookupFunction<
          Pointer<Void> Function(
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Int32,
            Pointer<Int32>,
          ),
          Pointer<Void> Function(
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            int,
            Pointer<Int32>,
          )
        >('ap_connect_options');
    final dialect = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('ap_dialect');
    final enumerate = lib
        .lookupFunction<
          Pointer<_Share> Function(
            Pointer<Void>,
            Pointer<Int32>,
            Pointer<Int32>,
          ),
          Pointer<_Share> Function(
            Pointer<Void>,
            Pointer<Int32>,
            Pointer<Int32>,
          )
        >('ap_shares');
    final freeShares = lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('ap_free_shares');
    final lastError = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('ap_last_error');
    final disconnect = lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('ap_disconnect');
    final stat = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<_Entry>),
          int Function(Pointer<Void>, Pointer<Utf8>, Pointer<_Entry>)
        >('ap_stat');
    final openDir = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
        >('ap_opendir');
    final next = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<_Entry>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<_Entry>)
        >('ap_next');
    final closeDir = lib
        .lookupFunction<
          Void Function(Pointer<Void>, Pointer<Void>),
          void Function(Pointer<Void>, Pointer<Void>)
        >('ap_closedir');
    final openFile = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
        >('ap_open');
    final read = lib
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Uint8>,
            Uint32,
            Uint64,
          ),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, int, int)
        >('ap_read');
    final closeFile = lib
        .lookupFunction<
          Void Function(Pointer<Void>, Pointer<Void>),
          void Function(Pointer<Void>, Pointer<Void>)
        >('ap_close');
    final config = startup
        .skip(1)
        .take(5)
        .map((s) => (s as String).toNativeUtf8())
        .toList();
    final error = calloc<Int32>();
    final ctx = connect(
      config[0],
      config[1],
      config[2],
      config[3],
      config[4],
      startup[6] == 'encrypt'
          ? 2
          : startup[6] == 'sign'
          ? 1
          : 0,
      error,
    );
    final connectionError = error.value;
    calloc.free(error);
    for (final p in config) {
      calloc.free(p);
    }
    if (ctx == nullptr) {
      ready.send(connectionError);
      return;
    }
    final port = ReceivePort();
    final files = <String, Pointer<Void>>{};
    ready.send([port.sendPort, dialect(ctx)]);
    port.listen((dynamic msg) {
      final method = msg[0], args = msg[1] as List, reply = msg[2] as SendPort;
      if (method == 'close') {
        for (final f in files.values) {
          closeFile(ctx, f);
        }
        disconnect(ctx);
        reply.send(true);
        port.close();
        return;
      }
      if (method == 'shares') {
        final count = calloc<Int32>(), error = calloc<Int32>();
        Pointer<_Share> shares = nullptr;
        try {
          shares = enumerate(ctx, count, error);
          if (shares == nullptr) {
            reply.send({'error': true, 'code': error.value});
          } else {
            reply.send([
              for (var i = 0; i < count.value; i++)
                {
                  'name': utf8.decode(
                    List.generate(
                      1024,
                      (j) => (shares + i).ref.name[j],
                    ).takeWhile((b) => b != 0).toList(),
                  ),
                  'hidden': ((shares + i).ref.type & 0x80000000) != 0,
                },
            ]);
          }
        } finally {
          if (shares != nullptr) freeShares(shares.cast());
          calloc.free(count);
          calloc.free(error);
        }
        return;
      }
      final path = (args[0] as String).toNativeUtf8();
      final entry = calloc<_Entry>();
      Map<String, dynamic> value() => {
        'size': entry.ref.size,
        'modified': entry.ref.modified,
        'directory': entry.ref.directory == 1,
        'hidden': (entry.ref.attributes & 0x6) != 0,
      };
      try {
        if (method == 'list') {
          final dir = openDir(ctx, path);
          if (dir == nullptr) throw StateError('open');
          final entries = <Map<String, dynamic>>[];
          try {
            while (next(ctx, dir, entry) > 0) {
              final name = utf8.decode(
                List.generate(
                  1024,
                  (i) => entry.ref.name[i],
                ).takeWhile((b) => b != 0).toList(),
              );
              if (name != '.' && name != '..') {
                entries.add({...value(), 'name': name});
              }
            }
          } finally {
            closeDir(ctx, dir);
          }
          reply.send(entries);
        } else if (method == 'stat') {
          if (stat(ctx, path, entry) < 0) throw StateError('stat');
          reply.send(value());
        } else if (method == 'read') {
          final key = args[0] as String;
          if (!files.containsKey(key)) {
            if (files.length >= 8) {
              final old = files.keys.first;
              closeFile(ctx, files.remove(old)!);
            }
            final f = openFile(ctx, path);
            if (f == nullptr) throw StateError('open');
            files[key] = f;
          }
          final count = (args[2] as int).clamp(1, 1024 * 1024),
              buffer = calloc<Uint8>(count);
          try {
            final n = read(ctx, files[key]!, buffer, count, args[1] as int);
            if (n < 0) {
              closeFile(ctx, files.remove(key)!);
              throw StateError('read');
            }
            reply.send(TransferableTypedData.fromList([buffer.asTypedList(n)]));
          } finally {
            calloc.free(buffer);
          }
        } else {
          throw StateError('unknown');
        }
      } catch (_) {
        reply.send({'error': true, 'code': lastError(ctx)});
      } finally {
        calloc.free(entry);
        calloc.free(path);
      }
    });
  } catch (_) {
    ready.send(-9001);
  }
}
