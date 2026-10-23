import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/cache_maintenance.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  final started = Completer<void>();
  final reply = Completer<Map<String, dynamic>>();
  bool delayed = false;

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    if (delayed) {
      if (!started.isCompleted) started.complete();
      return reply.future;
    }
    return {
      'comments': [
        {'time': 1, 'text': 'initial'},
      ],
    };
  }
}

void main() {
  for (final operation in ['load', 'refresh']) {
    test(
      'cache clear during danmaku $operation keeps playback without late disk writes',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'danmaku-cache-clear-',
        );
        final store = AppStore('${directory.path}/store.db');
        final transport = _Transport();
        final api = DanmuApiClient(
          DanmuApiClient.defaultOrigin,
          'fixture',
          transport: transport,
        );
        final session = DanmakuSession(store, api, 'video');
        addTearDown(() async {
          session.dispose();
          store.dispose();
          await directory.delete(recursive: true);
        });
        const match = EpisodeMatch('1', 'Series', 'Episode', 0);
        if (operation == 'refresh') {
          await session.select(match);
          expect(store.cachedJson(api.cacheKey('1')), isNotNull);
          session.configure(isPlaying: true);
        }
        transport.delayed = true;
        final pending = operation == 'load'
            ? session.select(match)
            : session.refresh();
        await transport.started.future;
        await clearStoredCaches(store, directory);
        expect(store.cachedJson(api.cacheKey('1')), isNull);
        transport.reply.complete({
          'comments': [
            {'time': 2, 'text': 'late but visible'},
          ],
        });
        await pending;
        expect(session.comments.single.text, 'late but visible');
        expect(session.episodeId, '1');
        expect(session.busy, isFalse);
        expect(session.error, isEmpty);
        expect(store.cachedJson(api.cacheKey('1')), isNull);
        expect(store.get('match', 'video')?.data['episodeId'], '1');
        session.configure(isPlaying: true);
        await session.refresh();
        expect(
          store.cachedJson(api.cacheKey('1')),
          isNotNull,
          reason: 'A fresh attempt after the clear may cache normally',
        );
      },
    );
  }
}
