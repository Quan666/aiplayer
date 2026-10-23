import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
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
    return reply(uri);
  }
}

const _subject = {'provider': 'tmdb', 'id': '7', 'mediaType': 'tv'};

Map<String, dynamic> _reply(Uri uri) {
  if (uri.path == '/3/tv/7') {
    return {'id': 7, 'name': 'Example', 'original_name': 'Example'};
  }
  final season = int.parse(uri.pathSegments.last);
  return {
    'season_number': season,
    'episodes': [
      {'episode_number': 1.0, 'name': 'Season $season: First'},
      {'episode_number': 2, 'name': 'Season $season: Second'},
    ],
  };
}

void main() {
  late Directory directory;
  late AppStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tmdb-series-cache-');
    store = AppStore('${directory.path}/store.db');
  });
  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  LibraryCatalog catalog(_Transport transport) => LibraryCatalog(
    store,
    transport: transport,
    tmdbCredential: () async => 'read-token',
  );

  test(
    'all episode readers share series and season requests and retain titles after restart',
    () async {
      final transport = _Transport(_reply);
      final first = catalog(transport);
      final results = await Future.wait([
        for (var episode = 1; episode <= 12; episode++)
          first.details(_subject, season: '2'),
        for (var episode = 1; episode <= 12; episode++)
          first.episodeNames('7', subject: {..._subject, 'season': '2'}),
      ]);
      final expected = {'1': 'Season 2: First', '2': 'Season 2: Second'};
      for (final result in results.take(12)) {
        expect(result['episodeNames'], expected);
      }
      for (final result in results.skip(12)) {
        expect(result, expected);
      }
      expect(
        transport.calls.where((uri) => uri.path == '/3/tv/7'),
        hasLength(1),
      );
      expect(
        transport.calls.where((uri) => uri.path == '/3/tv/7/season/2'),
        hasLength(1),
      );

      // Reusing a season subject must not silently switch its titles to S01.
      expect((await first.details(results.first))['season'], '2');
      expect(transport.calls, hasLength(2));
      (results.first['episodeNames'] as Map)['1'] = 'Edited by one reader';
      expect(
        await first.episodeNames('7', subject: {..._subject, 'season': '2'}),
        expected,
      );

      store.dispose();
      store = AppStore('${directory.path}/store.db');
      final offline = _Transport((_) => throw const AppFailure('Offline'));
      final restored = catalog(offline);
      expect(
        (await restored.details(_subject, season: '2'))['episodeNames'],
        expected,
      );
      expect(
        await restored.episodeNames('7', subject: {..._subject, 'season': '2'}),
        expected,
      );
      expect(offline.calls, isEmpty);
    },
  );

  test(
    'incomplete saved titles are filled per season and refresh invalidates them',
    () async {
      var revised = false;
      final transport = _Transport((uri) {
        final result = _reply(uri);
        if (revised && uri.path.contains('/season/')) {
          (result['episodes'] as List)[1]['name'] = 'Updated second title';
        }
        return result;
      });
      final model = catalog(transport);
      expect(
        await model.episodeNames(
          '7',
          subject: {
            ..._subject,
            'season': '2',
            'season_episodes': 2,
            'episodeNames': {'1': 'Old first title'},
          },
        ),
        {'1': 'Season 2: First', '2': 'Season 2: Second'},
      );
      expect(
        await model.episodeNames('7', subject: {..._subject, 'season': '1'}),
        {'1': 'Season 1: First', '2': 'Season 1: Second'},
      );
      expect(transport.calls, hasLength(2));
      revised = true;
      model.invalidateMetadataCaches();
      expect(
        await model.episodeNames('7', subject: {..._subject, 'season': '2'}),
        {'1': 'Season 2: First', '2': 'Updated second title'},
      );
      expect(transport.calls, hasLength(3));
      expect(
        await model.episodeNames(
          '7',
          subject: {..._subject, 'mediaType': 'movie'},
        ),
        isEmpty,
      );
      expect(transport.calls, hasLength(3));
    },
  );

  test(
    'known titles survive an offline incomplete snapshot and retry later',
    () async {
      var online = false;
      final transport = _Transport((uri) {
        if (!online) throw const AppFailure('Offline');
        return _reply(uri);
      });
      final model = catalog(transport);
      final snapshot = {
        ..._subject,
        'season': '2',
        'season_episodes': 2,
        'episodeNames': {'1': 'Season 2: First'},
      };
      expect(await model.episodeNames('7', subject: snapshot), {
        '1': 'Season 2: First',
      });
      online = true;
      expect(await model.episodeNames('7', subject: snapshot), {
        '1': 'Season 2: First',
        '2': 'Season 2: Second',
      });
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'cancelling one episode reader preserves the shared season lookup',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final transport = _Transport((_) {
        if (!started.isCompleted) started.complete();
        return gate.future;
      });
      final model = catalog(transport);
      final token = CancelToken();
      final first = model.episodeNames(
        '7',
        subject: {..._subject, 'season': '2'},
        cancel: token,
      );
      final rejected = expectLater(first, throwsA(isA<Cancelled>()));
      final second = model.episodeNames(
        '7',
        subject: {..._subject, 'season': '2'},
      );
      await started.future;
      token.cancel();
      await rejected;
      gate.complete(_reply(Uri.parse('https://example.com/season/2')));
      expect(await second, {'1': 'Season 2: First', '2': 'Season 2: Second'});
      expect(transport.calls, hasLength(1));
    },
  );
}
