import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

const _candidate = <String, dynamic>{
  'id': 7,
  'type': 2,
  'provider': 'bangumi',
  'name': 'Example',
  'name_cn': '示例',
  'summary': 'Search synopsis',
  'air_date': '2025-01-01',
  'eps_count': 12,
  'images': {'large': 'https://example.test/poster.jpg'},
};

class _Transport implements JsonTransport {
  _Transport(this.reply);
  FutureOr<Map<String, dynamic>> Function(Uri, CancelToken?) reply;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    calls++;
    return reply(uri, cancel);
  }
}

class _HttpTransport implements JsonTransport {
  _HttpTransport(this.port);
  final int port;
  final _transport = IoJsonTransport(
    inactivity: const Duration(milliseconds: 200),
  );

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) => _transport.send(
    uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
    method: method,
    body: body,
    headers: headers,
    cancel: cancel,
  );
}

void main() {
  late AppStore store;
  setUp(() => store = AppStore(':memory:'));
  tearDown(() => store.dispose());

  test(
    'an accepted legacy search candidate remains usable after HTTP timeout',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final candidate = Map<String, dynamic>.of(_candidate)..remove('type');
      server.listen((request) async {
        if (request.uri.path.startsWith('/search/subject/')) {
          request.response.write(
            jsonEncode({
              'list': [candidate],
            }),
          );
          await request.response.close();
        }
        // Leave the detail response pending to exercise the production timeout.
      });
      final catalog = LibraryCatalog(
        store,
        transport: _HttpTransport(server.port),
      );
      final found = await catalog.search('Example', source: 'bangumi');
      expect(found, hasLength(1));
      final selected = await catalog.selectionDetails(found.single);
      expect(selected['id'], 7);
      expect(selected['summary'], 'Search synopsis');
      expect(store.local('catalog-v1:bangumi:details:7'), isNull);
    },
  );

  test(
    'manual Bangumi selection survives a detail timeout without caching it',
    () async {
      final transport = _Transport((_, _) {
        throw const NetworkUnavailable('服务长时间未收到数据，请重试。');
      });
      final catalog = LibraryCatalog(store, transport: transport);
      var fallbackCount = 0;
      final selected = await catalog.selectionDetails(
        _candidate,
        season: '1',
        onFallback: () => fallbackCount++,
      );
      expect(selected['id'], 7);
      expect(selected['summary'], 'Search synopsis');
      expect(selected['date'], '2025-01-01');
      expect(selected['total_episodes'], 12);
      expect(selected['images'], _candidate['images']);
      expect(store.local('catalog-v1:bangumi:details:7'), isNull);
      expect(fallbackCount, 1);

      // Automatic identification must not silently accept partial detail data.
      await expectLater(
        catalog.details(_candidate),
        throwsA(isA<NetworkUnavailable>()),
      );
      transport.reply = (_, _) => {
        'id': 7,
        'type': 2,
        'name': 'Example',
        'summary': 'Full synopsis',
        'date': '2025-02-01',
        'total_episodes': 13,
      };
      final recovered = await catalog.selectionDetails(
        _candidate,
        onFallback: () => fallbackCount++,
      );
      expect(recovered['summary'], 'Full synopsis');
      expect(recovered['date'], '2025-02-01');
      expect(recovered['total_episodes'], 13);
      await catalog.selectionDetails(_candidate);
      expect(transport.calls, 3);
      expect(fallbackCount, 1);
    },
  );

  test(
    'manual selection tolerates temporary provider server failures',
    () async {
      final catalog = LibraryCatalog(
        store,
        transport: _Transport(
          (_, _) => throw const AppFailure('Unavailable', 503),
        ),
      );
      expect((await catalog.selectionDetails(_candidate))['id'], 7);
    },
  );

  test(
    'manual selection preserves authorization and malformed-response errors',
    () async {
      for (final failure in [
        const AppFailure('Unauthorized', 401),
        const AppFailure('Forbidden', 403),
        const AppFailure('Not found', 404),
        const AppFailure('Invalid JSON'),
      ]) {
        final catalog = LibraryCatalog(
          store,
          transport: _Transport((_, _) => throw failure),
        );
        await expectLater(
          catalog.selectionDetails(_candidate),
          throwsA(same(failure)),
        );
      }
    },
  );

  test(
    'wrong detail identity or type is never replaced by the candidate',
    () async {
      for (final response in [
        {..._candidate, 'id': 8},
        {..._candidate, 'type': 1},
      ]) {
        final catalog = LibraryCatalog(
          store,
          transport: _Transport((_, _) => response),
        );
        await expectLater(
          catalog.selectionDetails(_candidate),
          throwsA(
            isA<AppFailure>().having(
              (error) => error.message,
              'message',
              contains('编号或类型不一致'),
            ),
          ),
        );
      }
    },
  );

  test(
    'partial or wrong-provider candidates do not qualify for fallback',
    () async {
      for (final candidate in [
        {'id': 7, 'provider': 'bangumi', 'type': 2},
        {..._candidate, 'type': 1},
        {..._candidate, 'provider': 'tmdb', 'mediaType': 'movie'},
      ]) {
        final catalog = LibraryCatalog(
          store,
          tmdbCredential: () async => 'read-token',
          transport: _Transport((_, _) {
            throw const NetworkUnavailable('Offline');
          }),
        );
        await expectLater(
          catalog.selectionDetails(candidate),
          throwsA(isA<NetworkUnavailable>()),
        );
      }
    },
  );

  test(
    'cancelling an unavailable request cannot apply its search candidate',
    () async {
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      final catalog = LibraryCatalog(
        store,
        transport: _Transport((_, _) {
          started.complete();
          return response.future;
        }),
      );
      final cancel = CancelToken();
      var usedFallback = false;
      final selected = catalog.selectionDetails(
        _candidate,
        cancel: cancel,
        onFallback: () => usedFallback = true,
      );
      final assertion = expectLater(selected, throwsA(isA<Cancelled>()));
      await started.future;
      cancel.cancel();
      response.completeError(const NetworkUnavailable('Offline'));
      await assertion;
      expect(store.local('catalog-v1:bangumi:details:7'), isNull);
      expect(usedFallback, isFalse);
    },
  );

  test(
    'Bangumi timeout errors retain request phase and endpoint context',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((_) {});
      final catalog = LibraryCatalog(
        store,
        transport: _HttpTransport(server.port),
      );
      for (final operation in <String, Future<Object?> Function()>{
        '搜索': () => catalog.search('Secret fixture title', source: 'bangumi'),
        '作品详情': () => catalog.details(_candidate),
        '分集信息': () => catalog.episodeNames('7', subject: _candidate),
      }.entries) {
        await expectLater(
          operation.value(),
          throwsA(
            isA<NetworkUnavailable>()
                .having(
                  (error) => error.message,
                  'operation',
                  startsWith('Bangumi ${operation.key}：'),
                )
                .having(
                  (error) => error.diagnostic?.phase,
                  'phase',
                  NetworkPhase.responseHeaders,
                )
                .having(
                  (error) => error.diagnostic?.reason,
                  'reason',
                  NetworkFailureReason.timeout,
                ),
          ),
        );
        final log = AppLog.instance.entries.last;
        expect(log.scope, 'Bangumi ${operation.key}');
        expect(log.message, contains('阶段=responseHeaders'));
        expect(log.message, contains('原因=timeout'));
        expect(log.message, isNot(contains('Secret')));
        expect(log.message, isNot(contains('http')));
      }
    },
  );

  test(
    'shared detail timeout preserves fallback only for its active selection',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      var calls = 0;
      server.listen((_) {
        calls++;
        if (!started.isCompleted) started.complete();
      });
      final catalog = LibraryCatalog(
        store,
        transport: _HttpTransport(server.port),
      );
      final cancel = CancelToken();
      var firstFallback = false, secondFallback = false;
      final first = catalog.selectionDetails(
        _candidate,
        cancel: cancel,
        onFallback: () => firstFallback = true,
      );
      final firstAssertion = expectLater(first, throwsA(isA<Cancelled>()));
      final second = catalog.selectionDetails(
        _candidate,
        onFallback: () => secondFallback = true,
      );
      await started.future;
      cancel.cancel();
      await firstAssertion;
      expect((await second)['id'], 7);
      expect(firstFallback, isFalse);
      expect(secondFallback, isTrue);
      expect(calls, 1);
      expect(store.local('catalog-v1:bangumi:details:7'), isNull);
    },
  );
}
