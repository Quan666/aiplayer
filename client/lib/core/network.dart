import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'json_work.dart';
import 'system_proxy_stub.dart' if (dart.library.ui) 'system_proxy.dart';

class AppFailure implements Exception {
  final String message;
  final int? status;
  const AppFailure(this.message, [this.status]);
  @override
  String toString() => message;
}

class Cancelled extends AppFailure {
  const Cancelled() : super('请求已取消');
}

enum NetworkPhase {
  proxyResolution,
  connecting,
  responseHeaders,
  responseBody,
  decode,
}

enum NetworkFailureReason {
  timeout,
  dns,
  socket,
  tls,
  httpStatus,
  invalidResponse,
  serviceRejected,
  unknown,
}

/// One terminal failure, containing no URL, credentials, body or native error
/// text. Successful requests and explicit cancellation do not emit diagnostics.
class NetworkDiagnostic {
  final NetworkPhase phase;
  final NetworkFailureReason reason;
  final Duration elapsed, phaseElapsed, inactivity;
  final int? statusCode, osErrorCode;

  /// Bytes received after HttpClient's automatic content decompression.
  final int receivedBytes;
  const NetworkDiagnostic({
    required this.phase,
    required this.reason,
    required this.elapsed,
    required this.phaseElapsed,
    required this.inactivity,
    required this.receivedBytes,
    this.statusCode,
    this.osErrorCode,
  });
}

/// The server could not be reached or stopped responding. Callers may retain
/// already fetched optional data without treating invalid responses as offline.
class NetworkUnavailable extends AppFailure {
  final NetworkDiagnostic? diagnostic;
  const NetworkUnavailable(super.message, {this.diagnostic});
}

class CancelToken {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!cancelled) _done.complete();
  }

  void check() {
    if (cancelled) throw const Cancelled();
  }
}

/// Resolve before opening each URL, including explicit redirect hops. Dart's
/// HttpClient snapshots findProxy synchronously in openUrl, so a pooled client
/// can serve concurrent destinations without caching PAC answers or losing
/// connection reuse. Automatic redirects are disabled so callers resolve each
/// redirect destination separately.
Future<HttpClientRequest> openProxyAwareRequest(
  HttpClient client,
  String method,
  Uri uri, {
  SystemProxyLookup? proxyResolver,
  CancelToken? cancel,
}) async {
  cancel?.check();
  final proxy = await proxyResolver?.call(uri, cancel: cancel);
  cancel?.check();
  if (proxy != null) client.findProxy = (_) => proxy;
  final request = await client.openUrl(method, uri);
  if (cancel?.cancelled == true) {
    request.abort();
    throw const Cancelled();
  }
  request.followRedirects = false;
  if (uri.scheme == 'https' && proxy?.contains('PROXY ') == true) {
    // Dart stores CONNECT tunnels under the target origin's idle pool, which
    // can reuse an old tunnel after PAC switches that origin to DIRECT. Dart
    // does not consult that pool for subsequent proxied requests anyway; close
    // only these tunnels while retaining direct HTTPS and HTTP proxy pooling.
    request.persistentConnection = false;
  }
  return request;
}

abstract interface class JsonTransport {
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  });
}

class IoJsonTransport implements JsonTransport {
  final Duration inactivity;
  final HttpClient Function() createClient;
  final SystemProxyLookup? proxyResolver;
  final void Function(NetworkDiagnostic diagnostic)? onDiagnostic;
  IoJsonTransport({
    this.inactivity = const Duration(seconds: 25),
    HttpClient Function()? createClient,
    SystemProxyLookup? proxyResolver,
    this.onDiagnostic,
  }) : createClient = createClient ?? HttpClient.new,
       proxyResolver =
           proxyResolver ?? (createClient == null ? resolveSystemProxy : null);

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final client = createClient()..connectionTimeout = inactivity;
    final elapsed = Stopwatch()..start();
    var phase = NetworkPhase.connecting;
    var phaseStarted = Duration.zero;
    var receivedBytes = 0;
    int? statusCode;
    NetworkFailureReason? responseFailure;
    var done = false;

    void enter(NetworkPhase next) {
      phase = next;
      phaseStarted = elapsed.elapsed;
    }

    NetworkDiagnostic report(NetworkFailureReason reason, {int? osErrorCode}) {
      final total = elapsed.elapsed;
      final diagnostic = NetworkDiagnostic(
        phase: phase,
        reason: reason,
        elapsed: total,
        phaseElapsed: total - phaseStarted,
        inactivity: inactivity,
        receivedBytes: receivedBytes,
        statusCode: statusCode,
        osErrorCode: osErrorCode,
      );
      try {
        onDiagnostic?.call(diagnostic);
      } catch (_) {
        // Optional diagnostics cannot change the request's failure or retry path.
      }
      return diagnostic;
    }

    Future<dynamic> readJson(HttpClientResponse response) async {
      enter(NetworkPhase.responseBody);
      final bytes = response.timeout(inactivity).map((chunk) {
        receivedBytes += chunk.length;
        return chunk;
      });
      final String text;
      try {
        text = await utf8.decoder.bind(bytes).join();
      } on FormatException {
        enter(NetworkPhase.decode);
        rethrow;
      }
      cancel?.check();
      enter(NetworkPhase.decode);
      final value = await decodeJson(text);
      cancel?.check();
      return value;
    }

    Future<Map<String, dynamic>> work() async {
      if (proxyResolver != null) {
        enter(NetworkPhase.proxyResolution);
        final proxy = await proxyResolver!(uri, cancel: cancel);
        cancel?.check();
        if (proxy != null) client.findProxy = (_) => proxy;
        enter(NetworkPhase.connecting);
      }
      final request = await client.openUrl(method, uri).timeout(inactivity);
      cancel?.check();
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      enter(NetworkPhase.responseHeaders);
      final response = await request.close().timeout(inactivity);
      cancel?.check();
      statusCode = response.statusCode;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = response.statusCode;
        responseFailure = NetworkFailureReason.httpStatus;
        if (code == 401 || code == 403) {
          throw AppFailure('认证失败，请检查地址和 Token。', code);
        }
        if (code == 429) throw AppFailure('请求过于频繁，请稍后重试。', code);
        if (code >= 300 && code < 400) throw AppFailure('服务返回了不允许的重定向。', code);
        // Sync conflicts carry the current version, not raw server error text.
        if (code == 409) {
          final value = await readJson(response);
          if (value is Map<String, dynamic>) return {...value, '_status': 409};
        }
        throw AppFailure('服务请求失败（HTTP $code）。', code);
      }
      final result = await readJson(response);
      if (result is! Map<String, dynamic>) {
        responseFailure = NetworkFailureReason.invalidResponse;
        throw const AppFailure('服务响应格式无效。');
      }
      if (result['success'] == false ||
          (num.tryParse('${result['errorCode']}') ?? 0) > 0) {
        responseFailure = NetworkFailureReason.serviceRejected;
        throw const AppFailure('服务未能完成请求，请稍后重试。');
      }
      return result;
    }

    try {
      return await Future.any([
        work(),
        if (cancel != null)
          cancel.whenCancelled.then<Map<String, dynamic>>((_) {
            if (!done) client.close(force: true);
            throw const Cancelled();
          }),
      ]);
    } on Cancelled {
      rethrow;
    } on AppFailure {
      cancel?.check();
      report(responseFailure ?? NetworkFailureReason.unknown);
      rethrow;
    } on TimeoutException {
      cancel?.check();
      final diagnostic = report(NetworkFailureReason.timeout);
      throw NetworkUnavailable(_timeoutMessage(phase), diagnostic: diagnostic);
    } on FormatException {
      cancel?.check();
      report(NetworkFailureReason.invalidResponse);
      throw const AppFailure('服务返回了无效的 JSON。');
    } on SocketException catch (error) {
      cancel?.check();
      final reason = _socketFailureReason(error);
      final diagnostic = report(reason, osErrorCode: error.osError?.errorCode);
      throw NetworkUnavailable(
        reason == NetworkFailureReason.timeout
            ? _timeoutMessage(phase)
            : reason == NetworkFailureReason.dns
            ? '无法解析服务地址，请检查 DNS 和网络。'
            : '无法连接服务，请检查网络和服务地址。',
        diagnostic: diagnostic,
      );
    } on TlsException {
      cancel?.check();
      report(NetworkFailureReason.tls);
      throw const AppFailure('TLS 连接失败，请检查 HTTPS 配置和证书。');
    } catch (_) {
      cancel?.check();
      report(NetworkFailureReason.unknown);
      throw const AppFailure('无法连接服务，请检查网络和服务地址。');
    } finally {
      done = true;
      elapsed.stop();
      client.close(force: true);
    }
  }
}

String _timeoutMessage(NetworkPhase phase) => switch (phase) {
  NetworkPhase.proxyResolution => '读取系统代理超时，请检查系统代理设置。',
  NetworkPhase.connecting => '连接服务超时，请检查网络和服务地址。',
  NetworkPhase.responseHeaders => '等待服务响应超时，请重试。',
  NetworkPhase.responseBody => '接收服务数据超时，请重试。',
  NetworkPhase.decode => '解析服务数据超时，请重试。',
};

NetworkFailureReason _socketFailureReason(SocketException error) {
  final message = error.message.toLowerCase();
  // HttpClient.connectionTimeout wraps TimeoutException as SocketException.
  if (const {60, 110, 10060}.contains(error.osError?.errorCode) ||
      message.contains('timed out')) {
    return NetworkFailureReason.timeout;
  }
  if (message.contains('host lookup') ||
      message.contains('name or service') ||
      message.contains('nodename nor servname')) {
    return NetworkFailureReason.dns;
  }
  return NetworkFailureReason.socket;
}
