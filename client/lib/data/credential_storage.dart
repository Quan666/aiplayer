import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/network.dart';

FlutterSecureStorage createCredentialStorage(
  Directory documents, {
  bool? macosAdhoc,
}) =>
    (macosAdhoc ??
        (Platform.isMacOS &&
            const bool.fromEnvironment('AIPLAYER_MACOS_ADHOC')))
    ? LocalCredentialStorage(documents)
    : const FlutterSecureStorage();

/// The personal macOS build deliberately avoids Keychain entirely. These
/// credentials are NOT encrypted at rest; Unix permissions limit access to the
/// current user. SQLite serializes writes from the library and player engines
/// without per-isolate caches or JSON read/modify/write races.
class LocalCredentialStorage extends FlutterSecureStorage {
  final Directory directory;
  Future<Database>? _opening;
  bool _closed = false;

  LocalCredentialStorage(Directory documents)
    : directory = Directory(p.join(documents.path, 'credentials'));

  String get path => p.join(directory.path, 'local-v1.sqlite3');

  Future<void> _restrict(String path, String mode) async {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw const AppFailure('无法设置本机凭据文件的访问权限。');
    }
  }

  Future<Database> _open() async {
    Database? db;
    try {
      await directory.create(recursive: true);
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const AppFailure('本机凭据目录无效。');
      }
      // Restrict the empty directory before creating or writing any secret.
      await _restrict(directory.path, '700');
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const AppFailure('本机凭据文件无效。');
      }
      if (type == FileSystemEntityType.file) await _restrict(path, '600');
      // Let SQLite create the file. Closing an unrelated Dart file handle to
      // this path can release SQLite's POSIX locks in another Flutter engine.
      final opened = sqlite3.open(path);
      db = opened;
      if (type == FileSystemEntityType.notFound) await _restrict(path, '600');
      opened.execute('PRAGMA busy_timeout=250');
      opened.execute('PRAGMA secure_delete=ON');
      await _retryBusy(
        () => opened.execute(
          'CREATE TABLE IF NOT EXISTS credentials '
          '(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
        ),
      );
      return opened;
    } catch (_) {
      db?.dispose();
      // A failed/corrupt store must not look like empty credentials to sync.
      throw const AppFailure('无法打开本机凭据文件，请检查应用数据目录权限和可用空间。');
    }
  }

  Future<T> _use<T>(T Function(Database db) operation) async {
    if (_closed) throw const AppFailure('本机凭据存储已关闭。');
    final db = await (_opening ??= _open());
    if (_closed) throw const AppFailure('本机凭据存储已关闭。');
    try {
      return await _retryBusy(() => operation(db));
    } on SqliteException catch (error) {
      throw AppFailure(
        '无法访问本机凭据文件（SQLite ${error.extendedResultCode}），请检查应用数据目录权限和可用空间。',
        error.extendedResultCode,
      );
    } catch (_) {
      throw const AppFailure('无法访问本机凭据文件，请检查应用数据目录权限和可用空间。');
    }
  }

  Future<T> _retryBusy<T>(T Function() operation) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      if (_closed) throw const AppFailure('本机凭据存储已关闭。');
      try {
        return operation();
      } on SqliteException catch (error) {
        // SQLite may return BUSY without calling its native busy handler.
        // Yield so another engine can finish, then retry the whole atomic
        // operation. Corruption, I/O errors and denied access are not retried.
        if (error.resultCode != 5 || elapsed.elapsedMilliseconds >= 5000) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final opening = _opening;
    if (opening == null) return;
    try {
      (await opening).dispose();
    } catch (_) {
      // Initialization already reports its failure to the requesting operation.
    }
  }

  /// Keep generated sync keys and recovered credentials consistent when two
  /// Flutter engines initialize the same entry at the same time.
  Future<String> readOrCreate({required String key, required String value}) =>
      _use((db) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(
            'INSERT INTO credentials(key,value) VALUES(?,?) '
            'ON CONFLICT(key) DO NOTHING',
            [key, value],
          );
          final stored =
              db.select('SELECT value FROM credentials WHERE key=?', [
                    key,
                  ]).first['value']
                  as String;
          db.execute('COMMIT');
          return stored;
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      });

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use((db) {
    final rows = db.select('SELECT value FROM credentials WHERE key=?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  });

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use((db) {
    if (value == null) {
      db.execute('DELETE FROM credentials WHERE key=?', [key]);
    } else {
      db.execute(
        'INSERT INTO credentials(key,value) VALUES(?,?) '
        'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        [key, value],
      );
    }
  });

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use((db) => db.execute('DELETE FROM credentials WHERE key=?', [key]));

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use(
    (db) =>
        db.select('SELECT 1 FROM credentials WHERE key=?', [key]).isNotEmpty,
  );

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use(
    (db) => {
      for (final row in db.select('SELECT key,value FROM credentials'))
        row['key'] as String: row['value'] as String,
    },
  );

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _use((db) => db.execute('DELETE FROM credentials'));
}
