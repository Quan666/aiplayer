import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/core/third_party_network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/tmdb_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingTransport implements JsonTransport {
  int requests = 0;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    requests++;
    return {'results': <dynamic>[]};
  }
}

class _NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _NetworkBinding();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'disabled service traffic never reaches HTTP, but source reads do',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/media.bin') {
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-3/4')
            ..contentLength = 4
            ..add([1, 2, 3, 4]);
        } else {
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true}));
        }
        await request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      final policy = ThirdPartyNetworkPolicy(enabled: false);
      final transport = policy.jsonTransport(
        transport: IoJsonTransport(
          proxyResolver: (_, {cancel}) async => 'DIRECT',
        ),
      );
      final source = HttpSource(
        base.toString(),
        webdav: true,
        proxyResolver: (_, {cancel}) async => 'DIRECT',
      );
      try {
        await expectLater(
          transport.send(base.resolve('/service')),
          throwsA(isA<AppFailure>()),
        );
        expect(requests, isEmpty);
        expect(
          await source.read('/media.bin', 0, 3).expand((v) => v).toList(),
          [1, 2, 3, 4],
        );
        expect(requests, ['/media.bin']);
        policy.setEnabled(true);
        expect(
          await transport.send(base.resolve('/service'), cancel: CancelToken()),
          {'ok': true},
        );
        expect(requests, ['/media.bin', '/service']);
      } finally {
        policy.dispose();
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'disabling cancels an in-flight HTTP request without replay on enable',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>();
      var requests = 0;
      server.listen((request) {
        requests++;
        entered.complete();
        // Hold the response until the policy closes the client's connection.
      });
      final policy = ThirdPartyNetworkPolicy();
      final transport = policy.jsonTransport(
        transport: IoJsonTransport(
          proxyResolver: (_, {cancel}) async => 'DIRECT',
        ),
      );
      try {
        final result = transport.send(
          Uri.parse('http://127.0.0.1:${server.port}/hold'),
        );
        final cancelled = expectLater(result, throwsA(isA<Cancelled>()));
        await entered.future;
        policy.setEnabled(false);
        policy.setEnabled(true);
        await cancelled;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(requests, 1);
      } finally {
        policy.dispose();
        await server.close(force: true);
      }
    },
  );

  test('AI model listing and completion reject absent keys before creating HTTP clients', () async {
    var clients = 0;
    final ai = IoSubtitleAiTransport(
      createClient: () {
        clients++;
        return HttpClient();
      },
    );
    for (final key in ['', '   ']) {
      final config = SubtitleAiConfig(token: key, model: 'test-model');
      await expectLater(
        ai.models(config, CancelToken()),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(
        ai.complete(config, {}, CancelToken()),
        throwsA(isA<AppFailure>()),
      );
    }
    expect(clients, 0);
    final transport = _CountingTransport();
    final tmdb = TmdbCatalog(transport, () async => '');
    await expectLater(tmdb.search('Example'), throwsA(isA<AppFailure>()));
    expect(transport.requests, 0);
    var credentialReads = 0;
    final revoked = TmdbCatalog(
      transport,
      () async => credentialReads++ == 0 ? 'removed-key' : '',
    );
    await expectLater(revoked.search('Example'), throwsA(isA<AppFailure>()));
    expect(transport.requests, 0);
    expect(
      () => DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        '',
        transport: transport,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(transport.requests, 0);
  });

  test(
    'model switch gates manual providers, persists, and accepts synced changes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'service-policy-',
      );
      final store = AppStore(':memory:');
      final model = AppModel(store, directory, backgroundWork: false);
      try {
        expect(AppPreferences({}).thirdPartyNetworkingEnabled, isTrue);
        await model.secrets.write(key: 'danmuToken', value: 'configured-token');
        final api = await model.danmu();
        expect(api, isNotNull);
        await model.updatePreferences({'thirdPartyNetworkingEnabled': false});
        expect(model.thirdPartyNetwork.enabled, isFalse);
        expect(store.local('settings')['thirdPartyNetworkingEnabled'], isFalse);
        expect(await model.danmu(), isNull);
        await model.resetPreferences();
        expect(model.thirdPartyNetwork.enabled, isFalse);
        await expectLater(
          model.searchBangumi('Example', source: 'bangumi'),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(api!.search('Example'), throwsA(isA<AppFailure>()));
        await expectLater(
          model.mediaAi.analyzeFilename(
            'Example.S01E01.mkv',
            config: SubtitleAiConfig(
              token: 'configured-key',
              model: 'test-model',
            ),
            cancel: CancelToken(),
          ),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(
          model.recognizeDirectory('local', directory.path),
          throwsA(isA<AppFailure>()),
        );
        store.setLocal('settings', {'thirdPartyNetworkingEnabled': true});
        model.changed();
        expect(model.thirdPartyNetwork.enabled, isTrue);
        await model.setSettings({}, danmuToken: '');
        expect(await model.danmu(), isNull);
        var clients = 0;
        await HttpOverrides.runZoned(
          () async {
            await expectLater(
              api.search('Example'),
              throwsA(isA<AppFailure>()),
            );
            await expectLater(
              model.thirdPartyAiTransport.models(
                SubtitleAiConfig(token: 'removed-key', model: 'test-model'),
                CancelToken(),
              ),
              throwsA(isA<AppFailure>()),
            );
          },
          createHttpClient: (_) {
            clients++;
            throw StateError('No service client should be created');
          },
        );
        expect(clients, 0);
      } finally {
        model.dispose();
        await model.flushMetadataTasks();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('settings exposes one persisted third-party service switch', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('service-setting-'),
    ))!;
    final store = AppStore(':memory:');
    final model = AppModel(store, directory, backgroundWork: false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(body: SettingsPage(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      final setting = find.text('第三方服务联网');
      expect(setting, findsOneWidget);
      await tester.ensureVisible(setting);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(model.preferences.thirdPartyNetworkingEnabled, isFalse);
      expect(model.thirdPartyNetwork.enabled, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.runAsync(model.flushMetadataTasks);
      store.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  test('unrelated worker commits do not revoke service requests', () async {
    final directory = await Directory.systemTemp.createTemp(
      'service-revision-',
    );
    final store = await AppStore.open('${directory.path}/library.db');
    final worker = AppStore.openExisting(store.path);
    final model = AppModel(store, directory, backgroundWork: false);
    CancelToken? request;
    final pending = model.thirdPartyNetwork.run<void>((token) {
      request = token;
      return token.whenCancelled.then((_) => throw const Cancelled());
    });
    final cancelled = expectLater(pending, throwsA(isA<Cancelled>()));
    try {
      worker.setLocal('sync:cursor', 7);
      model.changed();
      expect(request!.cancelled, isFalse);
      worker.setLocal('unrelated:cache', {'value': 1});
      model.changed();
      expect(request!.cancelled, isFalse);
      worker.markLocalModified('secret:aiSubtitleToken');
      model.changed();
      await cancelled;
      expect(request!.cancelled, isTrue);
    } finally {
      model.dispose();
      await model.flushMetadataTasks();
      worker.dispose();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
}
