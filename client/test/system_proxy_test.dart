import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/core/system_proxy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = SystemProxyResolver.channel;
  final uri = Uri.parse(
    'https://private:password@api.bgm.tv/v0/subjects/611077?lang=zh#private',
  );
  late List<MethodCall> calls;
  late SystemProxyResolver resolver;

  setUp(() {
    calls = [];
    resolver = SystemProxyResolver(operatingSystem: 'android');
  });
  tearDown(() {
    resolver.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Android resolves full PAC target with credentials and fragment removed',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return 'PROXY 127.0.0.1:7890; DIRECT';
      });
      expect(await resolver.resolve(uri), 'PROXY 127.0.0.1:7890; DIRECT');
      expect(calls.single.method, 'resolve');
      expect(
        calls.single.arguments['url'],
        'https://api.bgm.tv/v0/subjects/611077?lang=zh',
      );
      expect(calls.single.arguments['id'], isA<String>());
    },
  );

  test(
    'network/PAC changes are read for each URL without stale cache or polling',
    () async {
      var proxy = 'PROXY proxy.example:8080';
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return proxy;
      });
      expect(await resolver.resolve(uri), proxy);
      proxy = 'DIRECT';
      expect(await resolver.resolve(uri), 'DIRECT');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, hasLength(2));
      expect(calls.first.arguments['id'], isNot(calls.last.arguments['id']));
    },
  );

  for (final platform in ['android', 'macos', 'ios', 'windows', 'linux']) {
    test(
      '$platform resolves OS routes and fails closed without its plugin',
      () async {
        final host = SystemProxyResolver(operatingSystem: platform);
        addTearDown(host.dispose);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          return 'PROXY localhost:7890';
        });
        expect(await host.resolve(uri), 'PROXY localhost:7890');
        expect(
          calls.single.arguments['url'],
          'https://api.bgm.tv/v0/subjects/611077?lang=zh',
        );
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await expectLater(host.resolve(uri), throwsA(isA<AppFailure>()));
      },
    );
  }

  test(
    'only Linux may explicitly defer to current environment settings',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      for (final platform in ['android', 'macos', 'ios', 'windows', 'linux']) {
        final host = SystemProxyResolver(operatingSystem: platform);
        addTearDown(host.dispose);
        if (platform == 'linux') {
          expect(
            await host.resolve(uri),
            HttpClient.findProxyFromEnvironment(uri),
          );
        } else {
          await expectLater(host.resolve(uri), throwsA(isA<AppFailure>()));
        }
      }
    },
  );

  test(
    'worker startup carries the selected proxy policy across isolates',
    () async {
      final configuration = SystemProxyWorkerConfiguration.capture();
      final result = await Isolate.run(() async {
        initializeSystemProxyWorker(configuration);
        return resolveSystemProxy(Uri.parse('https://worker.example/video'));
      });
      // Unit tests deliberately select a host without a native runner. Native
      // integration tests exercise the same startup with the real OS token.
      expect(configuration.operatingSystem, 'unit-test');
      expect(result, isNull);
    },
  );

  test(
    'unsupported hosts and non-HTTP transports do not invoke the platform',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return 'DIRECT';
      });
      final desktop = SystemProxyResolver(operatingSystem: 'unsupported');
      expect(await desktop.resolve(uri), isNull);
      expect(await resolver.resolve(Uri.parse('file:///private.mkv')), isNull);
      expect(calls, isEmpty);
      desktop.dispose();
    },
  );

  test(
    'ordered IPv6 and HTTP proxy routes are accepted for HTTPS CONNECT',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => 'PROXY [::1]:7890; PROXY proxy.example:3128; DIRECT',
      );
      expect(
        await resolver.resolve(uri),
        'PROXY [::1]:7890; PROXY proxy.example:3128; DIRECT',
      );
    },
  );

  test(
    'timeout removes native queued work and ignores a late result',
    () async {
      final response = Completer<String>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'resolve' ? response.future : null;
      });
      await expectLater(
        resolver.resolve(uri, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((call) => call.method), ['resolve', 'cancel']);
      expect(calls.first.arguments['id'], calls.last.arguments['id']);
      response.complete('PROXY late.example:8080');
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(2));
    },
  );

  test(
    'native PAC deadline remains a timeout for transport diagnostics',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'proxy_timeout'),
      );
      await expectLater(
        resolver.resolve(uri),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'cancel and dispose immediately cancel native work without requiring a frame',
    () async {
      for (final dispose in [false, true]) {
        calls.clear();
        final response = Completer<String>();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          return call.method == 'resolve' ? response.future : null;
        });
        final cancel = CancelToken();
        final pending = expectLater(
          resolver.resolve(uri, cancel: cancel),
          throwsA(isA<Cancelled>()),
        );
        if (dispose) {
          resolver.dispose();
        } else {
          cancel.cancel();
        }
        await pending;
        await Future<void>.delayed(Duration.zero);
        expect(calls.map((call) => call.method), ['resolve', 'cancel']);
        response.complete('DIRECT');
        await Future<void>.delayed(Duration.zero);
        expect(calls, hasLength(2));
      }
    },
  );

  test(
    'malformed or unsupported proxy settings fail instead of silently connecting direct',
    () async {
      for (final value in [
        '',
        'SOCKS private:8080',
        'PROXY user:password@private:8080',
        'PROXY private:0',
        'PROXY private:70000',
        'PROXY private:8080/path',
        'PROXY private:8080\nDIRECT',
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => value,
        );
        await expectLater(
          resolver.resolve(uri),
          throwsA(
            isA<AppFailure>().having(
              (error) => error.message,
              'safe message',
              isNot(contains('private')),
            ),
          ),
        );
      }
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'proxy_unsupported',
          message: 'private configuration',
        ),
      );
      await expectLater(
        resolver.resolve(uri),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'safe actionable message',
            '系统代理类型暂不支持，请使用 HTTP 代理。',
          ),
        ),
      );
    },
  );

  test(
    'pending requests are bounded and request ids do not collide across resolver instances',
    () async {
      final responses = <Completer<String>>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'cancel') return null;
        final response = Completer<String>();
        responses.add(response);
        return response.future;
      });
      final pending = [
        for (var index = 0; index < 32; index++) resolver.resolve(uri),
      ];
      await expectLater(
        resolver.resolve(uri),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'busy',
            contains('繁忙'),
          ),
        ),
      );
      final second = SystemProxyResolver(operatingSystem: 'android');
      final other = second.resolve(uri);
      await Future<void>.delayed(Duration.zero);
      final ids = calls
          .where((call) => call.method == 'resolve')
          .map((call) => call.arguments['id'])
          .toList();
      expect(ids.toSet(), hasLength(33));
      for (final response in responses) {
        response.complete('DIRECT');
      }
      expect(await Future.wait([...pending, other]), everyElement('DIRECT'));
      second.dispose();
    },
  );
}
