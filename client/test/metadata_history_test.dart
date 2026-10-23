import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  final Map<String, dynamic> Function(Uri) response;
  final calls =
      <
        ({
          Uri uri,
          String method,
          Map<String, dynamic>? body,
          Map<String, String> headers,
        })
      >[];
  _Transport(this.response);
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    calls.add((uri: uri, method: method, body: body, headers: headers));
    return response(uri);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late AppModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-history-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = AppModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  SyncRecord add(String name, {String? path}) {
    final id = model.addMedia(
      'local',
      SourceEntry(name: name, path: path ?? '/动漫/$name', size: 100),
    );
    return store.get('media', id)!;
  }

  test(
    'series history keeps newest card and every episode keeps its exact resume',
    () {
      final three = add('测试作品 S01E03.mkv');
      final four = add('测试作品 S01E04.mkv');
      final other = add('旅行.mp4');
      void progress(SyncRecord media, int position, String date) => store.save(
        'progress',
        model.progressKey(media),
        {'position': position, 'duration': 120, 'updatedAt': date},
      );
      progress(three, 17, '2026-10-20T00:00:00Z');
      progress(four, 42, '2026-10-21T00:00:00Z');
      progress(other, 11, '2026-10-19T00:00:00Z');
      expect(model.recentMedia().map((v) => v.id), [four.id, other.id]);
      expect(model.recentMedia(groupSeries: false).length, 3);
      expect(model.progressFor(three)?['position'], 17);
      expect(model.progressFor(four)?['position'], 42);
      progress(three, 21, '2026-10-22T00:00:00Z');
      expect(model.recentMedia().first.id, three.id);
      expect(model.progressFor(four)?['position'], 42);
    },
  );

  test(
    'unique same-season identity fills a missing episode without sharing progress or another season',
    () {
      final one = add('测试作品 S02E01.mkv');
      model.applyBangumi(
        '测试作品',
        {
          'id': 42,
          'name_cn': '正式中文作品 第二季',
          'name': 'Example 2nd Season',
          'images': {'large': 'https://example.com/poster.jpg'},
          'rating': {'score': 8.3},
          'total_episodes': 12,
          'date': '2026-01-01',
        },
        season: '2',
        manual: false,
      );
      final two = add('测试作品 S02E02.mkv');
      final firstSeason = add('测试作品 S01E02.mkv');
      expect(store.get('media', two.id)?.data['bangumiId'], '42');
      expect(store.get('media', two.id)?.data['rating'], 8.3);
      expect(store.get('media', firstSeason.id)?.data['bangumiId'], isNull);
      expect(model.progressFor(one), isNull);
      expect(model.progressFor(two), isNull);
      store.setLocal('episodeTitle:${two.id}', '新的相遇');
      expect(model.displayTitle(store.get('media', two.id)!), contains('新的相遇'));
      expect(
        model.displayTitle(store.get('media', two.id)!),
        contains('正式中文作品'),
      );
    },
  );

  test(
    'manual correction and ambiguous verified identities are not overwritten',
    () {
      final one = add('测试作品 S01E01.mkv');
      final three = add('测试作品 S01E03.mkv');
      store.save('media', one.id, {
        ...one.data,
        'bangumiId': '1',
        'poster': 'poster1',
      });
      store.save('media', three.id, {
        ...three.data,
        'bangumiId': '2',
        'poster': 'poster2',
      });
      final two = add('测试作品 S01E02.mkv');
      expect(store.get('media', two.id)?.data['bangumiId'], isNull);
      store.setLocal('manualMetadata:${two.id}', true);
      model.applyBangumi(
        '测试作品',
        {'id': 9, 'name': '测试作品'},
        season: '1',
        manual: false,
      );
      expect(store.get('media', two.id)?.data['bangumiId'], isNull);
    },
  );

  test(
    'startup repairs partial recognised series locally including implicit first season',
    () async {
      final one = add('测试作品 S01E01.mkv');
      final two = add('测试作品 - 02.mkv');
      store.save('media', one.id, {
        ...one.data,
        'bangumiId': '42',
        'metadataProvider': 'bangumi',
        'metadataTitle': '确定的作品名',
        'poster': 'poster42',
      });
      model.dispose();
      model = AppModel(store, root);
      await model.startBackgroundWork();
      expect(store.get('media', two.id)?.data['bangumiId'], '42');
      expect(
        mediaSeriesKey(store.get('media', one.id)!),
        mediaSeriesKey(store.get('media', two.id)!),
      );
    },
  );

  test(
    'TMDB movie and TV numeric IDs never share history or watched identity',
    () {
      final tv = SyncRecord(
        id: 'tv',
        kind: 'media',
        data: {
          'tmdbId': '100',
          'metadataType': 'tv',
          'series': '相同标题',
          'season': '',
          'episode': '',
        },
      );
      final movie = SyncRecord(
        id: 'movie',
        kind: 'media',
        data: {...tv.data, 'metadataType': 'movie'},
      );
      expect(mediaSeriesKey(tv), isNot(mediaSeriesKey(movie)));
      expect(model.watchedKey(tv), isNot(model.watchedKey(movie)));
    },
  );

  test('bare episode uses directory title and season locally', () {
    final two = add('02.mkv', path: '/测试作品 第二季/02.mkv');
    expect(two.data['series'], '测试作品');
    expect(two.data['season'], '2');
    expect(two.data['episode'], '2');
  });

  test(
    'Bangumi metadata only sends a cleaned GET name and numeric IDs, never source paths or content',
    () async {
      final transport = _Transport((uri) {
        if (uri.path.startsWith('/search/subject/')) {
          return {
            'list': [
              {'id': 99, 'name': 'Example', 'name_cn': '测试作品'},
            ],
          };
        }
        return {
          'id': 99,
          'name': 'Example',
          'name_cn': '测试作品',
          'rating': {'score': 9.0},
        };
      });
      final catalog = LibraryCatalog(store, transport: transport);
      final result = await catalog.resolve(
        '[字幕组] Example - 01 [1080p HEVC].mkv',
        '1',
      );
      expect(result?['id'], 99);
      expect(
        transport.calls.every(
          (call) => call.method == 'GET' && call.body == null,
        ),
        isTrue,
      );
      expect(transport.calls.first.uri.path, '/search/subject/Example');
      final count = transport.calls.length;
      expect(await catalog.resolve('/private/家庭视频.mp4', ''), isNull);
      expect(
        await catalog.resolve('https://host/private.mp4?token=secret', ''),
        isNull,
      );
      expect(transport.calls.length, count);
    },
  );

  test(
    'off strategy never requests metadata and same-name different seasons remain unresolved',
    () async {
      final transport = _Transport(
        (uri) => {
          'list': [
            {'id': 1, 'name': 'Example'},
            {'id': 2, 'name': 'Example'},
          ],
        },
      );
      final disabled = LibraryCatalog(
        store,
        transport: transport,
        strategy: () => 'off',
      );
      expect(await disabled.resolve('Example', ''), isNull);
      expect(transport.calls, isEmpty);
      final catalog = LibraryCatalog(store, transport: transport);
      expect(await catalog.resolve('Example', '2'), isNull);
      expect(await catalog.resolve('Example', '1'), isNull);
    },
  );

  test(
    'TMDB selected season supplies correct poster, ratings, episode titles and private header credential',
    () async {
      final transport = _Transport((uri) {
        if (uri.path == '/3/search/tv') {
          return {
            'results': [
              {'id': 12, 'name': '示例作品', 'original_name': 'Example'},
            ],
          };
        }
        if (uri.path == '/3/search/movie') return {'results': []};
        if (uri.path == '/3/tv/12/season/2') {
          return {
            'season_number': 2,
            'poster_path': '/season2.jpg',
            'air_date': '2026-04-01',
            'episodes': [
              {'episode_number': 2, 'name': '第二集标题'},
            ],
          };
        }
        return {
          'id': 12,
          'name': '示例作品',
          'original_name': 'Example',
          'number_of_episodes': 24,
          'number_of_seasons': 2,
          'vote_average': 8.5,
          'vote_count': 100,
          'poster_path': '/main.jpg',
        };
      });
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        provider: () => 'tmdb',
        tmdbCredential: () async => 'read-access-token',
      );
      final subject = await catalog.resolve('Example', '2');
      expect(subject?['season'], '2');
      expect(subject?['images']['large'], endsWith('/season2.jpg'));
      expect(subject?['rating']['score'], 8.5);
      expect(
        (await catalog.episodeNames('12', subject: subject))['2'],
        '第二集标题',
      );
      expect(
        transport.calls.every(
          (call) => call.method == 'GET' && call.body == null,
        ),
        isTrue,
      );
      expect(
        transport.calls.every(
          (call) => !call.uri.toString().contains('read-access-token'),
        ),
        isTrue,
      );
      expect(
        transport.calls
            .firstWhere((call) => call.uri.host == 'api.themoviedb.org')
            .headers['Authorization'],
        'Bearer read-access-token',
      );
    },
  );

  test(
    'progress presentation and unknown files never collapse into an unrelated card',
    () {
      final one = add('旅行.mp4'), two = add('生日.mp4');
      expect(mediaSeriesKey(one), isNot(mediaSeriesKey(two)));
      expect(
        playbackProgressLabel({'position': 30, 'duration': 120}),
        '00:30 / 02:00 · 25%',
      );
      expect(model.displayTitle(one), '旅行.mp4');
    },
  );
}
