import 'dart:async';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/core/external_open.dart';
import 'package:aiplayer/core/network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _jointCatalogTests();
  test(
    'metadata matches a season, never a different season with the same name',
    () {
      const first = {'id': 1, 'name_cn': '测试作品', 'name': 'Example'};
      const second = {
        'id': 2,
        'name_cn': '测试作品 第二季',
        'name': 'Example 2nd Season',
      };
      expect(subjectMatchesSeason('测试作品', '2', first), isFalse);
      expect(subjectMatchesSeason('测试作品', '2', second), isTrue);
      expect(subjectMatchesSeason('测试作品', '1', second), isFalse);
      expect(subjectMatchesSeason('测试作品', '', first), isTrue);
      expect(subjectMatchesSeason('完全不同', '', first), isFalse);
    },
  );
  test(
    'directory series require episodic evidence and a consistent title/season',
    () {
      SourceEntry file(String name) =>
          SourceEntry(name: name, path: '/测试作品 第二季/$name', size: 12);
      final group = identifyDirectory('/测试作品 第二季', [
        file('01.mkv'),
        file('02.mkv'),
      ]);
      expect(group?.title, '测试作品');
      expect(group?.season, '2');
      expect(group?.episodeLabel('/测试作品 第二季/02.mkv'), contains('第 2 季'));
      expect(
        identifyDirectory('/mixed', [
          file('甲 S01E01.mkv'),
          file('乙 S01E02.mkv'),
        ]),
        isNull,
      );
      expect(
        identifyDirectory('/mixed', [
          file('甲 S01E01.mkv'),
          file('甲 S02E02.mkv'),
        ]),
        isNull,
      );
      final alternate = identifyDirectory('/mixed', [
        file('甲 S01E01.mkv'),
        file('甲 S01E01.mp4'),
      ]);
      expect(alternate?.episodeCount, 1);
      expect(alternate?.videos, hasLength(2));
      expect(
        identifyDirectory('/mixed', [file('旅行.mp4'), file('生日.mp4')]),
        isNull,
      );
    },
  );
  test('first episode opens a series before playback and ignores extras', () {
    final collection = identifyDirectory('/Show', const [
      SourceEntry(name: 'Show E01.mkv', path: '/Show/Show E01.mkv'),
      SourceEntry(name: 'trailer.mkv', path: '/Show/trailer.mkv'),
      SourceEntry(name: 'poster.jpg', path: '/Show/poster.jpg'),
      SourceEntry(name: 'Extras', path: '/Show/Extras', directory: true),
    ]);
    expect(collection?.title, 'Show');
    expect(collection?.episodeCount, 1);
    expect(collection?.videos.single.name, 'Show E01.mkv');
    expect(
      identifyDirectory('/Show', const [
        SourceEntry(name: '01.mkv', path: '/Show/01.mkv'),
      ])?.identities['/Show/01.mkv']?.episode,
      '1',
    );
  });
  test('omitted first-season markers share one ordered directory series', () {
    final collection = identifyDirectory('/Show', const [
      SourceEntry(name: 'Show E02.mkv', path: '/Show/Show E02.mkv'),
      SourceEntry(name: 'Show S01E01.mkv', path: '/Show/Show S01E01.mkv'),
      SourceEntry(name: 'Show E03.mkv', path: '/Show/Show E03.mkv'),
    ]);
    expect(collection?.season, '1');
    expect(
      collection?.videos.map(
        (video) => collection.identities[video.path]?.episode,
      ),
      ['1', '2', '3'],
    );
    expect(
      collection?.identities.values.every((value) => value.season == '1'),
      isTrue,
    );
  });
  test('season folders derive their title before a played anchor exists', () {
    for (final path in [
      '/Series/S02/',
      '/Series/Season 2/',
      '/Series/第二季/',
      r'C:\Series\S02',
    ]) {
      final collection = identifyDirectory(path, [
        SourceEntry(name: '01.mkv', path: '$path/01.mkv'),
        SourceEntry(name: '02.mkv', path: '$path/02.mkv'),
        SourceEntry(name: 'trailer.mkv', path: '$path/trailer.mkv'),
      ]);
      expect(collection?.title, 'Series', reason: path);
      expect(collection?.season, '2', reason: path);
      expect(collection?.episodeCount, 2, reason: path);
    }
    for (final path in ['S01', '/S01', 'Season 1', '/Season 1', '/S02/S01']) {
      expect(
        identifyDirectory(path, [
          SourceEntry(name: '01.mkv', path: '$path/01.mkv'),
        ]),
        isNull,
        reason: 'A season marker alone does not identify a series: $path',
      );
    }
  });
  test('WebDAV root identity is separate from its relative file paths', () {
    final store = AppStore(':memory:');
    try {
      store.setLocal('sources', [
        {
          'id': 'nas',
          'kind': 'webdav',
          'url':
              'https://example.test/dav/${Uri.encodeComponent('作品 #1')}/S02/',
        },
      ]);
      final folder = sourceDirectoryIdentity(store, 'nas', '');
      expect(folder.anime, '作品 #1');
      expect(folder.season, '2');
      const entries = [SourceEntry(name: '01.mkv', path: '01.mkv')];
      final prepared = prepareDirectoryInspection(
        'nas',
        '',
        '',
        entries,
        folderIdentity: folder,
      );
      expect(prepared.collection?.videos.single.path, '01.mkv');
      expect(prepared.collection?.identities['01.mkv']?.episode, '1');
      store.setLocal('sources', [
        {
          'id': 'nas',
          'kind': 'webdav',
          'url': 'https://example.test/dav/Another/S02/',
        },
      ]);
      final changed = prepareDirectoryInspection(
        'nas',
        '',
        '',
        entries,
        folderIdentity: sourceDirectoryIdentity(store, 'nas', ''),
      );
      expect(changed.fingerprint, isNot(prepared.fingerprint));
      expect(changed.collection?.title, 'Another');
    } finally {
      store.dispose();
    }
  });
  test(
    'dot episode names do not turn codecs or hyphenated movie titles into episodes',
    () {
      expect(parseReleaseName('Series.01.mkv').anime, 'Series');
      expect(parseReleaseName('Series.01.mkv').episode, '1');
      for (final codec in ['264', '265']) {
        final parsed = parseReleaseName('Show.H.$codec.mkv');
        expect(parsed.anime, 'Show');
        expect(parsed.episode, isEmpty);
      }
      expect(parseReleaseName('Spider-Man-2.mkv').episode, isEmpty);
      expect(parseReleaseName('Spider-Man-2.mkv').anime, 'Spider-Man-2');
      expect(parseReleaseName('1.5.mkv').episode, isEmpty);
    },
  );
  test(
    'single title-only files preserve explicit seasons and reject conflicts',
    () {
      final collection = identifyDirectory('/Show/', [
        const SourceEntry(name: 'Show S02.mkv', path: '/Show/Show S02.mkv'),
      ]);
      expect(collection?.season, '2');
      expect(collection?.identities.values.single.season, '2');
      expect(collection?.identities.values.single.episode, isEmpty);
      expect(
        identifyDirectory('/Show/S02/', [
          const SourceEntry(
            name: 'Show S01.mkv',
            path: '/Show/S02/Show S01.mkv',
          ),
        ]),
        isNull,
      );
    },
  );
  test(
    'season forms and special episode identities survive filename cleanup',
    () {
      expect(
        parseReleaseName('[组] Example 2nd Season - 03 [1080p].mkv').season,
        '2',
      );
      expect(parseReleaseName('作品 第三期 - 02.mkv').season, '3');
      expect(parseReleaseName('Example II - 03.mkv').season, '2');
      expect(parseReleaseName('Example S02E03.mkv').episode, '3');
      expect(parseReleaseName('Example SP1.mkv').episode, 'S1');
    },
  );
  test(
    'resume thumbnails refresh by position while media identity remains stable',
    () {
      const a = MediaPreviewRequest(
        'video',
        'local',
        '/video.mkv',
        100,
        position: 12,
      );
      const b = MediaPreviewRequest(
        'video',
        'local',
        '/video.mkv',
        100,
        position: 24,
      );
      expect(a.contentFingerprint, b.contentFingerprint);
      expect(a.fingerprint, isNot(b.fingerprint));
      const replaced = MediaPreviewRequest(
        'video',
        'local',
        '/other.mkv',
        100,
        position: 12,
      );
      expect(a.contentFingerprint, isNot(replaced.contentFingerprint));
    },
  );
  test(
    'external open accepts video paths and URLs, rejects unsafe or unusable inputs',
    () {
      expect(
        ExternalVideoRequest.parse({'path': '/tmp/视频.mkv'}).remote,
        isFalse,
      );
      expect(
        ExternalVideoRequest.parse({
          'path': 'file:///tmp/%E8%A7%86%E9%A2%91.mp4',
        }).location,
        '/tmp/视频.mp4',
      );
      expect(
        ExternalVideoRequest.parse({
          'uri': 'https://example.org/video',
          'name': '视频.mp4',
        }).remote,
        isTrue,
      );
      for (final raw in [
        '',
        'relative.mkv',
        '/tmp/file.txt',
        'content://unknown/1',
        'https://user:secret@example.org/a.mp4',
      ]) {
        expect(
          () => ExternalVideoRequest.parse({'path': raw}),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
}

class _CatalogTransport implements JsonTransport {
  final FutureOr<Map<String, dynamic>> Function(Uri) reply;
  final calls = <Uri>[];
  _CatalogTransport(this.reply);
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

const _bangumi = {
  'id': 7,
  'type': 2,
  'name': 'Example',
  'name_cn': '示例',
  'platform': 'TV',
  'date': '2025-01-01',
};
const _tv = {
  'id': 7,
  'name': '示例',
  'original_name': 'Example',
  'first_air_date': '2025-01-01',
  'genres': [
    {'id': 16, 'name': '动画'},
  ],
};
const _movie = {
  'id': 7,
  'title': '示例',
  'original_title': 'Example',
  'release_date': '2025-01-01',
};

Map<String, dynamic> _catalogReply(
  Uri uri, {
  List<Map<String, dynamic>> bangumi = const [_bangumi],
  List<Map<String, dynamic>> tv = const [_tv],
  List<Map<String, dynamic>> movies = const [],
}) {
  if (uri.path.startsWith('/search/subject/')) return {'list': bangumi};
  if (uri.path == '/3/search/tv') return {'results': tv};
  if (uri.path == '/3/search/movie') return {'results': movies};
  if (uri.path == '/v0/episodes') return {'data': []};
  if (uri.path.contains('/season/')) {
    return {
      'season_number': int.parse(uri.pathSegments.last),
      'air_date': '2025-01-01',
      'episodes': [
        {'episode_number': 1, 'name': '开始'},
      ],
    };
  }
  final values = uri.path.startsWith('/v0/subjects/')
      ? bangumi
      : uri.path.startsWith('/3/tv/')
      ? tv
      : movies;
  return values.firstWhere(
    (value) => '${value['id']}' == uri.pathSegments.last,
  );
}

void _jointCatalogTests() {
  group('joint catalogue', () {
    late AppStore store;
    setUp(() => store = AppStore(':memory:'));
    tearDown(() => store.dispose());
    LibraryCatalog catalog(
      _CatalogTransport transport, {
      String Function()? provider,
      String Function()? strategy,
    }) => LibraryCatalog(
      store,
      transport: transport,
      provider: provider,
      strategy: strategy,
      tmdbNameAssist: () => false,
      tmdbCredential: () async => 'read-token',
    );

    test(
      'default search merges all sources and keeps same IDs in different types',
      () async {
        for (final preferred in ['bangumi', 'tmdb', 'legacy']) {
          final transport = _CatalogTransport(
            (uri) => _catalogReply(
              uri,
              bangumi: const [_bangumi, _bangumi],
              movies: const [_movie],
            ),
          );
          final results = await catalog(
            transport,
            provider: () => preferred,
          ).search('Example');
          expect(
            results
                .map(
                  (value) =>
                      '${value['provider']}:${value['mediaType']}:${value['id']}',
                )
                .toSet(),
            {'bangumi:tv:7', 'tmdb:tv:7', 'tmdb:movie:7'},
          );
          expect(results, hasLength(3));
          if (preferred == 'bangumi') {
            expect(
              transport.calls.map((uri) => uri.path),
              containsAll([
                '/search/subject/Example',
                '/3/search/tv',
                '/3/search/movie',
              ]),
            );
          } else {
            expect(
              transport.calls,
              isEmpty,
              reason: 'Legacy provider preference shares persistent results',
            );
          }
        }
      },
    );

    test(
      'one failed endpoint does not hide the other search results',
      () async {
        for (final failed in [
          '/search/subject/',
          '/3/search/tv',
          '/3/search/movie',
        ]) {
          final transport = _CatalogTransport((uri) {
            if (uri.path.startsWith(failed)) throw const AppFailure('离线');
            return _catalogReply(uri, movies: const [_movie]);
          });
          final model = catalog(transport)..invalidateMetadataCaches();
          final results = await model.search('Example');
          expect(results, hasLength(2), reason: failed);
          expect(
            transport.calls.map((uri) => uri.path),
            containsAll([
              '/search/subject/Example',
              '/3/search/tv',
              '/3/search/movie',
            ]),
          );
        }
      },
    );

    test(
      'missing TMDB credential retains Bangumi and explicit source remains available',
      () async {
        final transport = _CatalogTransport(_catalogReply);
        final model = LibraryCatalog(
          store,
          transport: transport,
          provider: () => 'tmdb',
        );
        expect((await model.search('Example')).single['provider'], 'bangumi');
        expect(transport.calls.every((uri) => uri.host == 'api.bgm.tv'), true);
        transport.calls.clear();
        expect(
          (await catalog(
            transport,
          ).search('Example', source: 'bangumi')).single['provider'],
          'bangumi',
        );
        expect(transport.calls.every((uri) => uri.host == 'api.bgm.tv'), true);
      },
    );

    test(
      'consistent animation prefers Bangumi and ignores legacy provider cache preferences',
      () async {
        var preferred = 'tmdb';
        final transport = _CatalogTransport(_catalogReply);
        final model = catalog(transport, provider: () => preferred);
        expect((await model.resolve('Example', '1'))?['provider'], 'bangumi');
        final count = transport.calls.length;
        preferred = 'bangumi';
        expect((await model.resolve('Example', '1'))?['provider'], 'bangumi');
        expect(transport.calls.length, count);
        expect(store.localEntries('subject-v5:'), hasLength(1));
        expect(store.localEntries('subject-v4:'), isEmpty);
      },
    );

    test(
      'TMDB TV or movie can resolve without Bangumi; episodic input never adopts a movie',
      () async {
        for (final movie in [false, true]) {
          final transport = _CatalogTransport(
            (uri) => _catalogReply(
              uri,
              bangumi: const [],
              tv: movie ? const [] : const [_tv],
              movies: movie ? const [_movie] : const [],
            ),
          );
          final model = catalog(transport)..invalidateMetadataCaches();
          final result = await model.resolve(
            'Example',
            movie ? '' : '2',
            force: true,
          );
          expect(result?['provider'], 'tmdb');
          expect(result?['mediaType'], movie ? 'movie' : 'tv');
          if (movie) {
            expect(await model.resolve('Example', '3', force: true), isNull);
          } else {
            expect(result?['season'], '2');
          }
        }
      },
    );

    test(
      'independent source failure permits a complete match without caching a partial lookup',
      () async {
        final transport = _CatalogTransport((uri) {
          if (uri.host == 'api.bgm.tv') throw const AppFailure('Bangumi 离线');
          return _catalogReply(uri);
        });
        expect(
          (await catalog(transport).resolve('Example', '1'))?['provider'],
          'tmdb',
        );
        expect(store.localEntries('subject-v5:'), isEmpty);
        final inverse = _CatalogTransport((uri) {
          if (uri.host == 'api.themoviedb.org') {
            throw const AppFailure('TMDB 离线');
          }
          return _catalogReply(uri);
        });
        final inverseCatalog = catalog(inverse)..invalidateMetadataCaches();
        expect(
          (await inverseCatalog.resolve('Example', '1'))?['provider'],
          'bangumi',
        );
      },
    );

    test(
      'conflicting years, original titles, live-action types and ambiguity remain unresolved',
      () async {
        final cases =
            <
              ({
                List<Map<String, dynamic>> bangumi,
                List<Map<String, dynamic>> tv,
              })
            >[
              (
                bangumi: [
                  {..._bangumi, 'date': '2020-01-01'},
                ],
                tv: [_tv],
              ),
              (
                bangumi: [
                  {..._bangumi, 'name': '原作甲'},
                ],
                tv: [
                  {..._tv, 'original_name': '原作乙'},
                ],
              ),
              (
                bangumi: [_bangumi],
                tv: [
                  {
                    ..._tv,
                    'genres': [
                      {'id': 18, 'name': '剧情'},
                    ],
                  },
                ],
              ),
              (
                bangumi: [
                  _bangumi,
                  {..._bangumi, 'id': 8},
                ],
                tv: [_tv],
              ),
              (
                bangumi: [_bangumi],
                tv: [
                  _tv,
                  {..._tv, 'id': 8},
                ],
              ),
            ];
        for (final entry in cases) {
          final transport = _CatalogTransport(
            (uri) => _catalogReply(uri, bangumi: entry.bangumi, tv: entry.tv),
          );
          final model = catalog(transport)..invalidateMetadataCaches();
          expect(
            await model.resolve('示例', '1', force: true),
            isNull,
            reason: '$entry',
          );
        }
      },
    );

    test(
      'cancelled cache access and late automatic replies never publish metadata',
      () async {
        final cached = catalog(_CatalogTransport(_catalogReply));
        await cached.resolve('Example', '1');
        final cancelled = CancelToken()..cancel();
        await expectLater(
          cached.resolve('Example', '1', cancel: cancelled),
          throwsA(isA<Cancelled>()),
        );

        var strategy = 'conservative';
        final gate = Completer<Map<String, dynamic>>();
        final started = Completer<void>();
        final delayed = LibraryCatalog(
          store,
          strategy: () => strategy,
          transport: _CatalogTransport((uri) {
            if (uri.path.startsWith('/search/subject/')) {
              if (!started.isCompleted) started.complete();
              return gate.future;
            }
            return _catalogReply(uri);
          }),
        );
        final request = delayed.resolve('Other', '1', force: true);
        await started.future;
        strategy = 'off';
        gate.complete({
          'list': [_bangumi],
        });
        expect(await request, isNull);
        expect(
          store.localEntries('subject-v5:'),
          hasLength(1),
          reason: 'Only the original completed lookup is cached',
        );
      },
    );

    test(
      'directory AI fallback covers unparsed files and invalidates when its context changes',
      () async {
        var aiContext = 'enabled:model-a';
        var calls = 0;
        final entries = [
          const SourceEntry(
            name: 'unstructured.mkv',
            path: '/folder/unstructured.mkv',
          ),
        ];
        final result = DirectoryCollection(
          title: 'Example',
          season: '1',
          videos: entries,
          identities: {
            entries.single.path: const ReleaseName('Example', '1', '1'),
          },
          subject: _bangumi,
          episodeTitles: const {'1': '开始'},
        );
        final model = LibraryCatalog(
          store,
          transport: _CatalogTransport(_catalogReply),
          aiContext: () => aiContext,
          aiFallback: (source, path, files, cancel) async {
            calls++;
            expect(files, entries);
            return result;
          },
        );
        expect(await model.inspect('local', '/folder', entries), same(result));
        expect(
          (await model.inspect('local', '/folder', entries))?.subject,
          _bangumi,
        );
        expect(calls, 1);
        aiContext = 'enabled:model-b';
        expect(model.directoryPreview('local', '/folder'), isNull);
        await model.inspect('local', '/folder', entries);
        expect(calls, 2);
      },
    );

    test(
      'directory keeps its resolved subject and retries failed episode details',
      () async {
        var episodeRequests = 0;
        final transport = _CatalogTransport((uri) {
          if (uri.path == '/v0/episodes') {
            episodeRequests++;
            if (episodeRequests == 1) {
              throw const AppFailure('episode catalogue temporarily offline');
            }
            return {
              'data': [
                {'sort': 1, 'name_cn': '开始'},
              ],
            };
          }
          return _catalogReply(uri);
        });
        final model = LibraryCatalog(store, transport: transport);
        const entries = [
          SourceEntry(name: 'Example S01E01.mkv', path: '/Example/E01.mkv'),
        ];
        final first = await model.inspect('local', '/Example', entries);
        expect(first?.subject?['id'], 7);
        expect(first?.metadataComplete, isFalse);
        expect(
          model
              .directoryPreview('local', '/Example')
              ?.collection
              ?.metadataComplete,
          isFalse,
        );
        expect(
          LibraryCatalog(
            store,
          ).directoryPreview('local', '/Example')?.collection?.metadataComplete,
          isFalse,
        );
        final second = await model.inspect('local', '/Example', entries);
        expect(second?.subject?['id'], 7);
        expect(second?.metadataComplete, isTrue);
        expect(second?.episodeTitles, {'1': '开始'});
        expect(episodeRequests, 2);
        expect(model.directoryPreview('local', '/Example'), isNotNull);
        expect(
          transport.calls.where((uri) => uri.path == '/v0/subjects/7'),
          hasLength(1),
          reason: 'Retry reuses the already resolved work.',
        );
      },
    );

    test(
      'directory metadata is discarded when episode lookup finishes after cancellation or disabling',
      () async {
        for (final cancelRequest in [false, true]) {
          final branchStore = AppStore(':memory:');
          addTearDown(branchStore.dispose);
          var strategy = 'conservative';
          final gate = Completer<Map<String, dynamic>>();
          final started = Completer<void>();
          final token = CancelToken();
          final model = LibraryCatalog(
            branchStore,
            strategy: () => strategy,
            transport: _CatalogTransport((uri) {
              if (uri.path == '/v0/episodes') {
                started.complete();
                return gate.future;
              }
              return _catalogReply(uri);
            }),
          );
          final entries = [
            for (var episode = 1; episode <= 2; episode++)
              SourceEntry(
                name: 'Example S01E0$episode.mkv',
                path: '/episodes/Example S01E0$episode.mkv',
              ),
          ];
          final request = model.inspect(
            'local',
            '/episodes',
            entries,
            cancel: token,
          );
          await started.future;
          if (cancelRequest) {
            token.cancel();
          } else {
            strategy = 'off';
          }
          gate.complete({
            'data': [
              {'sort': 1, 'name_cn': '开始'},
            ],
          });
          if (cancelRequest) {
            await expectLater(request, throwsA(isA<Cancelled>()));
            expect(branchStore.localEntries('episode-names:'), isEmpty);
          } else {
            expect((await request)?.subject, isNull);
          }
          expect(branchStore.localEntries('directory-preview:'), isEmpty);
        }
      },
    );

    test(
      'directory fallback does not publish after cancellation or disabling metadata',
      () async {
        for (final cancelRequest in [false, true]) {
          var strategy = 'conservative';
          final gate = Completer<DirectoryCollection?>();
          final started = Completer<void>();
          final token = CancelToken();
          final entries = [
            const SourceEntry(
              name: 'unstructured.mkv',
              path: '/late/unstructured.mkv',
            ),
          ];
          final model = LibraryCatalog(
            store,
            strategy: () => strategy,
            aiFallback: (_, _, _, _) {
              started.complete();
              return gate.future;
            },
          );
          final request = model.inspect(
            'local',
            '/late',
            entries,
            cancel: token,
          );
          await started.future;
          if (cancelRequest) {
            token.cancel();
          } else {
            strategy = 'off';
          }
          gate.complete(
            DirectoryCollection(
              title: 'Example',
              season: '1',
              videos: entries,
              identities: const {},
              subject: _bangumi,
            ),
          );
          if (cancelRequest) {
            await expectLater(request, throwsA(isA<Cancelled>()));
          } else {
            expect(await request, isNull);
          }
          expect(store.localEntries('directory-preview:'), isEmpty);
        }
      },
    );
  });
}
