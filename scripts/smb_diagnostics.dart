// Start scripts/smb_fixture.sh in another terminal.
// LD_LIBRARY_PATH=/tmp/aiplayer-smb-build dart --packages=client/.dart_tool/package_config.json scripts/smb_diagnostics.dart
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer_smb/aiplayer_smb.dart';

Future<void> main() async {
  final results = <String, dynamic>{};
  final user = Platform.environment['USER'] ?? 'root';
  final source = await SmbConnection.connect(
    host: '127.0.0.1:1445',
    share: 'video',
    user: user,
    password: 'aiplayer-fixture-password',
  );
  try {
    final entries = await source.list('');
    if (!entries.any((entry) => entry['name'] == '中文视频.mkv'))
      throw StateError('Chinese file missing');
    final large = await source.stat('大文件.mkv');
    if (large['size'] != 5 * 1024 * 1024 * 1024 + 64)
      throw StateError('Large stat incorrect');
    final data = await source.read('大文件.mkv', 5 * 1024 * 1024 * 1024 + 7, 9);
    if (data.join(',') != '7,8,9,10,11,12,13,14,15')
      throw StateError('Random read incorrect');
    results['authenticatedListAndRandomRead'] = true;
    if (source.dialect != 0x0311)
      throw StateError('SMB 3.1.1 was not negotiated');
    results['dialect'] = smbDialectLabel(source.dialect);
  } finally {
    await source.close();
  }
  for (final security in ['auto', 'sign', 'encrypt']) {
    final ipc = await SmbConnection.connect(
      host: '127.0.0.1:1445',
      share: 'IPC\$',
      user: user,
      password: 'aiplayer-fixture-password',
      security: security,
    );
    try {
      final shares = await ipc.shares();
      if (!shares.any((share) => share['name'] == 'video'))
        throw StateError('Share enumeration failed');
      if (shares.any((share) => share['name'] == 'IPC\$'))
        throw StateError('Non-disk share exposed');
      if (ipc.dialect != 0x0311) throw StateError('Incorrect dialect');
      results['enumeration_$security'] = {
        'dialect': smbDialectLabel(ipc.dialect),
        'shares': shares.map((share) => share['name']).toList(),
      };
    } finally {
      await ipc.close();
    }
  }
  for (final scenario in ['invalidPassword', 'missingShare']) {
    try {
      final unexpected = await SmbConnection.connect(
        host: '127.0.0.1:1445',
        share: scenario == 'missingShare' ? 'absent' : 'video',
        user: user,
        password: scenario == 'invalidPassword'
            ? 'incorrect-private-password'
            : 'aiplayer-fixture-password',
      );
      await unexpected.close();
      throw StateError('Expected SMB failure');
    } on SmbFailure catch (error) {
      final expected = scenario == 'invalidPassword' ? '登录失败' : '共享不存在';
      if (!error.message.contains(expected))
        throw StateError('Incorrect diagnosis: ${error.message}');
      if (error.message.contains('password') ||
          error.message.contains('127.0.0.1'))
        throw StateError('Sensitive details');
      results[scenario] = {'code': error.code, 'message': error.message};
    }
  }
  await File('artifacts/source-smb-diagnostics.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  print(jsonEncode(results));
}
