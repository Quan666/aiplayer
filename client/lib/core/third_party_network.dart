import 'dart:async';

import 'package:flutter/foundation.dart';

import 'network.dart';

/// An explicit boundary for service traffic. Source adapters, playback,
/// downloads and local discovery never use this policy.
class ThirdPartyNetworkPolicy extends ChangeNotifier {
  bool _enabled;
  bool _closed = false;
  final _requests = <CancelToken>{};

  ThirdPartyNetworkPolicy({this._enabled = true});

  bool get enabled => !_closed && _enabled;

  void check() {
    if (!enabled) throw const AppFailure('第三方联网已关闭。');
  }

  void setEnabled(bool value) {
    if (_closed || value == _enabled) return;
    _enabled = value;
    if (!value) cancelRequests();
    notifyListeners();
  }

  /// Credential replacement revokes old work without changing the user's
  /// network preference or automatically issuing a replacement request.
  void cancelRequests() {
    for (final request in _requests.toList(growable: false)) {
      request.cancel();
    }
  }

  Future<T> run<T>(
    Future<T> Function(CancelToken) work, {
    CancelToken? cancel,
  }) async {
    check();
    cancel?.check();
    final request = CancelToken();
    _requests.add(request);
    final subscription = cancel?.whenCancelled.asStream().listen(
      (_) => request.cancel(),
    );
    try {
      final result = await Future.any([
        work(request),
        request.whenCancelled.then<T>((_) => throw const Cancelled()),
      ]);
      request.check();
      check();
      return result;
    } finally {
      _requests.remove(request);
      // A Future-backed stream may wait for the caller's lifetime token while
      // cancelling its subscription. Detach now without delaying success.
      unawaited(subscription?.cancel());
    }
  }

  JsonTransport jsonTransport({
    JsonTransport? transport,
    Future<void> Function(CancelToken)? authorize,
  }) => _PolicyJsonTransport(this, transport ?? IoJsonTransport(), authorize);

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.toList(growable: false)) {
      request.cancel();
    }
    _requests.clear();
    super.dispose();
  }
}

class _PolicyJsonTransport implements JsonTransport {
  final ThirdPartyNetworkPolicy policy;
  final JsonTransport delegate;
  final Future<void> Function(CancelToken)? authorize;
  _PolicyJsonTransport(this.policy, this.delegate, this.authorize);

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) => policy.run((request) async {
    await authorize?.call(request);
    request.check();
    return delegate.send(
      uri,
      method: method,
      body: body,
      headers: headers,
      cancel: request,
    );
  }, cancel: cancel);
}
