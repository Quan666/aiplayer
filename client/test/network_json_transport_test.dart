import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:flutter_test/flutter_test.dart';

class _ConnectingClient implements HttpClient {
  final Future<HttpClientRequest> Function() connect;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  _ConnectingClient(this.connect);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => connect();

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedRequest implements HttpClientRequest {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    fail('A cancelled connection used its late request.');
  }
}

void main() {
  final privateUri = Uri.parse(
    'https://private-user:private-password@private-host.invalid/'
    'private-path?token=private-token',
  );

  test(
    'connection timeout retains its phase and reports once without request data',
    () async {
      final client = _ConnectingClient(
        () => Completer<HttpClientRequest>().future,
      );
      final diagnostics = <NetworkDiagnostic>[];
      const inactivity = Duration(milliseconds: 30);
      final transport = IoJsonTransport(
        inactivity: inactivity,
        createClient: () => client,
        onDiagnostic: diagnostics.add,
      );
      await expectLater(
        transport.send(privateUri),
        throwsA(
          isA<NetworkUnavailable>()
              .having((e) => e.message, 'message', '连接服务超时，请检查网络和服务地址。')
              .having(
                (e) => e.diagnostic?.phase,
                'phase',
                NetworkPhase.connecting,
              )
              .having(
                (e) => e.diagnostic?.reason,
                'reason',
                NetworkFailureReason.timeout,
              ),
        ),
      );
      expect(client.closed, isTrue);
      final diagnostic = diagnostics.single;
      expect(diagnostic.inactivity, inactivity);
      expect(diagnostic.elapsed, greaterThanOrEqualTo(inactivity));
      expect(diagnostic.phaseElapsed, diagnostic.elapsed);
      expect(diagnostic.statusCode, isNull);
      expect(diagnostic.receivedBytes, 0);
    },
  );

  test(
    'native connection timeout and DNS errors retain safe classifications',
    () async {
      for (final (error, reason) in [
        (
          const SocketException(
            'HTTP connection timed out after 0:00:25, host: private-host',
          ),
          NetworkFailureReason.timeout,
        ),
        (
          const SocketException(
            'Failed host lookup: private-host',
            osError: OSError('private DNS reply', -2),
          ),
          NetworkFailureReason.dns,
        ),
        (
          const SocketException(
            'private host refused',
            osError: OSError('private message', 111),
          ),
          NetworkFailureReason.socket,
        ),
      ]) {
        final diagnostics = <NetworkDiagnostic>[];
        final client = _ConnectingClient(() async => throw error);
        final transport = IoJsonTransport(
          createClient: () => client,
          onDiagnostic: diagnostics.add,
        );
        await expectLater(
          transport.send(privateUri),
          throwsA(
            isA<NetworkUnavailable>()
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('private')),
                )
                .having((e) => e.diagnostic?.reason, 'reason', reason),
          ),
        );
        expect(diagnostics.single.phase, NetworkPhase.connecting);
        expect(diagnostics.single.osErrorCode, error.osError?.errorCode);
        expect(client.closed, isTrue);
      }
    },
  );

  test(
    'cancellation stays silent and does not use a late connection',
    () async {
      final opening = Completer<HttpClientRequest>();
      final client = _ConnectingClient(() => opening.future);
      final diagnostics = <NetworkDiagnostic>[];
      final transport = IoJsonTransport(
        createClient: () => client,
        onDiagnostic: diagnostics.add,
      );
      final cancel = CancelToken();
      final pending = expectLater(
        transport.send(privateUri, cancel: cancel),
        throwsA(isA<Cancelled>()),
      );
      cancel.cancel();
      await pending;
      expect(client.closed, isTrue);
      opening.complete(_UnusedRequest());
      await Future<void>.delayed(Duration.zero);
      expect(diagnostics, isEmpty);
    },
  );

  test(
    'a diagnostic listener cannot change or duplicate request failures',
    () async {
      var calls = 0;
      final transport = IoJsonTransport(
        createClient: () => _ConnectingClient(
          () async => throw const SocketException('private host'),
        ),
        onDiagnostic: (_) {
          calls++;
          throw StateError('diagnostic consumer failed');
        },
      );
      await expectLater(
        transport.send(privateUri),
        throwsA(isA<NetworkUnavailable>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'TLS failures report connecting without exposing native certificate text',
    () async {
      final diagnostics = <NetworkDiagnostic>[];
      final transport = IoJsonTransport(
        createClient: () => _ConnectingClient(
          () async => throw const HandshakeException(
            'private-certificate private-token',
          ),
        ),
        onDiagnostic: diagnostics.add,
      );
      await expectLater(
        transport.send(privateUri),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
      expect(diagnostics.single.phase, NetworkPhase.connecting);
      expect(diagnostics.single.reason, NetworkFailureReason.tls);
    },
  );

  test(
    'response header and body stalls have distinct terminal diagnostics',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/headers') return;
        try {
          request.response.bufferOutput = false;
          request.response.write('{"ok":');
          await request.response.flush();
        } on SocketException {
          // The client abandons the deliberately incomplete response.
        }
      });
      try {
        for (final (path, phase) in [
          ('/headers', NetworkPhase.responseHeaders),
          ('/body', NetworkPhase.responseBody),
        ]) {
          final diagnostics = <NetworkDiagnostic>[];
          final transport = IoJsonTransport(
            inactivity: const Duration(milliseconds: 150),
            onDiagnostic: diagnostics.add,
          );
          await expectLater(
            transport.send(
              Uri.parse('http://127.0.0.1:${server.port}$path?token=private'),
            ),
            throwsA(
              isA<NetworkUnavailable>().having(
                (e) => e.diagnostic?.phase,
                'phase',
                phase,
              ),
            ),
          );
          final diagnostic = diagnostics.single;
          expect(diagnostic.reason, NetworkFailureReason.timeout);
          expect(diagnostic.statusCode, path == '/body' ? 200 : null);
          expect(
            diagnostic.receivedBytes,
            path == '/body' ? greaterThan(0) : 0,
          );
          expect(
            diagnostic.phaseElapsed,
            lessThanOrEqualTo(diagnostic.elapsed),
          );
        }
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'gzip with content length and chunked EOF both decode and stay silent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <String?>[], encodings = <String?>[];
      server.listen((request) async {
        accepted.add(request.headers.value(HttpHeaders.acceptHeader));
        encodings.add(request.headers.value(HttpHeaders.acceptEncodingHeader));
        final bytes = gzip.encode(
          utf8.encode(
            jsonEncode({
              'name': '中文作品',
              'items': [1, 2],
            }),
          ),
        );
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        if (request.uri.path == '/length') {
          request.response.contentLength = bytes.length;
        }
        request.response.bufferOutput = false;
        final split = bytes.length ~/ 2;
        request.response.add(bytes.sublist(0, split));
        await request.response.flush();
        request.response.add(bytes.sublist(split));
        await request.response.close();
      });
      final diagnostics = <NetworkDiagnostic>[];
      final transport = IoJsonTransport(onDiagnostic: diagnostics.add);
      try {
        for (final path in ['/length', '/chunked']) {
          expect(
            await transport.send(
              Uri.parse('http://127.0.0.1:${server.port}$path'),
            ),
            {
              'name': '中文作品',
              'items': [1, 2],
            },
          );
        }
        expect(accepted, everyElement('application/json'));
        expect(encodings, everyElement(contains('gzip')));
        expect(diagnostics, isEmpty);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'configured proxy routing is retained without resolving the destination',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final destinations = <String>[];
      proxy.listen((request) async {
        destinations.add(request.uri.host);
        request.response.write('{"ok":true}');
        await request.response.close();
      });
      final diagnostics = <NetworkDiagnostic>[];
      final transport = IoJsonTransport(
        createClient: () =>
            HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}',
        onDiagnostic: diagnostics.add,
      );
      try {
        expect(
          await transport.send(
            Uri.parse('http://unresolvable.invalid/private'),
          ),
          {'ok': true},
        );
        expect(destinations, ['unresolvable.invalid']);
        expect(diagnostics, isEmpty);
      } finally {
        await proxy.close(force: true);
      }
    },
  );

  test(
    'system proxy is resolved per destination and HTTPS uses CONNECT',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      proxy.listen((request) async {
        requests.add(request.method);
        if (request.method == 'CONNECT') {
          expect(request.uri.toString(), contains('unresolvable.invalid:443'));
          request.response.statusCode = 502;
        } else {
          expect(request.uri.host, 'unresolvable.invalid');
          request.response.write('{"ok":true}');
        }
        await request.response.close();
      });
      final targets = <Uri>[];
      final transport = IoJsonTransport(
        proxyResolver: (uri, {cancel}) async {
          targets.add(uri);
          return 'PROXY 127.0.0.1:${proxy.port}';
        },
      );
      try {
        final http = Uri.parse('http://unresolvable.invalid/details');
        final https = Uri.parse('https://unresolvable.invalid/details');
        expect(await transport.send(http), {'ok': true});
        await expectLater(transport.send(https), throwsA(isA<AppFailure>()));
        expect(targets, [http, https]);
        expect(requests, ['GET', 'CONNECT']);
      } finally {
        await proxy.close(force: true);
      }
    },
  );

  test('cancelled proxy lookup never opens a late connection', () async {
    final lookup = Completer<String?>();
    final client = _ConnectingClient(() async {
      fail('Cancelled proxy lookup opened a connection.');
    });
    final diagnostics = <NetworkDiagnostic>[];
    final token = CancelToken();
    final transport = IoJsonTransport(
      createClient: () => client,
      proxyResolver: (uri, {cancel}) => lookup.future,
      onDiagnostic: diagnostics.add,
    );
    final pending = expectLater(
      transport.send(privateUri, cancel: token),
      throwsA(isA<Cancelled>()),
    );
    token.cancel();
    await pending;
    lookup.complete('DIRECT');
    await Future<void>.delayed(Duration.zero);
    expect(client.closed, isTrue);
    expect(diagnostics, isEmpty);
  });

  test('proxy timeout has a distinct diagnostic and never connects', () async {
    final client = _ConnectingClient(() async {
      fail('Failed proxy lookup opened a direct connection.');
    });
    final transport = IoJsonTransport(
      createClient: () => client,
      proxyResolver: (uri, {cancel}) async => throw TimeoutException('proxy'),
    );
    await expectLater(
      transport.send(privateUri),
      throwsA(
        isA<NetworkUnavailable>()
            .having((e) => e.message, 'message', contains('系统代理'))
            .having(
              (e) => e.diagnostic?.phase,
              'phase',
              NetworkPhase.proxyResolution,
            ),
      ),
    );
    expect(client.closed, isTrue);
  });

  test(
    'HTTP rejection does not wait for the body and malformed JSON reports decode',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          if (request.uri.path == '/http') {
            request.response.statusCode = 429;
            request.response.bufferOutput = false;
            request.response.write('private-token');
            await request.response.flush();
            return;
          }
          if (request.uri.path == '/utf8') {
            request.response.add([0xff, 0xff]);
          } else {
            request.response.write('{"private-token": broken');
          }
          await request.response.close();
        } on SocketException {
          // Error response bodies are intentionally not consumed.
        }
      });
      try {
        for (final path in ['/http', '/json', '/utf8']) {
          final diagnostics = <NetworkDiagnostic>[];
          final transport = IoJsonTransport(onDiagnostic: diagnostics.add);
          await expectLater(
            transport
                .send(Uri.parse('http://127.0.0.1:${server.port}$path'))
                .timeout(const Duration(seconds: 2)),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.message,
                'safe message',
                isNot(contains('private')),
              ),
            ),
          );
          final diagnostic = diagnostics.single;
          expect(
            diagnostic.phase,
            path == '/http'
                ? NetworkPhase.responseHeaders
                : NetworkPhase.decode,
          );
          expect(
            diagnostic.reason,
            path == '/http'
                ? NetworkFailureReason.httpStatus
                : NetworkFailureReason.invalidResponse,
          );
          expect(diagnostic.statusCode, path == '/http' ? 429 : 200);
          if (path == '/http') expect(diagnostic.receivedBytes, 0);
        }
      } finally {
        await server.close(force: true);
      }
    },
  );
}
