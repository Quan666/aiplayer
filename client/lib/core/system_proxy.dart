import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'network.dart';

typedef SystemProxyLookup =
    Future<String?> Function(Uri uri, {CancelToken? cancel});

/// Captured before spawning a worker so every network isolate uses the same
/// platform policy and can reach the native resolver through its messenger.
class SystemProxyWorkerConfiguration {
  final RootIsolateToken? token;
  final String operatingSystem;

  SystemProxyWorkerConfiguration.capture()
    : token = ServicesBinding.rootIsolateToken,
      operatingSystem = _systemProxyResolver.operatingSystem;
}

void initializeSystemProxyWorker(SystemProxyWorkerConfiguration configuration) {
  _systemProxyResolver = SystemProxyResolver(
    operatingSystem: configuration.operatingSystem,
  );
  if (_systemProxyResolver.supported && configuration.token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(configuration.token!);
  }
}

var _systemProxyResolver = SystemProxyResolver();

/// Unit tests have no native runner. Keep that choice explicit and propagate it
/// to workers; a missing plugin in a real app must never silently bypass proxy.
@visibleForTesting
void overrideSystemProxyPlatformForTesting(String operatingSystem) {
  _systemProxyResolver.dispose();
  _systemProxyResolver = SystemProxyResolver(operatingSystem: operatingSystem);
}

/// Resolves each URL using current OS settings. Linux can return null when no
/// system resolver is installed, retaining HttpClient's environment policy.
Future<String?> resolveSystemProxy(
  Uri uri, {
  CancelToken? cancel,
  Duration timeout = const Duration(seconds: 5),
}) => _systemProxyResolver.resolve(uri, cancel: cancel, timeout: timeout);

class SystemProxyResolver {
  static const channel = MethodChannel('app.aiplayer/system_proxy');
  final MethodChannel _channel;
  final String operatingSystem;
  final String _client = const Uuid().v4();
  final Map<String, Completer<void>> _pending = {};
  int _serial = 0;
  bool _disposed = false;

  SystemProxyResolver({MethodChannel? methodChannel, String? operatingSystem})
    : _channel = methodChannel ?? channel,
      operatingSystem = operatingSystem ?? Platform.operatingSystem;

  bool get supported => const {
    'android',
    'ios',
    'macos',
    'windows',
    'linux',
  }.contains(operatingSystem);

  Future<String?> resolve(
    Uri uri, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    if (!supported || (uri.scheme != 'http' && uri.scheme != 'https')) {
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
      // These values are sent only to the OS selector and are never logged.
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
      if (value == null && operatingSystem == 'linux') {
        // Explicit environment result also clears a previous native route on
        // pooled clients if the desktop resolver disappears or is disabled.
        return HttpClient.findProxyFromEnvironment(uri);
      }
      if (value == null || !_validProxyConfiguration(value)) {
        throw const AppFailure('系统代理配置无效，请检查系统网络设置。');
      }
      return value;
    } on MissingPluginException {
      throw const AppFailure('无法读取系统代理，请重新启动应用。');
    } on PlatformException catch (error) {
      cancel?.check();
      if (_disposed ||
          error.code == 'proxy_cancelled' ||
          error.code == 'proxy_disposed') {
        throw const Cancelled();
      }
      if (error.code == 'proxy_timeout') {
        throw TimeoutException('读取系统代理超时。', timeout);
      }
      throw AppFailure(switch (error.code) {
        'proxy_unsupported' => '系统代理类型暂不支持，请使用 HTTP 代理。',
        'proxy_busy' => '系统代理查询繁忙，请稍后重试。',
        _ => '无法解析系统代理，请检查网络设置。',
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
