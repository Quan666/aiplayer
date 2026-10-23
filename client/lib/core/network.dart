import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'json_work.dart';

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
  IoJsonTransport({
    this.inactivity = const Duration(seconds: 25),
    HttpClient Function()? createClient,
  }) : createClient = createClient ?? HttpClient.new;

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
    var done = false;
    Future<Map<String, dynamic>> work() async {
      final request = await client.openUrl(method, uri).timeout(inactivity);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(inactivity);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = response.statusCode;
        if (code == 401 || code == 403) {
          throw AppFailure('认证失败，请检查地址和 Token。', code);
        }
        if (code == 429) throw AppFailure('请求过于频繁，请稍后重试。', code);
        if (code >= 300 && code < 400) throw AppFailure('服务返回了不允许的重定向。', code);
        // Sync conflicts carry the current version, not raw server error text.
        if (code == 409) {
          final value = await decodeJson(
            await utf8.decoder.bind(response.timeout(inactivity)).join(),
          );
          cancel?.check();
          if (value is Map<String, dynamic>) return {...value, '_status': 409};
        }
        throw AppFailure('服务请求失败（HTTP $code）。', code);
      }
      final text = await utf8.decoder.bind(response.timeout(inactivity)).join();
      cancel?.check();
      final result = await decodeJson(text);
      cancel?.check();
      if (result is! Map<String, dynamic>) throw const AppFailure('服务响应格式无效。');
      if (result['success'] == false ||
          (num.tryParse('${result['errorCode']}') ?? 0) > 0) {
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
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw const AppFailure('服务长时间未收到数据，请重试。');
    } on FormatException {
      throw const AppFailure('服务返回了无效的 JSON。');
    } catch (_) {
      cancel?.check();
      throw const AppFailure('无法连接服务，请检查网络和服务地址。');
    } finally {
      done = true;
      client.close(force: true);
    }
  }
}
