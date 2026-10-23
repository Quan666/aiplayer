import 'package:aiplayer_smb/aiplayer_smb.dart';

import '../core/network.dart';
import 'source.dart';

/// Split legacy addresses once so editing never adds a second port or scheme.
Map<String, dynamic> sourceFormValues(Map<String, dynamic>? source) {
  final value = <String, dynamic>{...?source};
  final kind = value['kind'] as String? ?? 'smb';
  value['kind'] = kind;
  if (kind == 'smb') {
    final raw = value['host'] as String? ?? '';
    final address = Uri.tryParse(raw.contains('://') ? raw : 'smb://$raw');
    if (address != null && address.host.isNotEmpty) {
      value['host'] = address.host;
      value['port'] ??= address.hasPort ? address.port : 445;
    }
    value['port'] ??= 445;
  } else if (kind == 'webdav') {
    final address = Uri.tryParse(value['url'] as String? ?? '');
    if (address != null && address.host.isNotEmpty) {
      value['host'] = address.host;
      value['port'] = address.port;
      value['encrypted'] = address.scheme == 'https';
      value['path'] = Uri.decodeComponent(address.path);
    }
    value['encrypted'] ??= true;
    value['port'] ??= value['encrypted'] == true ? 443 : 80;
    value['path'] ??= '/';
  }
  return value;
}

Map<String, dynamic> buildSourceConfiguration({
  required String kind,
  required Map<String, String> fields,
  bool encrypted = true,
  String smbSecurity = 'auto',
}) {
  String text(String key) => fields[key]?.trim() ?? '';
  final user = text('user');
  final result = <String, dynamic>{
    'kind': kind,
    'label': text('label'),
    'user': user,
    'password': fields['password'] ?? '',
  };
  if (kind == 'http') {
    final address = Uri.tryParse(text('url'));
    if (address == null ||
        !['http', 'https'].contains(address.scheme) ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty) {
      throw const AppFailure('请输入不含用户名和密码的 HTTP(S) 视频地址。');
    }
    result['url'] = text('url');
    result['label'] = directLinkDisplayName(
      text('url'),
      preferred: text('label'),
    );
    return result;
  }
  if (!['smb', 'webdav'].contains(kind)) {
    throw const AppFailure('不支持此来源类型。');
  }
  final host = text('host').replaceAll(RegExp(r'^\[|\]$'), '');
  if (host.isEmpty ||
      host.contains(RegExp(r'[/\\@?#\s]')) ||
      host.contains('://')) {
    throw const AppFailure('服务器地址只填写主机名或 IP，端口和目录请单独填写。');
  }
  final address = Uri.tryParse(
    '${kind == 'smb' ? 'smb' : 'https'}://'
    '${host.contains(':') ? '[$host]' : host}',
  );
  if (address == null || address.host.isEmpty) {
    throw const AppFailure('服务器地址无效，请检查主机名或 IP。');
  }
  final port = int.tryParse(text('port'));
  if (port == null || port < 1 || port > 65535) {
    throw const AppFailure('端口应为 1–65535 之间的整数。');
  }
  result.addAll({'host': host, 'port': port});
  if (kind == 'smb') {
    final share = text('share');
    if (share.contains(RegExp(r'[/\\]'))) {
      throw const AppFailure('共享名称不要包含服务器地址或子目录。');
    }
    if (!['auto', 'sign', 'encrypt'].contains(smbSecurity)) {
      throw const AppFailure('SMB 安全选项无效。');
    }
    result.addAll({
      'share': share,
      'domain': text('domain'),
      'smbSecurity': smbSecurity,
    });
    if (text('label').isEmpty) {
      result['label'] = share.isEmpty ? host : '$host · $share';
    }
  } else {
    var path = text('path');
    if (path.contains('?') || path.contains('#')) {
      throw const AppFailure('目录路径不能包含查询参数或片段。');
    }
    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    result.addAll({
      'encrypted': encrypted,
      'path': path,
      'url': Uri(
        scheme: encrypted ? 'https' : 'http',
        host: host,
        port: port,
        path: path,
      ).toString(),
    });
    if (text('label').isEmpty) result['label'] = host;
  }
  return result;
}

Future<SourceAdapter> connectSource(
  Map<String, dynamic> source, {
  String password = '',
}) async {
  final value = sourceFormValues(source);
  switch (value['kind']) {
    case 'smb':
      final host = value['host'] as String? ?? '';
      final port = int.tryParse('${value['port']}') ?? 445;
      final endpoint = Uri(host: host, port: port).authority;
      Future<SmbConnection> connect(String share) => SmbConnection.connect(
        host: endpoint,
        share: share,
        user: value['user'] as String? ?? '',
        password: password,
        domain: value['domain'] as String? ?? '',
        security: value['smbSecurity'] as String? ?? 'auto',
      );
      final share = value['share'] as String? ?? '';
      if (share.isEmpty) {
        final server = SmbServerSource(connect);
        await server.initialize();
        return server;
      }
      return SmbSource(await connect(share), reconnect: () => connect(share));
    case 'webdav':
    case 'http':
      return HttpSource(
        value['url'] as String? ?? '',
        webdav: value['kind'] == 'webdav',
        user: value['user'] as String? ?? '',
        password: password,
        displayName: value['label'] as String? ?? '',
      );
    default:
      throw const AppFailure('不支持此来源类型。');
  }
}

/// Parse complete addresses pasted into the host field without storing URL
/// credentials. Bare host names return null, leaving the separate fields intact.
Map<String, dynamic>? splitPastedSourceAddress(
  String raw, {
  required String kind,
}) {
  var value = raw.trim();
  if (kind == 'http' || value.isEmpty) return null;
  if (kind == 'smb' && value.startsWith(r'\\')) {
    value = 'smb://${value.substring(2).replaceAll(r'\', '/')}';
  }
  final complete = value.contains('://');
  if (!complete && !value.contains('/') && !RegExp(r':\d+$').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(
    complete ? value : '${kind == 'smb' ? 'smb' : 'https'}://$value',
  );
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const AppFailure('地址无效。用户名和密码请在下方单独填写。');
  }
  if (kind == 'smb'
      ? uri.scheme != 'smb'
      : !['http', 'https'].contains(uri.scheme)) {
    throw AppFailure(
      kind == 'smb'
          ? 'SMB 地址应以 smb:// 开头。'
          : 'WebDAV 地址应以 http:// 或 https:// 开头。',
    );
  }
  if (uri.hasQuery || uri.hasFragment) {
    throw const AppFailure('目录地址不应包含查询参数，请填写服务器目录而非分享链接。');
  }
  final path = Uri.decodeComponent(uri.path);
  return {
    'host': uri.host,
    'port': uri.hasPort
        ? uri.port
        : kind == 'smb'
        ? 445
        : uri.scheme == 'https'
        ? 443
        : 80,
    if (kind == 'webdav') ...{
      'encrypted': uri.scheme == 'https',
      'path': path.isEmpty ? '/' : path,
    },
    if (kind == 'smb' && path.replaceAll('/', '').isNotEmpty)
      'share': uri.pathSegments.firstWhere((part) => part.isNotEmpty),
  };
}
