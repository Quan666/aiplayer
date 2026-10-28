import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'automatic search and match transmit the entire recognized title',
    () async {
      const title = '用【循环利息】强制收回借出的魔力 / Fate [Unlimited] & 100% #?!';
      final store = AppStore(':memory:');
      final transport = _Transport();
      final api = DanmuApiClient(
        DanmuApiClient.defaultOrigin,
        'fixture',
        transport: transport,
      );
      final session = DanmakuSession(store, api, 'video');
      addTearDown(store.dispose);
      addTearDown(session.dispose);

      await session.identify(const ReleaseName(title, '', '3'));

      expect(transport.searches.single.queryParameters, {
        'anime': title,
        'episode': '3',
      });
      expect(transport.matches, ['$title S01E03']);
    },
  );

  test('raw file matching still strips directories', () async {
    final transport = _Transport();
    final api = DanmuApiClient(
      DanmuApiClient.defaultOrigin,
      'fixture',
      transport: transport,
    );

    await api.match('/private/videos/作品 S01E03.mkv');
    await api.match(r'C:\private\videos\作品 S01E04.mkv');

    expect(transport.matches, ['作品 S01E03.mkv', '作品 S01E04.mkv']);
  });

  test(
    'mixed encoded release repairs its saved title before matching episode four',
    () async {
      final store = AppStore(':memory:');
      final transport = _Transport();
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

      await session.identify(
        mediaRecordIdentity({
          'fileName':
              '2026-10/世界最强的魔女，就此开始/世界最强的魔女，就此开始%20-%20E04%20[ANi]%20[繁体].mp4',
          'series': '世界最强的魔女，就此开始%20-%20E04%20[ANi]%20',
        }),
      );

      expect(transport.searches.single.queryParameters, {
        'anime': '世界最强的魔女，就此开始',
        'episode': '4',
      });
      expect(transport.matches, ['世界最强的魔女，就此开始 S01E04']);
    },
  );
}

class _Transport implements JsonTransport {
  final searches = <Uri>[];
  final matches = <String>[];

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    if (uri.path.endsWith('search/episodes')) {
      searches.add(uri);
      return {'animes': []};
    }
    if (uri.path.endsWith('match')) {
      matches.add(body!['fileName'] as String);
      return {'isMatched': false, 'matches': []};
    }
    throw StateError('Unexpected request: ${uri.path}');
  }
}
