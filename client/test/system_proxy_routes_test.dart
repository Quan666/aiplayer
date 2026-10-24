import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

HttpClient _client() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'concurrent pooled requests keep their independently resolved proxy',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <String>[];
      first.listen((request) async {
        received.add('first:${request.uri.host}');
        await request.response.close();
      });
      second.listen((request) async {
        received.add('second:${request.uri.host}');
        await request.response.close();
      });
      final client = _client();
      final lookupA = Completer<String?>(), lookupB = Completer<String?>();
      try {
        final a = openProxyAwareRequest(
          client,
          'GET',
          Uri.parse('http://a.unresolvable.invalid/'),
          proxyResolver: (_, {cancel}) => lookupA.future,
        );
        final b = openProxyAwareRequest(
          client,
          'GET',
          Uri.parse('http://b.unresolvable.invalid/'),
          proxyResolver: (_, {cancel}) => lookupB.future,
        );
        // Complete both before either connection finishes, in reverse order.
        lookupB.complete('PROXY 127.0.0.1:${second.port}');
        lookupA.complete('PROXY 127.0.0.1:${first.port}');
        await Future.wait([
          a.then((request) async => (await request.close()).drain<void>()),
          b.then((request) async => (await request.close()).drain<void>()),
        ]);
        expect(
          received,
          unorderedEquals([
            'first:a.unresolvable.invalid',
            'second:b.unresolvable.invalid',
          ]),
        );
      } finally {
        client.close(force: true);
        await first.close(force: true);
        await second.close(force: true);
      }
    },
  );

  test(
    'HTTP source resolves proxy for stat and range reads without destination DNS',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      final connections = <int>{};
      proxy.listen((request) async {
        methods.add(request.method);
        connections.add(request.connectionInfo!.remotePort);
        expect(request.uri.host, 'source.unresolvable.invalid');
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.contentLength = 4;
        if (request.method == 'GET') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-range', 'bytes 0-3/4');
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final targets = <Uri>[];
      final source = HttpOverrides.runWithHttpOverrides(
        () => HttpSource(
          'http://source.unresolvable.invalid/video.mp4',
          proxyResolver: (uri, {cancel}) async {
            targets.add(uri);
            return 'PROXY 127.0.0.1:${proxy.port}';
          },
        ),
        _RealHttp(),
      );
      try {
        expect((await source.stat('')).size, 4);
        expect(await source.read('', 0, 3).expand((chunk) => chunk).toList(), [
          1,
          2,
          3,
          4,
        ]);
        expect(methods, ['HEAD', 'GET']);
        expect(connections, hasLength(1));
        expect(targets, hasLength(2));
      } finally {
        await source.close();
        await proxy.close(force: true);
      }
    },
  );

  test('HTTPS proxy removal does not reuse an idle CONNECT tunnel', () async {
    final context = SecurityContext()
      ..useCertificateChainBytes(
        await File('test/fixtures/proxy_local_test_cert.pem').readAsBytes(),
      )
      ..usePrivateKeyBytes(
        await File('test/fixtures/proxy_local_test_key.pem').readAsBytes(),
      );
    final origin = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ports = <int>[];
    final sockets = <Socket>[];
    origin.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      await request.response.close();
    });
    proxy.listen((downstream) async {
      sockets.add(downstream);
      final reader = StreamIterator(downstream);
      final header = <int>[];
      while (await reader.moveNext()) {
        header.addAll(reader.current);
        if (String.fromCharCodes(header).contains('\r\n\r\n')) break;
      }
      expect(String.fromCharCodes(header), startsWith('CONNECT '));
      final upstream = await Socket.connect('127.0.0.1', origin.port);
      sockets.add(upstream);
      downstream.write('HTTP/1.1 200 Connection established\r\n\r\n');
      await downstream.flush();
      upstream.listen(
        downstream.add,
        onDone: downstream.destroy,
        onError: (Object _) => downstream.destroy(),
      );
      try {
        while (await reader.moveNext()) {
          upstream.add(reader.current);
        }
      } on SocketException {
        // Teardown closes both ends of the fixture tunnel.
      } finally {
        upstream.destroy();
      }
    });
    final client = _client()
      ..badCertificateCallback = (certificate, host, port) => true;
    try {
      final uri = Uri.parse('https://127.0.0.1:${origin.port}/');
      for (final route in [
        'PROXY 127.0.0.1:${proxy.port}',
        'DIRECT',
        'DIRECT',
      ]) {
        final request = await openProxyAwareRequest(
          client,
          'GET',
          uri,
          proxyResolver: (_, {cancel}) async => route,
        );
        await (await request.close()).drain<void>();
      }
      expect(ports, hasLength(3));
      expect(ports.last, isNot(ports.first));
      expect(ports[2], ports[1]);
    } finally {
      client.close(force: true);
      for (final socket in sockets) {
        socket.destroy();
      }
      await origin.close(force: true);
      await proxy.close();
    }
  });

  test(
    'closing a source cancels pending proxy lookup before a late connection',
    () async {
      final started = Completer<void>();
      final lookup = Completer<String?>();
      late CancelToken lookupCancel;
      final source = HttpSource(
        'http://source.unresolvable.invalid/video.mp4',
        proxyResolver: (uri, {cancel}) async {
          lookupCancel = cancel!;
          started.complete();
          return await Future.any([
            lookup.future,
            cancel.whenCancelled.then<String?>((_) => throw const Cancelled()),
          ]);
        },
      );
      final pending = expectLater(source.stat(''), throwsA(isA<Cancelled>()));
      await started.future;
      await source.close();
      await pending;
      expect(lookupCancel.cancelled, isTrue);
      lookup.complete('DIRECT');
    },
  );

  test(
    'artwork redirect resolves each destination through its own proxy',
    () async {
      final directory = await Directory.systemTemp.createTemp('proxy-artwork-');
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final png = await File('assets/branding/app_icon.png').readAsBytes();
      final hosts = <String>[];
      proxy.listen((request) async {
        hosts.add(request.uri.host);
        if (request.uri.host == 'first.unresolvable.invalid') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://second.unresolvable.invalid/cover.png',
          );
        } else {
          request.response.add(png);
        }
        await request.response.close();
      });
      final targets = <String>[];
      final cache = PosterCache(
        directory: directory,
        createClient: _client,
        proxyResolver: (uri, {cancel}) async {
          targets.add(uri.host);
          return 'PROXY 127.0.0.1:${proxy.port}';
        },
      );
      try {
        final file = await cache.load(
          'http://first.unresolvable.invalid/cover',
        );
        expect(file, isNotNull);
        expect(targets, [
          'first.unresolvable.invalid',
          'second.unresolvable.invalid',
        ]);
        expect(hosts, targets);
      } finally {
        cache.close();
        await proxy.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'paused artwork cancels proxy work without frames and resumes once',
    () async {
      final directory = await Directory.systemTemp.createTemp('proxy-paused-');
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final png = await File('assets/branding/app_icon.png').readAsBytes();
      var requests = 0, lookups = 0;
      proxy.listen((request) async {
        requests++;
        request.response.add(png);
        await request.response.close();
      });
      final firstStarted = Completer<void>();
      late CancelToken firstCancel;
      final cache = PosterCache(
        directory: directory,
        createClient: _client,
        proxyResolver: (uri, {cancel}) async {
          if (++lookups == 1) {
            firstCancel = cancel!;
            firstStarted.complete();
            await cancel.whenCancelled;
            cancel.check();
          }
          return 'PROXY 127.0.0.1:${proxy.port}';
        },
      );
      try {
        final pending = cache.load('http://poster.unresolvable.invalid/cover');
        await firstStarted.future;
        cache.setActive(false);
        expect(firstCancel.cancelled, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(lookups, 1);
        expect(requests, 0);
        cache.setActive(true);
        expect(await pending, isNotNull);
        expect(lookups, 2);
        expect(requests, 1);
      } finally {
        cache.close();
        await proxy.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
