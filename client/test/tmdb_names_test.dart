import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/tmdb_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/metadata_match_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  final Map<String, dynamic> Function(Uri) reply;
  final calls =
      <
        ({
          Uri uri,
          String method,
          Map<String, dynamic>? body,
          Map<String, String> headers,
        })
      >[];
  _Transport(this.reply);
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
    return reply(uri);
  }
}

class _DialogModel extends AppModel {
  final JsonTransport transport;
  _DialogModel(super.store, super.documents, this.transport);

  late final LibraryCatalog _catalog = LibraryCatalog(
    store,
    transport: transport,
    tmdbCredential: () =>
        secrets.read(key: 'tmdb.apiKey').then((key) => key ?? ''),
  );

  @override
  LibraryCatalog get catalog => _catalog;
}

Map<String, dynamic> tmdbResponse(
  Uri uri, {
  bool ambiguous = false,
  bool missingSeason = false,
}) {
  if (uri.path == '/3/search/movie') return {'results': []};
  if (uri.path == '/3/search/tv') {
    return {
      'results': [
        {'id': 12, 'name': '中文作品', 'original_name': '日本語作品'},
        if (ambiguous) {'id': 13, 'name': '另一作品', 'original_name': '他の作品'},
      ],
    };
  }
  if (uri.path.contains('/season/')) {
    if (missingSeason) throw const AppFailure('季度不存在', 404);
    return {
      'season_number': int.parse(uri.pathSegments.last),
      'poster_path': '/season.jpg',
      'episodes': [
        {'episode_number': 2, 'name': '再次相遇'},
      ],
    };
  }
  if (uri.path.startsWith('/3/tv/')) {
    return {
      'id': int.parse(uri.pathSegments.last),
      'name': '中文作品',
      'original_name': '日本語作品',
      'overview': '中文简介',
      'poster_path': '/poster.jpg',
      'alternative_titles': {
        'results': [
          {'iso_3166_1': 'US', 'title': 'English Release Name'},
        ],
      },
      'translations': {
        'translations': [
          {
            'iso_639_1': 'en',
            'iso_3166_1': 'US',
            'data': {'name': 'An English Name'},
          },
          {
            'iso_639_1': 'zh',
            'iso_3166_1': 'TW',
            'data': {'name': '繁體譯名'},
          },
          {
            'iso_639_1': 'zh',
            'iso_3166_1': 'CN',
            'data': {'name': '中文作品', 'overview': '中文简介'},
          },
        ],
      },
    };
  }
  if (uri.path.startsWith('/search/subject/')) {
    return {
      'list': Uri.decodeComponent(uri.path).contains('中文作品')
          ? [
              {'id': 88, 'name_cn': '中文作品 第二季', 'name': '日本語作品 2nd Season'},
            ]
          : [],
    };
  }
  if (uri.path == '/v0/subjects/88') {
    return {
      'id': 88,
      'name_cn': '中文作品 第二季',
      'name': '日本語作品 2nd Season',
      'images': {'large': 'https://example.com/bangumi.jpg'},
    };
  }
  throw StateError('Unexpected path ${uri.path}');
}

Map<String, dynamic> tmdbOnlyResponse(Uri uri) => uri.host == 'api.bgm.tv'
    ? {'list': <Map<String, dynamic>>[]}
    : tmdbResponse(uri);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  setUp(() {
    store = AppStore(':memory:');
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => store.dispose());
  LibraryCatalog catalog(
    _Transport transport, {
    String provider = 'tmdb',
    bool assist = true,
    Future<String> Function()? credential,
  }) => LibraryCatalog(
    store,
    transport: transport,
    provider: () => provider,
    tmdbNameAssist: () => assist,
    tmdbCredential: credential ?? (() async => 'read-token'),
  );

  test(
    'English alternate name resolves Japanese original to Chinese metadata and the correct season',
    () async {
      final transport = _Transport(tmdbOnlyResponse);
      final result = await catalog(
        transport,
      ).resolve('[Group] English Release Name S02E02 [1080p].mkv', '2');
      expect(result?['id'], '12');
      expect(result?['name_cn'], '中文作品');
      expect(result?['summary'], '中文简介');
      expect(result?['season'], '2');
      expect(result?['images']['large'], endsWith('/season.jpg'));
      expect(result?['episodeNames']['2'], '再次相遇');
      expect(
        TmdbCatalog(transport, () async => 'read-token').names(result!).take(4),
        ['中文作品', '日本語作品', 'An English Name', 'English Release Name'],
      );
      final detail = transport.calls.singleWhere(
        (v) => v.uri.path == '/3/tv/12',
      );
      expect(
        detail.uri.queryParameters['append_to_response'],
        'alternative_titles,translations',
      );
      expect(
        transport.calls.every((v) => v.method == 'GET' && v.body == null),
        isTrue,
      );
      expect(
        transport.calls
            .where((v) => v.uri.host == 'api.themoviedb.org')
            .every((v) => v.headers['Authorization'] == 'Bearer read-token'),
        isTrue,
      );
      expect(
        transport.calls.any((v) => v.uri.toString().contains('read-token')),
        isFalse,
      );
      expect(
        transport.calls
            .firstWhere((v) => v.uri.path == '/3/search/tv')
            .uri
            .queryParameters['query'],
        'English Release Name',
      );
    },
  );

  test(
    'translated English title and Japanese original both resolve, not only localized title',
    () async {
      for (final name in ['An English Name', '日本語作品', '繁體譯名']) {
        final result = await catalog(
          _Transport(tmdbOnlyResponse),
        ).resolve(name, '2');
        expect(result?['id'], '12', reason: name);
      }
    },
  );

  test(
    'TMDB name assistance finds Bangumi while preserving Bangumi identity and season',
    () async {
      final transport = _Transport(tmdbResponse);
      final result = await catalog(
        transport,
        provider: 'bangumi',
      ).resolve('English Release Name', '2');
      expect(
        result?['id'],
        88,
        reason: transport.calls.map((v) => v.uri.path).join('\n'),
      );
      expect(result?['provider'], 'bangumi');
      expect(result?['name_cn'], '中文作品 第二季');
      expect(result?['images']['large'], endsWith('/bangumi.jpg'));
      expect(
        transport.calls.any(
          (v) => Uri.decodeComponent(v.uri.path).contains('中文作品'),
        ),
        isTrue,
      );
      final fields = subjectMediaFields(result!);
      expect(fields['bangumiId'], '88');
      expect(fields.containsKey('tmdbId'), isFalse);
      expect(fields.containsKey('aliases'), isFalse);
    },
  );

  test(
    'same English alias belonging to two identities remains unresolved',
    () async {
      final transport = _Transport((uri) => tmdbResponse(uri, ambiguous: true));
      expect(
        await catalog(transport).resolve('English Release Name', '2'),
        isNull,
      );
      expect(
        transport.calls.any((v) => v.uri.path.contains('/season/')),
        isFalse,
      );
    },
  );

  test(
    'a failed candidate identity cannot be skipped to manufacture a unique result',
    () async {
      final transport = _Transport((uri) {
        if (uri.path == '/3/tv/13') throw const AppFailure('网络失败');
        return tmdbResponse(uri, ambiguous: true);
      });
      expect(
        await catalog(transport).resolve('English Release Name', '2'),
        isNull,
      );
      expect(
        transport.calls.any((v) => v.uri.path.contains('/season/')),
        isFalse,
      );
    },
  );

  test(
    'missing season cannot borrow series artwork and truncated search cannot auto-select',
    () async {
      final transport = _Transport(
        (uri) => tmdbResponse(uri, missingSeason: true),
      );
      expect(
        await catalog(transport).resolve('English Release Name', '3'),
        isNull,
      );
      final broad = _Transport(
        (uri) => uri.path == '/3/search/tv'
            ? {...tmdbResponse(uri), 'total_pages': 2}
            : tmdbResponse(uri),
      );
      final refreshed = catalog(broad)..invalidateMetadataCaches();
      expect(await refreshed.resolve('English Release Name', '2'), isNull);
      expect(broad.calls.any((v) => v.uri.path == '/3/tv/12'), isFalse);
    },
  );

  test(
    'missing credential keeps Bangumi working; legacy helper switch does not disable joint lookup',
    () async {
      var secret = '';
      final transport = _Transport(tmdbResponse);
      final model = catalog(
        transport,
        provider: 'bangumi',
        credential: () async => secret,
      );
      expect(await model.resolve('English Release Name', '2'), isNull);
      expect(transport.calls.every((v) => v.uri.host == 'api.bgm.tv'), isTrue);
      secret = 'read-token';
      expect((await model.resolve('English Release Name', '2'))?['id'], 88);
      final disabled = _Transport(tmdbResponse);
      await catalog(
        disabled,
        provider: 'bangumi',
        assist: false,
      ).resolve('Other English Name', '2');
      expect(
        disabled.calls.any((v) => v.uri.host == 'api.themoviedb.org'),
        isTrue,
      );
    },
  );

  test(
    'manual source override is independent of preference and reports missing TMDB key',
    () async {
      final transport = _Transport(tmdbResponse);
      expect(
        (await catalog(
          transport,
          provider: 'bangumi',
        ).search('English Release Name', source: 'tmdb')).first['provider'],
        'tmdb',
      );
      final empty = _Transport(tmdbResponse);
      await expectLater(
        catalog(
          empty,
          credential: () async => '',
        ).search('English Release Name', source: 'tmdb'),
        throwsA(
          isA<AppFailure>().having(
            (v) => v.message,
            'message',
            contains('API Key'),
          ),
        ),
      );
      expect(empty.calls, isEmpty);
    },
  );

  test(
    'source URLs, full paths and control characters never reach TMDB even through direct adapter',
    () async {
      final transport = _Transport(tmdbResponse);
      final adapter = TmdbCatalog(transport, () async => 'read-token');
      for (final title in [
        'https://host/private.mkv?key=secret',
        '/private/home.mkv',
        r'C:\private\home.mkv',
        'name\nsecret',
      ]) {
        expect(await adapter.search(title), isEmpty);
        expect(await catalog(transport).resolve(title, '1'), isNull);
      }
      expect(transport.calls, isEmpty);
    },
  );

  test(
    'manual TMDB season adoption retains exact video progress and applies all series fields',
    () async {
      final root = Directory.systemTemp.createTempSync('tmdb-manual-');
      final model = AppModel(
        store..setLocal('settings', {'metadataStrategy': 'off'}),
        root,
      );
      try {
        final id = model.addMedia(
          'local',
          const SourceEntry(
            name: 'English Release Name S01E02.mkv',
            path: '/local/video.mkv',
            size: 100,
          ),
        );
        final media = store.get('media', id)!;
        store.save('progress', model.progressKey(media), {
          'position': 45,
          'duration': 100,
        });
        final full = await catalog(
          _Transport(tmdbOnlyResponse),
        ).resolve('English Release Name', '2');
        model.applyBangumi(
          'English Release Name',
          full!,
          season: '1',
          targetSeason: '2',
        );
        await model.fillEpisodeNames('English Release Name', full, season: '2');
        final updated = store.get('media', id)!;
        expect(updated.data['season'], '2');
        expect(updated.data['tmdbId'], '12');
        expect(updated.data['summary'], '中文简介');
        expect(model.progressFor(updated)?['position'], 45);
        expect(model.displayTitle(updated), contains('再次相遇'));
        expect(AppPreferences.defaults['tmdbNameAssist'], isTrue);
      } finally {
        model.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'manual matching sheet keeps catalogue search without fixed provider guidance',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('tmdb-dialog-');
      final transport = _Transport((uri) {
        expect(uri.host, 'api.bgm.tv');
        return {
          'list': [
            {
              'id': 66,
              'type': 2,
              'name': 'English Release Name',
              'name_cn': '中文作品',
            },
          ],
        };
      });
      final model = _DialogModel(
        store..setLocal('settings', {'metadataStrategy': 'off'}),
        root,
        transport,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showMetadataMatchDialog(
                    context,
                    model,
                    'English Release Name',
                    season: '2',
                  ),
                  child: const Text('匹配'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('匹配'));
        await tester.pumpAndSettle();
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.text('AI 自动识别'), findsOneWidget);
        expect(find.text('季度'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.byKey(const ValueKey('metadata-match-sheet')),
          findsOneWidget,
        );
        expect(find.textContaining('同时搜索 Bangumi 和 TMDB'), findsNothing);
        expect(find.textContaining('填写 TMDB API Key'), findsNothing);
        await tester.tap(find.byTooltip('搜索资料'));
        await tester.pumpAndSettle();
        expect(find.text('中文作品'), findsOneWidget);
        expect(
          find.textContaining('Bangumi · English Release Name'),
          findsOneWidget,
        );
        expect(transport.calls, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );
}
