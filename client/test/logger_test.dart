import 'dart:io';
import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/core/network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostics redact secrets, authenticated URLs and bound retention',
    () {
      final log = AppLog(maxEntries: 3)..rememberSecret('private value');
      log.info(
        '测试',
        'https://user:password@server/private-token/api/v2?token=secret',
      );
      log.error(
        '连接',
        'token=unsafe password=unsafe private value private%20value',
      );
      log.warning('认证', 'Authorization: Bearer ABCDEF Basic YWJj');
      final text = log.entries.map((e) => e.text).join('\n');
      for (final secret in [
        'private',
        'unsafe',
        'ABCDEF',
        'YWJj',
        'user:password',
        'server',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      log.info('连接', '测试连接成功');
      expect(log.entries.length, 3);
      expect(log.entries.last.message, '测试连接成功');
      log.dispose();
    },
  );
  test('logs persist locally and clear survives reopening', () async {
    final root = Directory.systemTemp.createTempSync('aiplayer-logs-');
    final first = AppLog(maxEntries: 2);
    final second = AppLog(maxEntries: 2);
    final third = AppLog();
    try {
      await first.initialize(root);
      first.info('连接', '成功');
      first.warning('连接', '服务不可达');
      await first.flush();
      await second.initialize(root);
      expect(second.entries.map((e) => e.message), ['成功', '服务不可达']);
      await second.clear();
      await third.initialize(root);
      expect(third.entries, isEmpty);
    } finally {
      first.dispose();
      second.dispose();
      third.dispose();
      root.deleteSync(recursive: true);
    }
  });
  test('connection errors retain useful category without echoing URLs', () {
    expect(
      safeFailure(
        const SocketException(
          'Connection refused',
          osError: OSError('refused', 111),
        ),
      ).message,
      contains('被拒绝'),
    );
    expect(
      safeFailure(
        const SocketException('Failed host lookup private.host'),
      ).message,
      contains('解析'),
    );
    expect(
      safeFailure(const HandshakeException('https://user:pass@secret')).message,
      contains('TLS'),
    );
    final failure = safeFailure(
      const AppFailure('失败 https://token.example/secret/api', 401),
    );
    expect(failure.status, 401);
    expect(failure.message, isNot(contains('secret')));
  });
}
