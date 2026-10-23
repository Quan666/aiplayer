import 'dart:async';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  Map<String, String> names = {'1': 'First'};
  final calls = <Uri>[];
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    calls.add(uri);
    await gate?.future;
    if (uri.path == '/v0/episodes') {
      return {
        'data': [
          for (final row in names.entries)
            {'sort': int.parse(row.key), 'name_cn': row.value},
        ],
      };
    }
    return {
      'season_number': int.parse(uri.pathSegments.last),
      'episodes': [
        for (final row in names.entries)
          {'episode_number': int.parse(row.key), 'name': row.value},
      ],
    };
  }
}

DirectoryCollection _collection([int count = 3]) =>
    identifyDirectory('Example', [
      for (var episode = 1; episode <= count; episode++)
        SourceEntry(
          name: 'Example S02E$episode.mkv',
          path: 'Example/$episode.mkv',
        ),
    ])!;

const _full = {'1': 'First', '2': 'Second', '3': 'Third'};

void main() {
  for (final provider in ['bangumi', 'tmdb']) {
    late AppStore store;
    late _Transport transport;
    late LibraryCatalog catalog;
    late DateTime now;
    final subject = {'provider': provider, 'id': '7', 'mediaType': 'tv'};
    final savedSubject = {...subject, 'season': '2'};
    setUp(() {
      store = AppStore(':memory:');
      transport = _Transport();
      now = DateTime.utc(2026, 1, 1);
      catalog = LibraryCatalog(
        store,
        transport: transport,
        tmdbCredential: () async => 'test-token',
        now: () => now,
      );
    });
    tearDown(() => store.dispose());

    test(
      '$provider other series requests cannot suppress this cache refresh',
      () async {
        var otherLoaded = false;
        catalog = LibraryCatalog(
          store,
          transport: transport,
          tmdbCredential: () async => 'test-token',
          episodeNamesCovered: (identities, names, cancel) async {
            if (!otherLoaded) {
              otherLoaded = true;
              await catalog.episodeNames(
                '8',
                subject: {...savedSubject, 'id': '8'},
              );
            }
            return directoryEpisodeNamesCovered(identities, names);
          },
        );
        await catalog.episodeNames('7', subject: savedSubject);
        transport.names = _full;
        expect(
          await catalog.collectionEpisodeNames(_collection(), subject),
          _full,
        );
        expect(transport.calls, hasLength(3));
      },
    );

    test(
      '$provider AI directory fallback repairs a partial title cache',
      () async {
        final files = [
          for (final name in ['alpha', 'beta', 'gamma'])
            SourceEntry(name: '$name.mkv', path: 'Mixed/$name.mkv'),
        ];
        final fallback = DirectoryCollection(
          title: 'Example',
          season: '2',
          videos: files,
          identities: {
            for (var index = 0; index < files.length; index++)
              files[index].path: ReleaseName('Example', '2', '${index + 1}'),
          },
          subject: subject,
          episodeTitles: const {'1': 'First'},
        );
        catalog = LibraryCatalog(
          store,
          transport: transport,
          tmdbCredential: () async => 'test-token',
          aiFallback: (_, _, _, _) async => fallback,
        );
        await catalog.episodeNames('7', subject: savedSubject);
        transport.names = _full;
        final result = await catalog.inspect('nas', 'Mixed', files);
        expect(result?.episodeTitles, _full);
        expect(result?.metadataComplete, isTrue);
        expect(transport.calls, hasLength(2));
        expect(
          catalog.directoryPreview('nas', 'Mixed')?.collection?.episodeTitles,
          _full,
        );
      },
    );

    test(
      '$provider refreshes a cached episode subset for the opened collection',
      () async {
        expect(await catalog.episodeNames('7', subject: savedSubject), {
          '1': 'First',
        });
        transport.names = _full;
        expect(
          await catalog.collectionEpisodeNames(_collection(), subject),
          _full,
        );
        expect(transport.calls, hasLength(2));
        expect(
          await catalog.collectionEpisodeNames(_collection(), {
            ...subject,
            'episodeNames': {'1': 'First'},
            'season_episodes': 1,
          }),
          _full,
        );
        expect(transport.calls, hasLength(2));
        if (provider == 'tmdb') {
          expect(
            transport.calls.every((uri) => uri.path.endsWith('/season/2')),
            isTrue,
          );
        }
      },
    );

    test(
      '$provider fresh partial results make one request and back off',
      () async {
        expect(await catalog.collectionEpisodeNames(_collection(), subject), {
          '1': 'First',
        });
        expect(transport.calls, hasLength(1));
        for (var i = 0; i < 5; i++) {
          await catalog.collectionEpisodeNames(_collection(), subject);
        }
        expect(transport.calls, hasLength(1));
        now = now.add(const Duration(minutes: 5));
        await catalog.collectionEpisodeNames(_collection(), subject);
        expect(transport.calls, hasLength(2));
        now = now.add(const Duration(minutes: 9));
        await catalog.collectionEpisodeNames(_collection(), subject);
        expect(transport.calls, hasLength(2));
        now = now.add(const Duration(minutes: 1));
        transport.names = _full;
        expect(
          await catalog.collectionEpisodeNames(_collection(), subject),
          _full,
        );
        expect(transport.calls, hasLength(3));
      },
    );

    test(
      '$provider partial refresh retains previously cached episode titles',
      () async {
        transport.names = {'1': 'First', '2': 'Second'};
        await catalog.episodeNames('7', subject: savedSubject);
        transport.names = {'3': 'Third'};
        expect(
          await catalog.collectionEpisodeNames(_collection(), subject),
          _full,
        );
        expect(await catalog.episodeNames('7', subject: savedSubject), _full);
        expect(transport.calls, hasLength(2));
      },
    );

    test(
      '$provider checks numeric membership rather than name count',
      () async {
        transport.names = {'1': 'First', '3': 'Third'};
        await catalog.episodeNames('7', subject: savedSubject);
        transport.names = _full;
        final result = await catalog.collectionEpisodeNames(
          _collection(2),
          subject,
        );
        expect(result['2'], 'Second');
        expect(transport.calls, hasLength(2));
      },
    );

    test('$provider shared refresh survives one cancelled reader', () async {
      await catalog.episodeNames('7', subject: savedSubject);
      final gate = transport.gate = Completer<void>();
      final token = CancelToken();
      final first = catalog.collectionEpisodeNames(
        _collection(),
        subject,
        cancel: token,
      );
      final firstFailure = expectLater(first, throwsA(isA<Cancelled>()));
      final second = catalog.collectionEpisodeNames(
        _collection(),
        subject,
        cancel: CancelToken(),
      );
      for (var i = 0; i < 20 && transport.calls.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      token.cancel();
      await firstFailure;
      transport.names = _full;
      gate.complete();
      expect(await second, _full);
      expect(await catalog.episodeNames('7', subject: savedSubject), _full);
      expect(transport.calls, hasLength(2));
    });

    test(
      '$provider cancelled refresh cannot replace cached names or delay retry',
      () async {
        await catalog.episodeNames('7', subject: savedSubject);
        final gate = transport.gate = Completer<void>();
        final token = CancelToken();
        final pending = catalog.collectionEpisodeNames(
          _collection(),
          subject,
          cancel: token,
        );
        final failure = expectLater(pending, throwsA(isA<Cancelled>()));
        for (var i = 0; i < 20 && transport.calls.length < 2; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        token.cancel();
        await failure;
        transport.names = _full;
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(await catalog.episodeNames('7', subject: savedSubject), {
          '1': 'First',
        });
        transport.gate = null;
        expect(
          await catalog.collectionEpisodeNames(_collection(), subject),
          _full,
        );
        expect(transport.calls, hasLength(3));
      },
    );
  }
}
