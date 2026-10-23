import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/catalog_cache.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  final FutureOr<Map<String, dynamic>> Function(Uri) reply;
  final calls = <Uri>[];
  _Transport(this.reply);
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    calls.add(uri);
    // Deliberately ignore cancellation to exercise stale-response guards.
    return reply(uri);
  }
}

const _bgm = {
  'id': 7,
  'type': 2,
  'name': 'Example',
  'name_cn': 'Example',
  'platform': 'TV',
};
const _tv = {'id': 7, 'name': 'Example', 'original_name': 'Example'};
Map<String, dynamic> _reply(Uri uri) {
  if (uri.path.startsWith('/search/subject/')) {
    return {
      'list': [_bgm],
    };
  }
  if (uri.path == '/3/search/tv') {
    return {
      'results': [_tv],
    };
  }
  if (uri.path == '/3/search/movie') return {'results': []};
  if (uri.path == '/v0/episodes') {
    return {
      'data': [
        {'sort': 1, 'name_cn': 'Start'},
      ],
    };
  }
  if (uri.path.contains('/season/')) {
    return {
      'season_number': int.parse(uri.pathSegments.last),
      'episodes': [
        {'episode_number': 1, 'name': 'Start'},
      ],
    };
  }
  return uri.host == 'api.bgm.tv' ? _bgm : _tv;
}

void main() {
  late Directory directory;
  late AppStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('catalog-cache-');
    store = AppStore('${directory.path}/store.db');
  });
  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });
  LibraryCatalog catalog(
    _Transport transport, {
    String Function()? credential,
  }) => LibraryCatalog(
    store,
    transport: transport,
    tmdbCredential: () async => credential?.call() ?? 'read-token',
  );

  test(
    'successful search, details, seasons, names and forced recognition survive database restart',
    () async {
      final online = _Transport(_reply);
      final first = catalog(online);
      expect(await first.search('Example'), hasLength(2));
      final calls = online.calls.length;
      expect(await first.search('Example'), hasLength(2));
      expect(
        online.calls,
        hasLength(calls),
        reason: 'A complete merged search also reuses its empty movie branch',
      );
      expect((await first.resolve('Example', '1'))?['provider'], 'bangumi');
      await Future.wait(List.generate(8, (_) => first.details(_bgm)));
      await Future.wait(List.generate(8, (_) => first.episodeNames('7')));
      expect(
        online.calls.where((uri) => uri.path == '/v0/subjects/7'),
        hasLength(1),
      );
      expect(
        online.calls.where((uri) => uri.path == '/v0/episodes'),
        hasLength(1),
      );
      await first.details({
        'provider': 'tmdb',
        'id': 7,
        'mediaType': 'tv',
      }, season: '2');
      for (final row in store.localEntries('subject-v5:').entries) {
        store.setLocal(row.key, {...row.value as Map, 'at': 0});
      }
      store.dispose();
      store = AppStore('${directory.path}/store.db');
      final offline = _Transport((_) => throw const AppFailure('Offline'));
      final restored = catalog(offline);
      expect(await restored.search('Example'), hasLength(2));
      expect((await restored.details(_bgm))['id'], 7);
      expect(await restored.episodeNames('7'), {'1': 'Start'});
      expect(
        (await restored.details({
          'provider': 'tmdb',
          'id': 7,
          'mediaType': 'tv',
        }, season: '2'))['season'],
        '2',
      );
      expect((await restored.resolve('Example', '1', force: true))?['id'], 7);
      final disabled = LibraryCatalog(
        store,
        transport: offline,
        strategy: () => 'off',
        tmdbCredential: () async => 'read-token',
      );
      expect(await disabled.resolve('Example', '1'), isNull);
      expect((await disabled.resolve('Example', '1', force: true))?['id'], 7);
      expect(offline.calls, isEmpty);
      restored.invalidateMetadataCaches();
      final refreshed = catalog(_Transport(_reply));
      expect((await refreshed.resolve('Example', '1'))?['id'], 7);
    },
  );

  test(
    'concurrent details share one request and one cancelled reader does not cancel the other',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final transport = _Transport((_) => gate.future);
      final model = catalog(transport);
      final cancelled = CancelToken();
      final first = model.details(_bgm, cancel: cancelled);
      final rejected = expectLater(first, throwsA(isA<Cancelled>()));
      final second = model.details(_bgm, cancel: CancelToken());
      cancelled.cancel();
      await rejected;
      gate.complete(_bgm);
      expect((await second)['id'], 7);
      expect(transport.calls, hasLength(1));
      expect((await model.details(_bgm))['id'], 7);
      expect(transport.calls, hasLength(1));
    },
  );

  test(
    'all cancelled readers and explicit refresh cannot persist late shared results',
    () async {
      for (final refresh in [false, true]) {
        final gate = Completer<Map<String, dynamic>>();
        final cache = CatalogCache(store);
        final token = CancelToken();
        final pending = cache.load<Map<String, dynamic>>(
          'catalog-v1:test:$refresh',
          fetch: (_) => gate.future,
          decode: (value) => Map<String, dynamic>.from(value as Map),
          keep: (value) => value.isNotEmpty,
          cancel: token,
        );
        final rejected = expectLater(pending, throwsA(isA<Cancelled>()));
        if (refresh) {
          cache.invalidate();
        } else {
          token.cancel();
        }
        gate.complete({'id': 1});
        await rejected;
        await Future<void>.delayed(Duration.zero);
        expect(store.local('catalog-v1:test:$refresh'), isNull);
      }
    },
  );

  test(
    'empty and failed searches retry, partial success does not hide recovered sources',
    () async {
      var ready = false;
      final transport = _Transport((uri) {
        if (!ready) {
          if (uri.host == 'api.bgm.tv') throw const AppFailure('Offline');
          return _reply(uri);
        }
        return _reply(uri);
      });
      final model = catalog(transport);
      expect((await model.search('Example')).single['provider'], 'tmdb');
      ready = true;
      expect(await model.search('Example'), hasLength(2));
      model.invalidateMetadataCaches();
      var populated = false;
      final retry = catalog(
        _Transport(
          (uri) => populated
              ? _reply(uri)
              : uri.path.startsWith('/search/subject/')
              ? {'list': []}
              : uri.path == '/v0/episodes'
              ? {'data': []}
              : {'results': []},
        ),
      );
      expect(await retry.search('Example'), isEmpty);
      expect(await retry.resolve('Example', '1'), isNull);
      expect(await retry.episodeNames('7'), isEmpty);
      populated = true;
      expect(await retry.search('Example'), hasLength(2));
      expect((await retry.resolve('Example', '1'))?['id'], 7);
      expect(await retry.episodeNames('7'), {'1': 'Start'});
    },
  );

  test(
    'adding or changing TMDB credentials cannot reuse incomplete or different credential searches',
    () async {
      var credential = '';
      final transport = _Transport(_reply);
      final model = catalog(transport, credential: () => credential);
      expect((await model.search('Example')).single['provider'], 'bangumi');
      credential = 'first-private-token';
      expect(await model.search('Example'), hasLength(2));
      final requests = transport.calls.length;
      credential = 'second-private-token';
      expect(await model.search('Example'), hasLength(2));
      expect(transport.calls.length, greaterThan(requests));
      expect(
        store.localEntries('catalog-v1:').toString(),
        isNot(contains('private-token')),
      );
    },
  );

  test(
    'directory metadata keeps more than 256 previews and unresolved previews retry',
    () async {
      final model = catalog(_Transport(_reply));
      List<SourceEntry> entries(String path) => [
        for (var episode = 1; episode <= 2; episode++)
          SourceEntry(
            name: 'Example S01E0$episode.mkv',
            path: '$path/$episode.mkv',
          ),
      ];
      for (var i = 0; i < 260; i++) {
        expect(
          (await model.inspect('nas', '$i', entries('$i')))?.subject,
          isNotNull,
        );
      }
      expect(store.localEntries('directory-preview:'), hasLength(260));
      final restored = catalog(
        _Transport((_) => throw const AppFailure('Offline')),
      );
      expect(
        restored.directoryPreview('nas', '0')?.collection?.subject,
        isNotNull,
      );
      model.invalidateMetadataCaches();
      var ready = false;
      final retryTransport = _Transport(
        (uri) => ready ? _reply(uri) : {'list': []},
      );
      final retry = LibraryCatalog(store, transport: retryTransport);
      expect((await retry.inspect('nas', 'x', entries('x')))?.subject, isNull);
      expect(retry.directoryPreview('nas', 'x'), isNull);
      ready = true;
      expect(
        (await retry.inspect('nas', 'x', entries('x')))?.subject,
        isNotNull,
        reason:
            '${retryTransport.calls}\n${store.localEntries('catalog-v1:')}\n${store.localEntries('subject-v5:')}',
      );
    },
  );
}
