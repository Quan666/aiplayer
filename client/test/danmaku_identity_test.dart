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
