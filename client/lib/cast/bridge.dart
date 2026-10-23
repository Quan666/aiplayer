import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../core/network.dart';
import '../core/logger.dart';
import '../sources/range_bridge.dart';
import '../sources/source.dart';
import 'dlna.dart';

/// Exists only during a user-started cast. One interface, one renderer IP, one
/// file and an unguessable session URL; it never exposes directory listing.
class CastBridge {
  final SourceAdapter source;
  final String path;
  final SourceEntry entry;
  final InternetAddress renderer;
  final HttpServer _server;
  final String _token;
  final void Function(AppFailure)? onError;
  bool _closed = false;
  late final Uri uri;
  CastBridge._(
    this.source,
    this.path,
    this.entry,
    this.renderer,
    this._server,
    this._token,
    this.onError,
  ) {
    uri = Uri(
      scheme: 'http',
      host: _server.address.address,
      port: _server.port,
      path:
          '/$_token/video.${entry.name.split('.').last.replaceAll(RegExp('[^a-zA-Z0-9]'), '')}',
    );
  }
  static Future<CastBridge> open(
    SourceAdapter source,
    String path, {
    required InternetAddress localAddress,
    required InternetAddress renderer,
    void Function(AppFailure)? onError,
  }) async {
    if (!isLocalCastAddress(localAddress) || !isLocalCastAddress(renderer)) {
      throw const AppFailure('只能向同一局域网中的设备投屏。');
    }
    final entry = await source.stat(path);
    if (entry.directory || entry.size <= 0) throw const AppFailure('视频为空或不可读。');
    final server = await HttpServer.bind(localAddress, 0);
    final random = Random.secure();
    final bridge = CastBridge._(
      source,
      path,
      entry,
      renderer,
      server,
      base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', ''),
      onError,
    );
    server.listen(bridge._serve);
    return bridge;
  }

  String get mime => switch (entry.name.toLowerCase().split('.').last) {
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'ts' || 'm2ts' || 'mts' => 'video/mp2t',
    'avi' => 'video/x-msvideo',
    'mov' => 'video/quicktime',
    'mpeg' || 'mpg' => 'video/mpeg',
    _ => 'video/mp4',
  };
  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (_closed ||
          request.connectionInfo?.remoteAddress.address != renderer.address ||
          request.uri.path != uri.path) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      if (!['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 405;
        await response.close();
        return;
      }
      final header = request.headers.value('range');
      final range = ByteRange.parse(header, entry.size);
      if (range == null || !entry.seekable && range.start > 0) {
        _report(
          AppFailure(range == null ? '投屏设备请求的视频范围无效。' : '此视频来源不支持随机拖动，请从开头播放。'),
        );
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */${entry.size}');
        await response.close();
        return;
      }
      response.statusCode = header == null ? 200 : 206;
      response.headers.set('Content-Type', mime);
      response.headers.set('Accept-Ranges', entry.seekable ? 'bytes' : 'none');
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('transferMode.dlna.org', 'Streaming');
      response.headers.set(
        'contentFeatures.dlna.org',
        'DLNA.ORG_OP=${entry.seekable ? '01' : '00'};DLNA.ORG_CI=0',
      );
      response.contentLength = range.length;
      if (header != null) {
        response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/${entry.size}',
        );
      }
      if (request.method == 'GET') {
        await response.addStream(source.read(path, range.start, range.end));
      }
      await response.close();
    } catch (error) {
      if (!_closed) {
        _report(AppFailure('读取投屏视频失败：${safeFailure(error).message}'));
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _report(AppFailure error) {
    try {
      onError?.call(error);
    } catch (_) {
      /* The HTTP stream still closes if UI has disposed. */
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }
}
