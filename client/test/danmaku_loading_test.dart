import 'dart:async';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class LoadingTransport implements JsonTransport {
  final Future<Map<String, dynamic>> Function(Uri) handle;
  final paths = <String>[];
  LoadingTransport(this.handle);

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) {
    paths.add(uri.path);
    return handle(uri);
  }
}

const snapshot = {
  'comments': [
    {'time': 1, 'text': 'ready'},
  ],
};

Map<String, dynamic> searchResult(String id) => {
  'animes': [
    {
      'animeTitle': '作品',
      'episodes': [
        {'episodeId': id, 'episodeTitle': '第一集'},
      ],
    },
  ],
};

Map<String, dynamic> matchedResult(String id) => {
  'isMatched': true,
  'matches': [
    {'episodeId': id, 'animeTitle': '作品', 'episodeTitle': '第一集'},
  ],
};

void main() {
  for (final operation in ['search', 'match', 'comment']) {
    test('$operation 404 preserves status and provides safe context', () async {
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture-secret',
        transport: LoadingTransport((_) async {
          throw const AppFailure('https://private/fixture-secret', 404);
        }),
      );
      final request = switch (operation) {
        'search' => api.search('作品'),
        'match' => api.match('作品'),
        _ => api.comments('1'),
      };
      await expectLater(
        request,
        throwsA(
          isA<AppFailure>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', contains('HTTP 404'))
              .having(
                (e) => e.message,
                'secret',
                isNot(contains('fixture-secret')),
              )
              .having((e) => e.message, 'URL', isNot(contains('https://')))
              .having(
                (e) => e.message,
                'operation',
                contains(switch (operation) {
                  'search' => '搜索',
                  'match' => '匹配',
                  _ => '剧集',
                }),
              ),
        ),
      );
    });
  }

  test(
    'missing saved episode is rematched without retrying the old ID',
    () async {
      final store = AppStore(':memory:');
      final transport = LoadingTransport((uri) async {
        if (uri.path.endsWith('/1')) throw const AppFailure('missing', 404);
        if (uri.path.endsWith('search/episodes')) return searchResult('1');
        if (uri.path.endsWith('match')) return matchedResult('2');
        return snapshot;
      });
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: transport,
      );
      store.save('match', 'video', {
        'provider': api.origin.origin,
        'episodeId': '1',
        'label': '旧匹配',
        'offset': 2.5,
      });
      final session = DanmakuSession(store, api, 'video');
      addTearDown(store.dispose);
      addTearDown(session.dispose);

      await session.identify(const ReleaseName('作品', '', '1'));

      expect(session.episodeId, '2');
      expect(session.comments.single.text, 'ready');
      expect(session.offset, 2.5);
      expect(session.error, isEmpty);
      expect(session.busy, isFalse);
      expect(store.get('match', 'video')!.data['episodeId'], '2');
      expect(transport.paths.map((path) => path.split('/api/v2/').last), [
        'comment/1',
        'search/episodes',
        'match',
        'comment/2',
      ]);
    },
  );

  test(
    'missing unique search result falls back to filename matching',
    () async {
      final store = AppStore(':memory:');
      final transport = LoadingTransport((uri) async {
        if (uri.path.endsWith('/1')) throw const AppFailure('missing', 404);
        if (uri.path.endsWith('search/episodes')) return searchResult('1');
        if (uri.path.endsWith('match')) return matchedResult('2');
        return snapshot;
      });
      final session = DanmakuSession(
        store,
        DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: transport,
        ),
        'video',
      );
      addTearDown(store.dispose);
      addTearDown(session.dispose);

      await session.identify(const ReleaseName('作品', '', '1'));

      expect(session.episodeId, '2');
      expect(session.error, isEmpty);
      expect(transport.paths.length, 4);
    },
  );

  test(
    'the same missing result is not downloaded again after matching',
    () async {
      final store = AppStore(':memory:');
      final transport = LoadingTransport((uri) async {
        if (uri.path.endsWith('search/episodes')) return searchResult('1');
        if (uri.path.endsWith('match')) return matchedResult('1');
        throw const AppFailure('missing', 404);
      });
      final session = DanmakuSession(
        store,
        DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: transport,
        ),
        'video',
      );
      addTearDown(store.dispose);
      addTearDown(session.dispose);

      await session.identify(const ReleaseName('作品', '', '1'));

      expect(session.episodeId, isNull);
      expect(session.candidates, isEmpty);
      expect(session.error, contains('HTTP 404'));
      expect(session.busy, isFalse);
      expect(transport.paths.length, 3);
    },
  );

  test('valid unique search avoids the filename matching request', () async {
    final store = AppStore(':memory:');
    final transport = LoadingTransport((uri) async {
      if (uri.path.endsWith('search/episodes')) return searchResult('1');
      return snapshot;
    });
    final session = DanmakuSession(
      store,
      DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: transport,
      ),
      'video',
    );
    addTearDown(store.dispose);
    addTearDown(session.dispose);

    await session.identify(const ReleaseName('作品', '', '1'));

    expect(session.episodeId, '1');
    expect(transport.paths.length, 2);
    expect(transport.paths.any((path) => path.endsWith('match')), isFalse);
  });

  test(
    'superseded rematching cannot replace a newer selected episode',
    () async {
      final store = AppStore(':memory:');
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final transport = LoadingTransport((uri) async {
        if (uri.path.endsWith('search/episodes')) return searchResult('1');
        if (uri.path.endsWith('/1')) throw const AppFailure('missing', 404);
        if (uri.path.endsWith('match')) {
          started.complete();
          return pending.future;
        }
        return snapshot;
      });
      final session = DanmakuSession(
        store,
        DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: transport,
        ),
        'video',
      );
      addTearDown(store.dispose);
      addTearDown(session.dispose);
      final identifying = session.identify(const ReleaseName('作品', '', '1'));
      await started.future;
      await session.select(const EpisodeMatch('3', '新作品', ''));
      pending.complete(matchedResult('2'));
      await identifying;

      expect(session.episodeId, '3');
      expect(transport.paths.any((path) => path.endsWith('/2')), isFalse);
      expect(session.error, isEmpty);
    },
  );

  for (final cache in ['{broken', '[{"time":-1,"text":"invalid"}]']) {
    test('unusable comment cache fetches a new snapshot: $cache', () async {
      final store = AppStore(':memory:');
      final transport = LoadingTransport((_) async => snapshot);
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: transport,
      );
      store.cacheJson(api.cacheKey('1'), cache);
      final session = DanmakuSession(store, api, 'video');
      addTearDown(store.dispose);
      addTearDown(session.dispose);

      await session.select(const EpisodeMatch('1', '作品', ''));

      expect(session.comments.single.text, 'ready');
      expect(session.error, isEmpty);
      expect(transport.paths.length, 1);
    });
  }

  test(
    'play state changes cannot refresh the old episode during rematching',
    () {
      fakeAsync((time) {
        final store = AppStore(':memory:');
        final search = Completer<Map<String, dynamic>>();
        var oldDownloads = 0, newDownloads = 0;
        final api = DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: LoadingTransport((uri) async {
            if (uri.path.endsWith('search/episodes')) return search.future;
            if (uri.path.endsWith('/1')) {
              oldDownloads++;
              if (oldDownloads > 1) throw const AppFailure('old episode', 404);
            } else if (uri.path.endsWith('/2')) {
              newDownloads++;
            }
            return snapshot;
          }),
        );
        final session = DanmakuSession(store, api, 'video');
        session.select(const EpisodeMatch('1', '旧匹配', ''));
        time.flushMicrotasks();
        session.identify(const ReleaseName('作品', '', '1'), restore: false);
        time.flushMicrotasks();
        expect(session.busy, isTrue);

        session.configure(isPlaying: true);
        time.elapse(const Duration(seconds: 30));
        session.refresh();
        time.flushMicrotasks();
        expect(oldDownloads, 1);
        expect(session.error, isEmpty);

        search.complete(searchResult('2'));
        time.flushMicrotasks();
        expect(session.episodeId, '2');
        expect(session.busy, isFalse);
        expect(newDownloads, 1);
        time.elapse(const Duration(seconds: 30));
        expect(newDownloads, 2);
        expect(session.error, isEmpty);
        session.dispose();
        store.dispose();
      });
    },
  );

  test('first snapshot is visible before its cache is persisted', () async {
    final store = AppStore(':memory:');
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: LoadingTransport((_) async => snapshot),
    );
    final session = DanmakuSession(store, api, 'video');
    addTearDown(store.dispose);
    addTearDown(session.dispose);
    var displayedBeforeCache = false;
    session.addListener(() {
      if (session.comments.isNotEmpty && !session.busy) {
        displayedBeforeCache = store.cachedJson(api.cacheKey('1')) == null;
      }
    });

    await session.select(const EpisodeMatch('1', '作品', ''));

    expect(displayedBeforeCache, isTrue);
    expect(store.cachedJson(api.cacheKey('1')), isNotNull);
  });

  test('saved nonempty comments load without a network request', () async {
    final store = AppStore(':memory:');
    final transport = LoadingTransport((_) async {
      throw StateError('cached opening must work offline');
    });
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: transport,
    );
    store.cacheJson(api.cacheKey('1'), '[{"time":1,"text":"cached"}]');
    final session = DanmakuSession(store, api, 'video');
    addTearDown(store.dispose);
    addTearDown(session.dispose);

    await session.select(const EpisodeMatch('1', '作品', ''));

    expect(session.comments.single.text, 'cached');
    expect(session.busy, isFalse);
    expect(transport.paths, isEmpty);
  });

  test(
    '404 refresh keeps comments, backs off and clears errors on recovery',
    () {
      fakeAsync((time) {
        final store = AppStore(':memory:');
        var calls = 0;
        final api = DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: LoadingTransport((_) async {
            calls++;
            if (calls == 2) throw const AppFailure('missing', 404);
            return snapshot;
          }),
        );
        final session = DanmakuSession(store, api, 'video');
        session.select(const EpisodeMatch('1', '作品', ''));
        time.flushMicrotasks();
        final original = session.comments;
        session.configure(isPlaying: true);
        time.elapse(const Duration(seconds: 30));
        expect(session.error, contains('HTTP 404'));
        expect(session.comments, same(original));
        time.elapse(const Duration(seconds: 299));
        expect(calls, 2);
        var notifiedError = 'not notified';
        session.addListener(() => notifiedError = session.error);
        time.elapse(const Duration(seconds: 1));
        expect(calls, 3);
        expect(session.comments, same(original));
        expect(session.error, isEmpty);
        expect(notifiedError, isEmpty);
        session.dispose();
        store.dispose();
      });
    },
  );
}
