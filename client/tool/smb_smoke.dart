import 'dart:io';
import 'package:aiplayer_smb/aiplayer_smb.dart';

/// Run against the disposable share created by scripts/smb_fixture.sh.
Future<void> main(List<String> args) async {
  final connection = await SmbConnection.connect(
    host: args.isEmpty ? '127.0.0.1:1445' : args[0],
    share: 'video',
    user: Platform.environment['SMB_TEST_USER'] ?? 'root',
    password:
        Platform.environment['SMB_TEST_PASSWORD'] ??
        'aiplayer-fixture-password',
  );
  try {
    final entries = await connection.list('');
    if (!entries.any((e) => e['name'] == '中文视频.mkv')) {
      throw StateError('Unicode directory listing failed');
    }
    final stat = await connection.stat('中文视频.mkv');
    if (stat['size'] != 2097152) throw StateError('Wrong size');
    for (final offset in [0, 123, 1048570, 2097140]) {
      final count = offset == 2097140 ? 12 : 32,
          bytes = await connection.read('中文视频.mkv', offset, count);
      if (bytes.length != count) throw StateError('Short read');
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != (offset + i) % 256) {
          throw StateError('Wrong random read at $offset');
        }
      }
    }
    final large = await connection.stat('大文件.mkv');
    final largeOffset = 5 * 1024 * 1024 * 1024;
    if (large['size'] != largeOffset + 64) {
      throw StateError('64-bit stat failed');
    }
    final tail = await connection.read('大文件.mkv', largeOffset, 64);
    if (tail.length != 64) throw StateError('64-bit read failed');
    for (var i = 0; i < 64; i++) {
      if (tail[i] != i) throw StateError('Wrong byte beyond 4 GiB');
    }
    stdout.writeln(
      'SMB OK: authenticated Unicode listing, stat, random reads, 5 GiB offsets, end-of-file',
    );
  } finally {
    await connection.close();
  }
}
