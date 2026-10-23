import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../core/network.dart';
import '../core/logger.dart';

class SourceEntry {
  final String name, path;
  final int size;
  final bool directory, seekable, hidden;
  final int modified;
  const SourceEntry({
    required this.name,
    required this.path,
    this.size = 0,
    this.directory = false,
    this.modified = 0,
    this.seekable = true,
    this.hidden = false,
  });
}

/// A direct link's query, fragment, user info and parent path never become its
/// display name. Opaque download endpoints fall back to their host name.
String directLinkDisplayName(String address, {String preferred = ''}) {
  final label = preferred.trim();
  if (label.isNotEmpty) return label;
  final uri = Uri.tryParse(address);
  if (uri == null || uri.host.isEmpty) return '视频直链';
  try {
    final segments = uri.pathSegments.where((p) => p.isNotEmpty);
    if (segments.isNotEmpty) {
      final leaf = segments.last
          .split(RegExp(r'[/\\]'))
          .last
          .split(RegExp(r'[?#]'))
          .first
          .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
          .trim();
      if (leaf.isNotEmpty && leaf.length <= 256 && isVideo(leaf)) return leaf;
    }
  } on FormatException {
    // A URL can parse while its escaped path is not valid UTF-8.
  }
  return uri.host;
}

AppFailure sourceHttpFailure(int status, {bool webdav = false}) {
  final detail = switch (status) {
    401 => '认证失败，请检查用户名和密码。',
    403 => '访问被拒绝，请检查账号和目录权限。',
    404 => '文件或目录不存在，请检查地址和目录路径。',
    405 || 501 when webdav => '服务器未启用 WebDAV，或目录不支持 PROPFIND。',
    408 || 504 => '服务器响应超时，请稍后重试。',
    429 => '服务器限制了请求频率，请稍后重试。',
    >= 300 && < 400 => '服务器要求重定向，请直接填写最终地址。',
    >= 500 => '服务器内部错误，请检查服务器状态。',
    _ => '来源请求失败，请检查服务配置。',
  };
  return AppFailure('HTTP $status · $detail', status);
}

abstract class SourceAdapter {
  Future<List<SourceEntry>> list(String path);
  Future<SourceEntry> stat(String path);
  Stream<List<int>> read(String path, int start, int end);
  Future<void> close() async {}
}

class LocalSource extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async {
    final result = <SourceEntry>[];
    await for (final file in Directory(path).list(followLinks: false)) {
      if (file is Link) continue;
      try {
        result.add(await stat(file.path));
      } on FileSystemException {
        continue;
      }
    }
    return result;
  }

  @override
  Future<SourceEntry> stat(String path) async {
    final s = await FileStat.stat(path);
    if (s.type == FileSystemEntityType.notFound) {
      throw const AppFailure('文件不可访问，请重新关联位置。');
    }
    return SourceEntry(
      name: p.basename(path),
      path: path,
      size: s.size,
      directory: s.type == FileSystemEntityType.directory,
      modified: s.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      File(path).openRead(start, end + 1);
}

class HttpSource extends SourceAdapter {
  final Uri base;
  final bool webdav;
  final String user, password, displayName;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
  HttpSource(
    String address, {
    this.webdav = false,
    this.user = '',
    this.password = '',
    this.displayName = '',
  }) : base = Uri.parse(address) {
    if (!['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw const AppFailure('请输入不含用户名和密码的 HTTP(S) 地址。');
    }
  }
  Uri url(String path) {
    if (path.isEmpty) return base;
    final root = webdav && !base.path.endsWith('/')
        ? base.replace(path: '${base.path}/')
        : base;
    return root.resolveUri(Uri(path: path));
  }

  Future<HttpClientResponse> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    try {
      final r = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 25));
      r.followRedirects = false;
      if (user.isNotEmpty) {
        r.headers.set(
          'Authorization',
          'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        );
      }
      headers.forEach(r.headers.set);
      if (body != null) r.write(body);
      return await r.close().timeout(const Duration(seconds: 25));
    } catch (error) {
      throw safeFailure(error, action: '连接来源失败');
    }
  }

  @override
  Future<List<SourceEntry>> list(String path) async {
    if (!webdav) throw const AppFailure('HTTP 直链不支持目录浏览。');
    final requested = url(path);
    // Browser entries retain WebDAV collection slashes, whereas an existing
    // video's dirname does not. Request the collection directly in both cases;
    // following redirects could send source credentials to another location.
    final uri = requested.path.endsWith('/')
        ? requested
        : requested.replace(path: '${requested.path}/');
    final response = await _request(
      'PROPFIND',
      uri,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:ishidden/></d:prop></d:propfind>',
    );
    if (response.statusCode != 207) {
      // An error body may be unbounded or stalled. The status is sufficient;
      // cancelling surfaces the failure without waiting for that body to end.
      await response.listen((_) {}).cancel();
      throw sourceHttpFailure(response.statusCode, webdav: true);
    }
    try {
      final text = await utf8.decoder
          .bind(response.timeout(const Duration(seconds: 25)))
          .join();
      return await _decodeWebDavListing(text, uri, base);
    } on FormatException {
      throw const AppFailure('服务器返回了无效的 WebDAV 目录数据，请确认目录路径。');
    } on XmlException {
      throw const AppFailure('服务器返回了无效的 WebDAV 目录数据，请确认目录路径。');
    }
  }

  @override
  Future<SourceEntry> stat(String path) async {
    final uri = url(path);
    var response = await _request('HEAD', uri);
    if (response.statusCode == 405 ||
        response.statusCode == 501 ||
        (response.statusCode == 200 &&
            (response.headers.value('accept-ranges') != 'bytes' ||
                response.contentLength < 0))) {
      await response.listen((_) {}).cancel();
      response = await _request('GET', uri, headers: {'Range': 'bytes=0-0'});
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.listen((_) {}).cancel();
      throw sourceHttpFailure(response.statusCode);
    }
    final range = response.headers.value('content-range');
    final size = range != null
        ? int.tryParse(range.split('/').last) ?? 0
        : response.contentLength;
    final seekable =
        response.statusCode == 206 ||
        response.headers.value('accept-ranges') == 'bytes';
    // Cancel GET fallback immediately; do not accidentally download the whole movie.
    final subscription = response.listen((_) {});
    await subscription.cancel();
    if (size < 0) throw const AppFailure('该来源未提供文件大小，无法建立可定位的视频读取。');
    return SourceEntry(
      name: webdav
          ? uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.host
          : directLinkDisplayName(uri.toString(), preferred: displayName),
      path: path,
      size: size,
      seekable: seekable,
    );
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    final response = await _request(
      'GET',
      url(path),
      headers: {'Range': 'bytes=$start-$end', 'Accept-Encoding': 'identity'},
    );
    if (response.statusCode != 206 &&
        !(response.statusCode == 200 && start == 0)) {
      final s = response.listen((_) {});
      await s.cancel();
      if (response.statusCode >= 300) {
        throw sourceHttpFailure(response.statusCode);
      }
      throw const AppFailure('来源不支持此位置的范围读取。');
    }
    if (response.statusCode == 206) {
      final range = response.headers.value('content-range') ?? '';
      if (!range.startsWith('bytes $start-')) {
        await response.listen((_) {}).cancel();
        throw const AppFailure('来源返回了错误的读取范围。');
      }
    }
    var remaining = end - start + 1;
    await for (final bytes in response.timeout(const Duration(seconds: 25))) {
      final n = remaining < bytes.length ? remaining : bytes.length;
      if (n > 0) {
        // HTTP chunks are immutable after delivery. Forward complete chunks
        // directly; copying every byte competes with the UI and video output.
        yield n == bytes.length
            ? bytes
            : bytes is Uint8List
            ? Uint8List.sublistView(bytes, 0, n)
            : bytes.sublist(0, n);
      }
      remaining -= n;
      if (remaining <= 0) break;
    }
    if (remaining > 0) throw const AppFailure('视频读取提前结束，请重试。');
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}

/// Server-level SMB source. The root enumerates disk shares over IPC$; each
/// visited share gets its own connection, so share names never become mandatory.
class SmbServerSource extends SourceAdapter {
  final Future<SmbConnection> Function(String share) connect;
  final Map<String, Future<SmbSource>> _shares = {};
  SmbConnection? _ipc;
  Future<void>? _initializing;
  bool _closed = false;
  SmbServerSource(this.connect);
  int get dialect => _ipc?.dialect ?? 0;
  Future<void> initialize() async {
    if (_closed) throw const AppFailure('来源已关闭。');
    if (_ipc != null) return;
    final pending = _initializing ??= _initialize();
    try {
      await pending;
    } finally {
      if (identical(_initializing, pending)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    final connection = await connect('IPC\$');
    if (_closed) {
      await connection.close();
      throw const AppFailure('来源已关闭。');
    }
    _ipc = connection;
  }

  (String, String) _split(String path) {
    final parts = p.posix
        .split(path)
        .where((s) => s.isNotEmpty && s != '/')
        .toList();
    if (parts.isEmpty || parts.any((s) => s == '..' || s == '.')) {
      throw const AppFailure('共享路径无效。');
    }
    return (parts.first, parts.skip(1).join('/'));
  }

  Future<SmbSource> _share(String name) async {
    if (_closed) throw const AppFailure('来源已关闭。');
    final existing = _shares[name];
    if (existing != null) return existing;
    if (_shares.length >= 3) {
      final oldest = _shares.remove(_shares.keys.first)!;
      await (await oldest).close();
    }
    final future = () async {
      final connection = await connect(name);
      if (_closed) {
        await connection.close();
        throw const AppFailure('来源已关闭。');
      }
      return SmbSource(connection, reconnect: () => connect(name));
    }();
    _shares[name] = future;
    try {
      return await future;
    } catch (_) {
      _shares.remove(name);
      rethrow;
    }
  }

  @override
  Future<List<SourceEntry>> list(String path) async {
    if (_closed) throw const AppFailure('来源已关闭。');
    if (path.isEmpty) {
      if (_ipc == null) await initialize();
      return (await _ipc!.shares())
          .map(
            (share) => SourceEntry(
              name: share['name'] as String,
              path: '${share['name']}/',
              directory: true,
              hidden: share['hidden'] == true,
            ),
          )
          .toList();
    }
    final (share, relative) = _split(path);
    return (await (await _share(share)).list(relative))
        .map(
          (entry) => SourceEntry(
            name: entry.name,
            path: p.posix.join(share, entry.path),
            size: entry.size,
            directory: entry.directory,
            modified: entry.modified,
            seekable: entry.seekable,
            hidden: entry.hidden,
          ),
        )
        .toList();
  }

  @override
  Future<SourceEntry> stat(String path) async {
    final (share, relative) = _split(path);
    if (relative.isEmpty) {
      return SourceEntry(name: share, path: path, directory: true);
    }
    final entry = await (await _share(share)).stat(relative);
    return SourceEntry(
      name: entry.name,
      path: path,
      size: entry.size,
      directory: entry.directory,
      modified: entry.modified,
      seekable: entry.seekable,
      hidden: entry.hidden,
    );
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    final (share, relative) = _split(path);
    yield* (await _share(share)).read(relative, start, end);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pending = _shares.values.toList();
    _shares.clear();
    await Future.wait([
      if (_ipc != null) _ipc!.close(),
      for (final source in pending)
        () async {
          await (await source).close();
        }(),
    ]);
    _ipc = null;
  }
}

class SmbSource extends SourceAdapter {
  SmbConnection connection;
  final Future<SmbConnection> Function()? reconnect;
  Future<SmbConnection>? _reconnecting;
  bool _closed = false;
  SmbSource(this.connection, {this.reconnect});

  Future<T> _readWithRetry<T>(Future<T> Function(SmbConnection) action) async {
    if (_closed) throw const AppFailure('SMB 来源已关闭。');
    final previous = connection;
    try {
      return await action(previous);
    } catch (_) {
      if (_closed || reconnect == null) rethrow;
      if (identical(previous, connection)) {
        final future = _reconnecting ??= _reconnect(previous);
        try {
          await future;
        } finally {
          if (identical(_reconnecting, future)) _reconnecting = null;
        }
      }
      if (_closed) throw const AppFailure('SMB 来源已关闭。');
      return action(connection);
    }
  }

  Future<SmbConnection> _reconnect(SmbConnection previous) async {
    final next = await reconnect!();
    if (_closed) {
      await next.close();
      throw const AppFailure('SMB 来源已关闭。');
    }
    connection = next;
    unawaited(previous.close().catchError((Object _) {}));
    return next;
  }

  @override
  Future<List<SourceEntry>> list(String path) async =>
      (await _readWithRetry((c) => c.list(path)))
          .map(
            (v) => SourceEntry(
              name: v['name'],
              path: p.posix.join(path, v['name']),
              size: v['size'],
              directory: v['directory'],
              modified: v['modified'] * 1000,
              hidden: v['hidden'] == true,
            ),
          )
          .toList();
  @override
  Future<SourceEntry> stat(String path) async {
    final v = await _readWithRetry((c) => c.stat(path));
    return SourceEntry(
      name: p.posix.basename(path),
      path: path,
      size: v['size'],
      directory: v['directory'],
      modified: v['modified'] * 1000,
      hidden: v['hidden'] == true,
    );
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    var cursor = start;
    var firstRead = true;
    while (cursor <= end) {
      // Native SMB reads complete only after the entire requested block arrives.
      // Deliver a small header/seek probe before switching to large sequential
      // reads, so opening a video does not wait for a full MiB over the network.
      final limit = firstRead ? 64 * 1024 : 1024 * 1024;
      final bytes = await _readWithRetry(
        (c) => c.read(path, cursor, (end - cursor + 1).clamp(1, limit)),
      );
      if (bytes.isEmpty) throw const AppFailure('SMB 文件读取提前结束。');
      yield bytes;
      cursor += bytes.length;
      firstRead = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await connection.close();
  }
}

Future<List<SourceEntry>> _decodeWebDavListing(
  String text,
  Uri requested,
  Uri base,
) {
  final input = (text, requested, base);
  // Keep tiny folders inexpensive while moving large XML trees and all their
  // path/property parsing away from the isolate forwarding playback bytes.
  return text.length < 64 * 1024
      ? Future.value(_parseWebDavListing(input))
      : Isolate.run(() => _parseWebDavListing(input));
}

List<SourceEntry> _parseWebDavListing((String, Uri, Uri) input) {
  final (text, requested, base) = input;
  final document = XmlDocument.parse(text);
  final result = <SourceEntry>[];
  final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
  final trailingSlash = RegExp(r'/$');
  final requestedPath = requested.path.replaceFirst(trailingSlash, '');
  for (final response in document.descendants.whereType<XmlElement>().where(
    (element) => element.name.local == 'response',
  )) {
    final fields = <String, String>{};
    var directory = false;
    for (final element in response.descendants.whereType<XmlElement>()) {
      final name = element.name.local;
      if (name == 'collection') directory = true;
      if (const {
        'href',
        'getcontentlength',
        'getlastmodified',
        'ishidden',
      }.contains(name)) {
        fields.putIfAbsent(name, () => element.innerText);
      }
    }
    final href = requested.resolve(fields['href'] ?? '');
    if (href.origin != base.origin ||
        !href.path.startsWith(basePath) ||
        href.path.replaceFirst(trailingSlash, '') == requestedPath) {
      continue;
    }
    final relative = Uri.decodeComponent(href.path.substring(basePath.length));
    if (relative.split('/').any((segment) => segment == '..')) continue;
    result.add(
      SourceEntry(
        name: p.posix.basename(relative.replaceFirst(trailingSlash, '')),
        path: relative,
        directory: directory,
        size: int.tryParse(fields['getcontentlength'] ?? '') ?? 0,
        modified: _httpModified(fields['getlastmodified'] ?? ''),
        hidden: const [
          '1',
          'true',
        ].contains((fields['ishidden'] ?? '').toLowerCase()),
      ),
    );
  }
  return result;
}

int _httpModified(String value) {
  try {
    return HttpDate.parse(value).millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

bool isVideo(String name) => RegExp(
  r'\.(mkv|mp4|webm|avi|mov|m4v|ts|m2ts|flv|wmv)$',
  caseSensitive: false,
).hasMatch(name);
bool isSubtitle(String name) =>
    RegExp(r'\.(ass|ssa|srt|vtt)$', caseSensitive: false).hasMatch(name);
