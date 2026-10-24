import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'network.dart';

typedef SystemProxyLookup =
    Future<String?> Function(Uri uri, {CancelToken? cancel});

/// Call once at an Android worker entry point using the token captured on the
/// root isolate before spawning it. No channel work is needed on other hosts.
void initializeSystemProxyWorker(RootIsolateToken? token) {
  if (Platform.isAndroid && token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
}

final _systemProxyResolver = SystemProxyResolver();

/// Returns null outside Android so callers retain their existing environment or
/// custom proxy policy. Android resolves each URL using the current selector.
Future<String?> resolveSystemProxy(
  Uri uri, {
  CancelToken? cancel,
  Duration timeout = const Duration(seconds: 5),
}) => _systemProxyResolver.resolve(uri, cancel: cancel, timeout: timeout);

class SystemProxyResolver {
  static const channel = MethodChannel('app.aiplayer/system_proxy');
  final MethodChannel _channel;
  final bool _android;
  final String _client = const Uuid().v4();
  final Map<String, Completer<void>> _pending = {};
  int _serial = 0;
  bool _disposed = false;

  SystemProxyResolver({MethodChannel? methodChannel, bool? isAndroid})
    : _channel = methodChannel ?? channel,
      _android = isAndroid ?? Platform.isAndroid;

  Future<String?> resolve(
    Uri uri, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    if (!_android || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    if (_pending.length >= 32) {
      throw const AppFailure('系统代理查询繁忙，请稍后重试。');
    }
    final id = '$_client:${++_serial}';
    final disposed = Completer<void>();
    _pending[id] = disposed;
    var nativeFinished = false;
    try {
      // PAC can depend on path/query, but never needs credentials or fragments.
      // These values are sent only to Android's selector and are never logged.
      final target = uri.replace(userInfo: '').removeFragment().toString();
      final request = _channel
          .invokeMethod<String>('resolve', {'id': id, 'url': target})
          .whenComplete(() => nativeFinished = true);
      final value = await Future.any<String?>([
        request.timeout(timeout),
        disposed.future.then((_) => throw const Cancelled()),
        if (cancel != null)
          cancel.whenCancelled.then((_) => throw const Cancelled()),
      ]);
      cancel?.check();
      if (_disposed) throw const Cancelled();
      if (value == null || !_validProxyConfiguration(value)) {
        throw const AppFailure('系统代理配置无效，请检查 Android 网络设置。');
      }
      return value;
    } on MissingPluginException {
      throw const AppFailure('无法读取 Android 系统代理，请重新启动应用。');
    } on PlatformException catch (error) {
      cancel?.check();
      if (_disposed ||
          error.code == 'proxy_cancelled' ||
          error.code == 'proxy_disposed') {
        throw const Cancelled();
      }
      throw AppFailure(switch (error.code) {
        'proxy_unsupported' => '系统代理类型暂不支持，请使用 HTTP 代理。',
        'proxy_busy' => '系统代理查询繁忙，请稍后重试。',
        _ => '无法解析 Android 系统代理，请检查网络设置。',
      });
    } finally {
      _pending.remove(id);
      if (!nativeFinished) _cancelNative(id);
    }
  }

  void _cancelNative(String id) {
    unawaited(
      _channel
          .invokeMethod<void>('cancel', {'id': id})
          .catchError((Object _) {}),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.complete();
    }
  }
}

bool _validProxyConfiguration(String value) {
  if (value.isEmpty || value.length > 16384) return false;
  final entries = value.split(';');
  if (entries.length > 32) return false;
  for (final entry in entries) {
    final route = entry.trim();
    if (route == 'DIRECT') continue;
    if (!route.startsWith('PROXY ')) return false;
    final endpoint = route.substring(6);
    if (endpoint.contains(RegExp(r'[\s;/@?#\\]'))) return false;
    final address = Uri.tryParse('http://$endpoint');
    if (address == null ||
        address.host.isEmpty ||
        !address.hasPort ||
        address.port < 1 ||
        address.port > 65535 ||
        address.path.isNotEmpty ||
        address.hasQuery ||
        address.hasFragment ||
        address.userInfo.isNotEmpty) {
      return false;
    }
  }
  return true;
}
