import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  final calls = <Uri>[];

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    calls.add(uri);
    return uri.host == 'api.bgm.tv' ? {'list': []} : {'results': []};
  }
}

void main() {
  const titles = [
    '用【循环利息】强制收回借出的魔力',
    'Fate/stay night',
    'Dr. STONE',
    'Re:ゼロから始める異世界生活',
    'Who? [Re:Start] #1 & 100%',
    'Apollo 13',
    'Rocky II',
  ];

  test('catalogue titles preserve symbols and title numbers', () {
    for (final title in titles) {
      expect(metadataQuery(title), title, reason: title);
      expect(metadataQuery(title, preserveSeason: false), title, reason: title);
    }
    expect(metadataQuery('作品 第二季'), '作品 第2季');
    expect(metadataQuery('作品 第二季', preserveSeason: false), '作品');
    expect(metadataQuery('[字幕组] Example - 01 [1080p HEVC].mkv'), 'Example');
    expect(
      metadataQuery('[字幕组] 用【循环利息】强制收回借出的魔力 - 01 [1080p HEVC].mkv'),
      '用【循环利息】强制收回借出的魔力',
    );
  });

  test('catalogue queries reject pasted source URLs and paths', () {
    for (final value in [
      '/private/video.mkv',
      '  /private/video.mkv ',
      r'C:\Users\name\video.mkv',
      'C:/Users/name/video.mkv',
      './private/video.mkv',
      '../private/video.mkv',
      '~/private/video.mkv',
      'https://host/video.mkv?secret=abc',
      'file:/private/video.mkv',
      'data:video/private',
      'name\nvideo',
    ]) {
      expect(metadataQuery(value), isEmpty, reason: value);
    }
  });

  test('AI titles reach Bangumi and TMDB as intact escaped queries', () async {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    final transport = _Transport();
    final catalog = LibraryCatalog(
      store,
      transport: transport,
      tmdbNameAssist: () => false,
      tmdbCredential: () async => 'test-token',
    );
    for (final title in titles) {
      transport.calls.clear();
      await searchAiCatalogIdentity(
        AiMediaIdentity(name: title),
        catalog: catalog,
        mediaAi: MediaAiRecognition(store),
        config: SubtitleAiConfig(model: 'test-model'),
        cancel: CancelToken(),
      );
      final bangumi = transport.calls.singleWhere(
        (uri) => uri.host == 'api.bgm.tv',
      );
      expect(bangumi.pathSegments, ['search', 'subject', title]);
      expect(bangumi.fragment, isEmpty);
      final tmdb = transport.calls.where(
        (uri) => uri.host == 'api.themoviedb.org',
      );
      expect(tmdb, hasLength(2));
      expect(
        tmdb.every((uri) => uri.queryParameters['query'] == title),
        isTrue,
      );
    }
  });
}
