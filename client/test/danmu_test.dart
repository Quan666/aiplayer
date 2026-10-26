import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/release_name.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/danmaku/layout.dart';
import 'package:aiplayer/data/store.dart';

class FakeTransport implements JsonTransport {
  final Future<Map<String, dynamic>> Function(
    Uri,
    String,
    Map<String, dynamic>?,
    CancelToken?,
  )
  handler;
  FakeTransport(this.handler);
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) => handler(uri, method, body, cancel);
}

void main() {
  test('layout is deterministic and prevents overlapping lane lifetimes', () {
    final values = [
      for (var i = 0; i < 100; i++)
        DanmakuComment(i / 4, '$i', 0xffffff, i % 3),
    ];
    final schedule = assignLanes(values, 4, presetFilter: false),
        ends = <int, double>{};
    expect(schedule, isNotEmpty);
    for (final item in schedule) {
      expect(
        item.start,
        greaterThanOrEqualTo(ends[item.lane] ?? double.negativeInfinity),
      );
      ends[item.lane] = item.start + item.duration;
    }
    expect(
      schedule.map((e) => [e.index, e.lane]),
      assignLanes(values, 4, presetFilter: false).map((e) => [e.index, e.lane]),
    );
  });
  test('release parsing handles filenames and special episodes', () {
    final cases = {
      '[Group] 在超市后门吸烟的二人 - 12 [1080p HEVC].mkv': ['在超市后门吸烟的二人', '', '12'],
      'Some.Show.S02E03.1080p.mkv': ['Some Show', '2', '3'],
      '[字幕组] 葬送的芙莉莲 [07][HEVC].mkv': ['葬送的芙莉莲', '', '7'],
      '某作品 第2季第4集.mkv': ['某作品', '2', '4'],
      'LIAR GAME 第二季': ['LIAR GAME', '2', ''],
      '[Nekomoe kissaten&LoliHouse] LIAR GAME - 04 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv':
          ['LIAR GAME', '', '4'],
      '作品 OVA1.mkv': ['作品', '', 'O1'],
    };
    for (final e in cases.entries) {
      final n = parseReleaseName(e.key);
      expect([n.anime, n.season, n.episode], e.value, reason: e.key);
    }
    expect(
      const ReleaseName('LIAR GAME', '', '4').matchName,
      'LIAR GAME S01E04',
    );
  });
  test('origin and token validation, credential-isolated cache', () {
    for (final value in [
      'http://example.com',
      'https://example.com/path',
      'https://user@example.com',
      'https://example.com/?x=1',
    ]) {
      expect(() => DanmuApiClient(value, 'secret'), throwsA(isA<AppFailure>()));
    }
    for (final token in ['', '../secret', 'bad/token']) {
      expect(
        () => DanmuApiClient(DanmuApiClient.defaultOrigin, token),
        throwsA(isA<AppFailure>()),
      );
    }
    expect(
      DanmuApiClient(DanmuApiClient.defaultOrigin, 'a').cacheKey('1'),
      isNot(DanmuApiClient(DanmuApiClient.defaultOrigin, 'b').cacheKey('1')),
    );
  });
  test(
    'search request, deduplication, filename-only match, comments query',
    () async {
      var calls = 0;
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture-secret',
        transport: FakeTransport((uri, method, body, cancel) async {
          calls++;
          expect(uri.path, startsWith('/fixture-secret/api/v2/'));
          if (uri.path.endsWith('search/episodes')) {
            expect(uri.queryParameters, {'anime': '星 & 月', 'episode': '3'});
            return {
              'animes': [
                {
                  'animeTitle': '星与月',
                  'episodes': [
                    {'episodeId': 123, 'episodeTitle': '第三集'},
                    {'episodeId': 123},
                    {'episodeId': '../x'},
                  ],
                },
              ],
            };
          }
          if (uri.path.endsWith('match')) {
            expect(method, 'POST');
            expect(body, {'fileName': '作品 S01E01'});
            return {
              'isMatched': true,
              'matches': [
                {'episodeId': '123', 'shift': 2.5},
              ],
            };
          }
          expect(uri.queryParameters, {
            'format': 'json',
            'withRelated': 'true',
            'chConvert': '0',
          });
          return {
            'comments': [
              {'p': '1,1,25,16777215,0,0,user,1', 'm': '弹幕'},
            ],
          };
        }),
      );
      expect((await api.search('星 & 月', episode: '3')).single.episodeId, '123');
      expect((await api.match('作品 S01E01')).matches.single.shift, 2.5);
      expect((await api.comments('123')).single.text, '弹幕');
      await expectLater(
        api.comments('../../secret'),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 3);
    },
  );
  test('search and match accept only valid optional comment counts', () async {
    final countFields = <Map<String, dynamic>>[
      {},
      {'commentCount': null},
      {'commentCount': 0},
      {'commentCount': 1245},
      {'commentCount': '27'},
      {'commentCount': '0'},
      {'commentCount': -1},
      {'commentCount': '-2'},
      {'commentCount': 1.5},
      {'commentCount': '1.5'},
      {'commentCount': ''},
      {'commentCount': 'NaN'},
      {'commentCount': true},
      {'commentCount': 3.0},
      {'count': 42, 'episodeCount': 12},
    ];
    final expected = <int?>[
      null,
      null,
      0,
      1245,
      27,
      0,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
    ];
    final entries = [
      for (var i = 0; i < countFields.length; i++)
        {'episodeId': i + 1, 'episodeTitle': '第${i + 1}集', ...countFields[i]},
    ];
    var calls = 0;
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: FakeTransport((uri, method, body, cancel) async {
        calls++;
        if (uri.path.endsWith('search/episodes')) {
          return {
            'animes': [
              {'animeTitle': '作品', 'episodes': entries},
            ],
          };
        }
        expect(uri.path, endsWith('/match'));
        return {'isMatched': false, 'matches': entries};
      }),
    );

    expect((await api.search('作品')).map((e) => e.commentCount), expected);
    expect(
      (await api.match('作品')).matches.map((e) => e.commentCount),
      expected,
    );
    expect(calls, 2);
  });
  test(
    'normalization preserves text, duplicates, colors, modes and user IDs',
    () {
      final comments = normalizeComments([
        {'p': '0.5,1,25,16777215,1710000000,0,online-user,42', 'm': '在线白色'},
        {'p': '2.5,5,16711680,user', 'm': '顶部'},
        {'p': '3,4,255,user', 'm': '底部'},
        {'p': '4,7,123,user', 'm': '脚本'},
        {'time': -1, 'text': 'invalid'},
        {'time': 9, 'text': ' a\nb ', 'color': 'url(bad)'},
      ]);
      expect(comments.map((c) => c.mode), [0, 1, 2, 0]);
      expect(comments.first.userId, 'online-user');
      expect(comments[1].color, 0xff0000);
      expect(comments.last.text, 'a b');
      final text = List.filled(1000, '完整弹幕').join();
      expect(
        normalizeComments([
          {'time': 500000, 'text': text},
        ]).single.text,
        text,
      );
      expect(
        normalizeComments([
          {'time': 1, 'text': 'x'},
          {'time': 1, 'text': 'x'},
        ]).length,
        2,
      );
    },
  );
  test('ambiguous match requires selection', () async {
    final store = AppStore(':memory:');
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: FakeTransport(
        (uri, method, body, cancel) async => uri.path.endsWith('match')
            ? {
                'isMatched': true,
                'matches': [
                  {'episodeId': 1},
                  {'episodeId': 2},
                ],
              }
            : {'animes': []},
      ),
    );
    final session = DanmakuSession(store, api, 'video');
    await session.identify(const ReleaseName('作品', '2', '3'));
    expect(session.episodeId, isNull);
    expect(session.candidates.length, 2);
    session.dispose();
    store.dispose();
  });
  test('late result cannot overwrite a new episode', () async {
    final first = Completer<Map<String, dynamic>>(),
        store = AppStore(':memory:');
    CancelToken? old;
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: FakeTransport((uri, method, body, cancel) async {
        if (uri.path.endsWith('/1')) {
          old = cancel;
          return first.future;
        }
        return {
          'comments': [
            {'time': 2, 'text': 'new'},
          ],
        };
      }),
    );
    final session = DanmakuSession(store, api, 'v');
    final pending = session.select(const EpisodeMatch('1', 'old', '1'));
    await session.select(const EpisodeMatch('2', 'new', '2'));
    first.complete({
      'comments': [
        {'time': 1, 'text': 'old'},
      ],
    });
    await pending;
    expect(old!.cancelled, true);
    expect(session.comments.single.text, 'new');
    expect(session.episodeId, '2');
    session.dispose();
    store.dispose();
  });
  test('refresh follows play state and replaces complete snapshots', () {
    fakeAsync((time) {
      var calls = 0;
      final store = AppStore(':memory:');
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: FakeTransport((uri, method, body, cancel) async {
          calls++;
          return {
            'comments': calls == 1
                ? [
                    {'time': 1, 'text': 'old'},
                    {'time': 2, 'text': 'deleted'},
                  ]
                : [
                    {'time': 1, 'text': 'edited'},
                  ],
          };
        }),
      );
      final session = DanmakuSession(store, api, 'v');
      const match = EpisodeMatch('1', '作品', '1', 0, 99);
      expect(session.candidateCommentCount(match), 99);
      session.select(match);
      time.flushMicrotasks();
      expect(session.candidateCommentCount(match), 2);
      session.configure(isPlaying: true);
      time.elapse(const Duration(seconds: 30));
      time.flushMicrotasks();
      expect(calls, 2);
      expect(session.comments.single.text, 'edited');
      expect(session.candidateCommentCount(match), 1);
      session.configure(isPlaying: false);
      time.elapse(const Duration(minutes: 2));
      expect(calls, 2);
      session.configure(isPlaying: true, show: false);
      time.elapse(const Duration(minutes: 2));
      expect(calls, 2);
      session.dispose();
      store.dispose();
    });
  });
  test('unchanged playback configuration does not fan out notifications', () {
    final store = AppStore(':memory:');
    final session = DanmakuSession(
      store,
      DanmuApiClient(DanmuApiClient.defaultOrigin, 'fixture'),
      'v',
    );
    addTearDown(store.dispose);
    addTearDown(session.dispose);
    var notifications = 0;
    session.addListener(() => notifications++);
    session.configure(show: true, isPlaying: false, seconds: 30);
    expect(notifications, 0);
    session.configure(isPlaying: true);
    expect(notifications, 1);
    for (var i = 0; i < 100; i++) {
      session.configure(show: true, isPlaying: true, seconds: 30);
    }
    expect(notifications, 1);
    session.configure(show: false);
    expect(notifications, 2);
    session.configure(show: false, seconds: 1);
    expect(notifications, 2);
  });
  test('unchanged 30-second snapshots preserve the list without notifying', () {
    fakeAsync((time) {
      var calls = 0, notifications = 0;
      final store = AppStore(':memory:');
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: FakeTransport((uri, method, body, cancel) async {
          calls++;
          return {
            'comments': [
              {
                'time': 28,
                'text': 'keep scrolling',
                'color': 0xff0000,
                'mode': 0,
                'userId': 'viewer',
              },
              {'time': 29, 'text': 'keep fixed', 'mode': 1},
            ],
          };
        }),
      );
      final session = DanmakuSession(store, api, 'v');
      session.select(const EpisodeMatch('1', '作品', '1'));
      time.flushMicrotasks();
      session.configure(isPlaying: true);
      final original = session.comments;
      session.addListener(() => notifications++);

      time.elapse(const Duration(seconds: 29));
      expect(calls, 1);
      time.elapse(const Duration(seconds: 1));
      time.flushMicrotasks();
      expect(calls, 2);
      expect(session.comments, same(original));
      expect(notifications, 0);

      time.elapse(const Duration(seconds: 30));
      time.flushMicrotasks();
      expect(calls, 3);
      expect(session.comments, same(original));
      expect(notifications, 0);
      session.dispose();
      store.dispose();
    });
  });
  test('pending refresh retains comments until an empty snapshot succeeds', () {
    fakeAsync((time) {
      var calls = 0, notifications = 0;
      final pending = Completer<Map<String, dynamic>>();
      final store = AppStore(':memory:');
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: FakeTransport((uri, method, body, cancel) async {
          calls++;
          if (calls > 1) return pending.future;
          return {
            'comments': [
              {'time': 28, 'text': 'keep while loading'},
            ],
          };
        }),
      );
      final session = DanmakuSession(store, api, 'v');
      session.select(const EpisodeMatch('1', '作品', '1'));
      time.flushMicrotasks();
      session.configure(isPlaying: true);
      final original = session.comments;
      session.addListener(() => notifications++);

      time.elapse(const Duration(seconds: 30));
      expect(calls, 2);
      expect(session.comments, same(original));
      expect(session.comments.single.text, 'keep while loading');
      expect(notifications, 0);

      time.elapse(const Duration(minutes: 2));
      expect(calls, 2);
      expect(session.comments, same(original));
      expect(notifications, 0);

      pending.complete({'comments': []});
      time.flushMicrotasks();
      expect(session.comments, isEmpty);
      expect(
        session.candidateCommentCount(
          const EpisodeMatch('1', '作品', '1', 0, 99),
        ),
        0,
      );
      expect(notifications, 1);
      session.dispose();
      store.dispose();
    });
  });
  test('429 backs off five minutes and keeps existing comments', () {
    fakeAsync((time) {
      var calls = 0;
      final store = AppStore(':memory:');
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: FakeTransport((uri, method, body, cancel) async {
          calls++;
          if (calls > 1) throw const AppFailure('limit', 429);
          return {
            'comments': [
              {'time': 1, 'text': 'keep'},
            ],
          };
        }),
      );
      final session = DanmakuSession(store, api, 'v');
      session.select(const EpisodeMatch('1', '作品', '1'));
      time.flushMicrotasks();
      final original = session.comments;
      session.configure(isPlaying: true);
      time.elapse(const Duration(seconds: 30));
      time.flushMicrotasks();
      expect(session.comments, same(original));
      expect(session.comments.single.text, 'keep');
      time.elapse(const Duration(seconds: 299));
      expect(calls, 2);
      session.dispose();
      store.dispose();
    });
  });
  test(
    '429 while rematching also delays background refresh of the previous episode',
    () {
      fakeAsync((time) {
        var calls = 0;
        final store = AppStore(':memory:');
        final api = DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: FakeTransport((uri, method, body, cancel) async {
            calls++;
            if (calls > 1) throw const AppFailure('limit', 429);
            return {
              'comments': [
                {'time': 1, 'text': 'keep'},
              ],
            };
          }),
        );
        final session = DanmakuSession(store, api, 'v');
        session.select(const EpisodeMatch('1', '作品', '1'));
        time.flushMicrotasks();
        session.configure(isPlaying: true);
        session.select(const EpisodeMatch('2', '作品', '2'));
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 299));
        expect(calls, 2);
        expect(session.episodeId, '1');
        expect(session.comments.single.text, 'keep');
        session.dispose();
        store.dispose();
      });
    },
  );
}
