import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../sources/source.dart';
import 'network.dart';

class ExternalVideoRequest {
  final String location, name;
  final bool remote, temporary;
  const ExternalVideoRequest(
    this.location,
    this.name,
    this.remote, {
    this.temporary = false,
  });
  static ExternalVideoRequest parse(Map<dynamic, dynamic> value) {
    if (value['error'] is String) throw AppFailure(value['error']);
    final raw = (value['path'] ?? value['uri'])?.toString() ?? '';
    if (raw.isEmpty || raw.contains('\u0000')) {
      throw const AppFailure('没有收到可播放的视频地址。');
    }
    final uri = Uri.tryParse(raw);
    if (uri != null && ['http', 'https'].contains(uri.scheme)) {
      if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const AppFailure('视频链接无效，请使用不含用户名和密码的 HTTP(S) 链接。');
      }
      return ExternalVideoRequest(
        raw,
        directLinkDisplayName(raw, preferred: '${value['name'] ?? ''}'),
        true,
      );
    }
    final path = uri?.scheme == 'file' ? uri!.toFilePath() : raw;
    if (uri != null &&
        uri.hasScheme &&
        uri.scheme != 'file' &&
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
      throw const AppFailure('该应用没有提供可读取的视频文件，请使用“打开方式”重新选择映库。');
    }
    if (!p.isAbsolute(path)) throw const AppFailure('收到的视频路径无效。');
    final name = '${value['name'] ?? p.basename(path)}';
    if (!isVideo(name) && !isVideo(path)) {
      throw const AppFailure('此文件不是受支持的视频格式。');
    }
    return ExternalVideoRequest(
      path,
      name,
      false,
      temporary: value['temporary'] == true,
    );
  }
}

class ExternalVideoInbox {
  static const channel = MethodChannel('app.aiplayer/external_video');
  final void Function(Map<dynamic, dynamic>) onOpen;
  bool _closed = false;
  ExternalVideoInbox(this.onOpen);
  Future<void> start(List<String> arguments) async {
    channel.setMethodCallHandler((call) async {
      if (!_closed && call.method == 'onOpen' && call.arguments is Map) {
        onOpen(call.arguments as Map);
      }
    });
    try {
      final values = await channel.invokeListMethod<dynamic>('getPending');
      if (!_closed) {
        for (final value in values ?? []) {
          if (value is Map) onOpen(value);
        }
      }
    } on MissingPluginException {
      /* Desktop launch arguments are supplied by the runner. */
    } on PlatformException catch (_) {
      if (!_closed) onOpen({'error': '读取外部视频失败，请从原应用重新打开。'});
    }
    if (!_closed &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      for (final argument in arguments.where((v) => !v.startsWith('--'))) {
        onOpen({'path': argument});
      }
    }
  }

  Future<void> release(String path) async {
    try {
      await channel.invokeMethod<void>('releaseIncoming', {'path': path});
    } on MissingPluginException {
      /* No temporary copy on this platform. */
    } on PlatformException {
      /* Native startup cleanup retries. */
    }
  }

  void dispose() {
    _closed = true;
    channel.setMethodCallHandler(null);
  }
}
