import 'dart:io';

import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct link names exclude URL credentials, query and parent path', () {
    expect(
      directLinkDisplayName(
        'https://cdn.example/token-secret/%E7%AC%AC01%E9%9B%86.mkv?token=private#fragment',
      ),
      '第01集.mkv',
    );
    expect(
      directLinkDisplayName(
        'https://cdn.example/download?file=title.mp4&token=secret',
      ),
      'cdn.example',
    );
    expect(
      directLinkDisplayName('https://user:secret@cdn.example/'),
      'cdn.example',
    );
    expect(directLinkDisplayName('https://cdn.example'), 'cdn.example');
    expect(
      directLinkDisplayName('https://cdn.example/token-value/'),
      'cdn.example',
    );
    expect(
      directLinkDisplayName(
        'https://cdn.example/clip.mp4',
        preferred: ' 我的影片 ',
      ),
      '我的影片',
    );
    expect(directLinkDisplayName('not a URL'), '视频直链');
  });

  test('invalid escaped UTF-8 filenames safely fall back to host', () {
    for (final path in ['%FF.mkv', '%C3%28.mp4', '%E4%B8.mkv']) {
      expect(
        directLinkDisplayName('https://cdn.example/$path?token=secret'),
        'cdn.example',
      );
    }
    expect(
      directLinkDisplayName('https://cdn.example/%FF.mkv', preferred: '我的视频'),
      '我的视频',
    );
  });

  test('HTTP stat supplies custom display name to media import', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.contentLength = 1024;
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/episode.mkv?token=private';
    final named = HttpSource(url, displayName: '海边的故事 第 1 集');
    final unnamed = HttpSource(url);
    final root = HttpSource('http://127.0.0.1:${server.port}');
    try {
      expect((await named.stat('')).name, '海边的故事 第 1 集');
      expect((await unnamed.stat('')).name, 'episode.mkv');
      expect((await root.stat('')).name, '127.0.0.1');
    } finally {
      await named.close();
      await unnamed.close();
      await root.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
