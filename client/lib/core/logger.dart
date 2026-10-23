import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'network.dart';

class LogEntry {
  final DateTime time;
  final String level, scope, message;
  const LogEntry(this.time, this.level, this.scope, this.message);
  Map<String, dynamic> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'level': level,
    'scope': scope,
    'message': message,
  };
  String get text =>
      '${time.toLocal().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} [$level] $scope · $message';
}

/// Bounded device-local diagnostics. Never stores response bodies or credentials.
class AppLog extends ChangeNotifier {
  static final instance = AppLog();
  final int maxEntries;
  final List<LogEntry> _entries = [];
  final Set<String> _secrets = {};
  File? _file;
  Timer? _flushTimer;
  Future<void> _writes = Future.value();
  AppLog({this.maxEntries = 400});
  List<LogEntry> get entries => List.unmodifiable(_entries);
  void rememberSecret(String? value) {
    if (value != null && value.isNotEmpty) _secrets.add(value);
  }

  String sanitize(String input) {
    var text = input;
    text = text.replaceAll(
      RegExp(r'''(?:https?|smb|file)://[^\s<>"']+''', caseSensitive: false),
      '[地址已隐藏]',
    );
    text = text.replaceAll(
      RegExp(r'\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=._-]+', caseSensitive: false),
      '[凭证已隐藏]',
    );
    text = text.replaceAll(
      RegExp(
        r'''\b(?:token|password|passwd|authorization|secret|api[_-]?key)\s*[:=]\s*[^\s,;}]+''',
        caseSensitive: false,
      ),
      '[凭证已隐藏]',
    );
    for (final secret
        in _secrets.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      text = text.replaceAll(secret, '[已隐藏]');
      text = text.replaceAll(Uri.encodeComponent(secret), '[已隐藏]');
    }
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
    return text.length > 1200 ? '${text.substring(0, 1200)}…' : text;
  }

  Future<void> initialize(Directory directory) async {
    await directory.create(recursive: true);
    _file = File('${directory.path}/diagnostics.json');
    try {
      if (await _file!.exists()) {
        if (await _file!.length() <= 1024 * 1024) {
          final rows = jsonDecode(await _file!.readAsString());
          if (rows is List) {
            for (final row in rows.skip(
              (rows.length - maxEntries).clamp(0, rows.length),
            )) {
              if (row is! Map) continue;
              final time = DateTime.tryParse('${row['time']}');
              if (time == null) continue;
              _entries.add(
                LogEntry(
                  time,
                  sanitize('${row['level']}'),
                  sanitize('${row['scope']}'),
                  sanitize('${row['message']}'),
                ),
              );
            }
          }
        }
      }
    } catch (_) {
      /* A damaged log must not prevent launching the player. */
    }
    _trim();
  }

  void info(String scope, String message) => _add('信息', scope, message);
  void warning(String scope, String message) => _add('警告', scope, message);
  void error(String scope, String message) => _add('错误', scope, message);
  void _add(String level, String scope, String message) {
    _entries.add(
      LogEntry(DateTime.now(), level, sanitize(scope), sanitize(message)),
    );
    _trim();
    notifyListeners();
    if (_file != null) {
      _flushTimer ??= Timer(const Duration(milliseconds: 300), () {
        _flushTimer = null;
        unawaited(flush());
      });
    }
  }

  void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _file;
    if (file == null) return Future.value();
    final text = jsonEncode(_entries.map((e) => e.toJson()).toList());
    _writes = _writes
        .then((_) async {
          await file.writeAsString(text, flush: true);
        })
        .catchError((Object _) {});
    return _writes;
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await flush();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}

/// Describe actionable transport errors without echoing authenticated URLs.
AppFailure safeFailure(Object error, {String action = ''}) {
  final String message;
  if (error is SmbFailure) return AppFailure(error.message);
  if (error is AppFailure) {
    return AppFailure(AppLog.instance.sanitize(error.message), error.status);
  } else if (error is TimeoutException) {
    message = '连接超时，请检查服务器是否在线、端口和防火墙。';
  } else if (error is HandshakeException || error is TlsException) {
    message = 'TLS 握手失败，请检查 HTTPS 设置、证书有效期及证书是否受信任。';
  } else if (error is SocketException) {
    final code = error.osError?.errorCode;
    message = switch (code) {
      111 || 61 || 10061 => '连接被拒绝，请检查服务是否启动以及端口是否正确。',
      101 || 113 || 51 || 65 || 10051 || 10065 => '无法到达服务器，请检查是否在同一网络或已连接 VPN。',
      1 || 13 || 10013 => '网络访问被拒绝，请检查系统局域网权限或防火墙。',
      _ =>
        error.message.toLowerCase().contains('host lookup') ||
                error.message.toLowerCase().contains('name or service')
            ? '无法解析服务器地址，请检查主机名、DNS 或改用 IP 地址。'
            : '网络连接失败，请检查服务器地址、端口和网络状态。',
    };
  } else if (error is FileSystemException) {
    message = error.osError?.errorCode == 2
        ? '文件或目录已不存在，请重新关联位置。'
        : '无法访问文件，请检查文件权限及磁盘空间。';
  } else if (error is FormatException) {
    message = '地址或服务器响应格式无效，请检查协议和路径。';
  } else {
    message = '操作未完成（${error.runtimeType}），请检查配置后重试。';
  }
  return AppFailure(action.isEmpty ? message : '$action：$message');
}
