import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'real-server-integration-token-with-24-characters';
final _binary = File(
  Platform.environment['AIPLAYER_SYNC_TEST_BINARY'] ??
      '../artifacts/aiplayer-sync-linux-amd64',
).absolute;

void main() {
  // These ordinary tests intentionally do not initialize the widget binding,
  // whose HTTP override would replace the real loopback transport with mocks.
  final Object skip = !Platform.isLinux || !_binary.existsSync()
      ? 'Requires the Linux amd64 release sync-service binary.'
      : false;

  test(
    'real Go service shares encrypted profiles and video state, resolves conflicts and deletions',
    () async {
      final server = await _GoServer.start();
      final first = _Device(server, 'first');
      final second = _Device(server, 'second');
      first.seedRemote();
      second.seedLocal();
      second.settings({'syncOrigin': 'https://device-local-bootstrap.example'});

      await first.sync();
      final published = await server.changes();
      final wire = jsonEncode(published);
      for (final privateValue in [
        'private-ai-key',
        'private-tmdb-key',
        'private-danmu-key',
        'private-nas-password',
        'private-nas.example',
        'Series/E01.mkv',
      ]) {
        expect(wire, isNot(contains(privateValue)));
      }
      expect(
        (published['changes'] as List).where((row) => row['kind'] == 'vault'),
        isNotEmpty,
      );

      await second.sync();
      expect(
        (await server.changes())['cursor'],
        (published['cursor'] as int) + 1,
      );
      expect(second.store.local('settings'), {
        'syncOrigin': 'https://device-local-bootstrap.example',
        'metadataStrategy': 'balanced',
        'aiSubtitleModel': 'translation-model',
        'aiSubtitleOrigin': 'https://api.example.com/v1',
      });
      for (final key in SyncProfile.secretKeys) {
        expect(second.secrets.values[key], first.secrets.values[key]);
      }
      expect(second.secrets.values['source:nas'], 'private-nas-password');
      expect(second.secrets.values['syncToken'], isNull);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(second.store.local('appearance:theme'), 'dark');
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(second.store.local('episodeTitle:remote-video'), '相逢');
      expect(second.store.local('manualMetadata:remote-video'), true);
      for (final kind in ['media', 'match']) {
        expect(
          second.store.get(kind, 'remote-video')!.data,
          first.store.get(kind, 'remote-video')!.data,
        );
      }
      expect(
        second.store.get('progress', 'remote-video:64')!.data['position'],
        42,
      );
      expect(
        second.store
            .get(
              'watched',
              _watchedKey(first.store.get('media', 'remote-video')!),
            )!
            .data['watched'],
        true,
      );
      expect(SourceFavorites(second.store).contains('nas', 'Series/'), true);
      expect(first.store.get('media', 'local-only'), isNull);
      expect(second.store.get('media', 'local-only')!.data['title'], '本机视频');

      second.settings({'metadataStrategy': 'conservative'});
      second.secrets.values['aiSubtitleToken'] = 'updated-private-key';
      second.store.save('progress', 'remote-video:64', {
        'position': 84,
        'duration': 100,
        'updatedAt': '2026-10-22T10:00:00Z',
      });
      second.store.setLocal('episodeTitle:remote-video', '更新的小标题');
      await second.sync();
      await first.sync();
      expect(first.store.get('media', 'local-only')!.data['title'], '本机视频');
      expect(first.store.local('location:local-only'), isNull);
      expect(first.store.get('progress', 'local-only:8'), isNull);
      expect(
        (first.store.local('settings') as Map)['metadataStrategy'],
        'conservative',
      );
      expect(first.secrets.values['aiSubtitleToken'], 'updated-private-key');
      expect(
        first.store.get('progress', 'remote-video:64')!.data['position'],
        84,
      );
      expect(first.store.local('episodeTitle:remote-video'), '更新的小标题');

      first.settings({'aiSubtitleModel': 'server-choice'});
      second.settings({'aiSubtitleModel': 'offline-choice'});
      await first.sync();
      await second.sync();
      expect(second.store.conflicts, isEmpty);
      expect(
        (second.store.local('settings') as Map)['aiSubtitleModel'],
        'offline-choice',
      );
      await first.sync();
      expect(
        (first.store.local('settings') as Map)['aiSubtitleModel'],
        'offline-choice',
      );

      first.store.setLocal('settings', {'syncOrigin': server.origin});
      first.store.setLocal('sources', []);
      first.store.setLocal(SourceFavorites.storageKey, []);
      first.store.removeLocal('location:remote-video');
      first.store.removeLocal('episodeTitle:remote-video');
      first.store.removeLocal('manualMetadata:remote-video');
      first.store.removeLocal('appearance:theme');
      for (final key in [...SyncProfile.secretKeys, 'source:nas']) {
        first.secrets.values.remove(key);
      }
      for (final kind in ['media', 'match']) {
        first.store.save(kind, 'remote-video', {}, deleted: true);
      }
      first.store.save('progress', 'remote-video:64', {}, deleted: true);
      await first.sync();
      await second.sync();
      expect(second.store.local('sources'), isEmpty);
      expect(second.secrets.values['aiSubtitleToken'], isNull);
      expect(second.secrets.values['source:nas'], isNull);
      expect(second.store.local('location:remote-video'), isNull);
      expect(second.store.local('episodeTitle:remote-video'), isNull);
      expect(second.store.local('appearance:theme'), isNull);
      expect(second.store.get('media', 'remote-video')!.deleted, true);
      expect(second.store.get('match', 'remote-video')!.deleted, true);
      expect(second.store.get('progress', 'remote-video:64')!.deleted, true);
      expect(SourceFavorites(second.store).all.single.sourceId, 'local');
      expect(second.store.get('media', 'local-only')!.deleted, false);
      expect(second.store.local('settings'), {
        'syncOrigin': 'https://device-local-bootstrap.example',
      });
      expect(first.store.conflicts, isEmpty);
      expect(second.store.conflicts, isEmpty);
      final allChanges = jsonEncode(await server.changes());
      expect(allChanges, contains('local-only'));
      expect(allChanges, isNot(contains('/device/private.mkv')));
      expect(allChanges, isNot(contains('local-only:8')));
    },
    skip: skip,
  );

  test(
    'real server syncs all-video sorting in both directions across restart and reset',
    () async {
      final server = await _GoServer.start();
      final first = _Device(server, 'first');
      final second = _Device(server, 'second');
      AppPreferences preferences(_Device device) => AppPreferences(
        Map<String, dynamic>.from(device.store.local('settings') ?? {}),
      );

      first.settings({
        'librarySortField': 'name',
        'librarySortDescending': false,
      });
      await first.sync();
      await second.sync();
      expect(preferences(second).librarySortField, 'name');
      expect(preferences(second).librarySortDescending, isFalse);
      final published = (await server.changes())['changes'] as List;
      expect(published, hasLength(2));
      expect(published.every((row) => row['kind'] == 'vault'), isTrue);
      expect(jsonEncode(published), isNot(contains('librarySortField')));

      second.settings({
        'librarySortField': 'modified',
        'librarySortDescending': true,
      });
      await second.sync();
      await first.sync();
      expect(preferences(first).librarySortField, 'modified');
      expect(preferences(first).librarySortDescending, isTrue);

      await server.restart(_token);
      final fresh = _Device(server, 'fresh');
      await fresh.sync();
      expect(preferences(fresh).librarySortField, 'modified');
      expect(preferences(fresh).librarySortDescending, isTrue);

      first.store.setLocal('settings', <String, dynamic>{});
      await first.sync();
      await second.sync();
      await fresh.sync();
      for (final device in [first, second, fresh]) {
        expect(preferences(device).librarySortField, 'recent');
        expect(preferences(device).librarySortDescending, isTrue);
        expect(device.store.conflicts, isEmpty);
      }
    },
    skip: skip,
  );

  test(
    'real server preserves new public metadata and unknown kinds through client sync',
    () async {
      final server = await _GoServer.start();
      final first = _Device(server, 'first')..seedRemote();
      final second = _Device(server, 'second');
      const details = {
        'schemaRevision': 2,
        'chapters': [
          {'name': 'Opening', 'begin': 0},
          {'name': 'Episode', 'begin': 90},
        ],
        'publicId': 9007199254740993,
      };
      first.store.save('media', 'remote-video', {
        ...first.store.get('media', 'remote-video')!.data,
        'publicDetails': details,
      });
      await first.sync();
      await second.sync();
      expect(
        second.store.get('media', 'remote-video')!.data['publicDetails'],
        details,
      );

      second.store.save('media', 'remote-video', {
        ...second.store.get('media', 'remote-video')!.data,
        'title': 'Updated title',
      });
      await second.sync();
      await first.sync();
      expect(
        first.store.get('media', 'remote-video')!.data['publicDetails'],
        details,
      );
      expect(
        first.store.get('media', 'remote-video')!.data['title'],
        'Updated title',
      );

      await IoJsonTransport().send(
        Uri.parse('${server.origin}/v1/records'),
        method: 'PUT',
        headers: {'Authorization': 'Bearer $_token'},
        body: {
          'id': 'future-collection',
          'kind': 'collection.v2',
          'version': 0,
          'data': details,
        },
      );
      await server.restart(_token);
      final fresh = _Device(server, 'fresh');
      await fresh.sync();
      expect(
        fresh.store.get('media', 'remote-video')!.data['publicDetails'],
        details,
      );
      expect(
        fresh.store.get('collection.v2', 'future-collection')!.data,
        details,
      );
      expect(
        fresh.store.local('syncCursor:${server.origin}'),
        (await server.changes())['cursor'],
      );
      expect(fresh.store.conflicts, isEmpty);
    },
    skip: skip,
  );

  test(
    'real server lightweight sync publishes NAS playback dependencies before media',
    () async {
      final server = await _GoServer.start();
      final first = _Device(server, 'first');
      final second = _Device(server, 'second');
      first.seedRemote();

      await first.client.synchronize(server.origin, _token, sharedOnly: true);
      final changes = (await server.changes())['changes'] as List;
      final sourceIndex = changes.indexWhere(
        (row) => row['kind'] == 'vault' && row['id'].startsWith('source:'),
      );
      final bindingIndex = changes.indexWhere(
        (row) => row['kind'] == 'vault' && row['id'].startsWith('binding:'),
      );
      final mediaIndex = changes.indexWhere(
        (row) => row['kind'] == 'media' && row['id'] == 'remote-video',
      );
      expect(sourceIndex, greaterThanOrEqualTo(0));
      expect(bindingIndex, greaterThan(sourceIndex));
      expect(mediaIndex, greaterThan(bindingIndex));

      await second.client.synchronize(server.origin, _token, sharedOnly: true);

      expect(second.store.get('media', 'remote-video')!.deleted, false);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(second.secrets.values['source:nas'], 'private-nas-password');
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(second.store.local('episodeTitle:remote-video'), '相逢');
      expect(second.store.local('settings'), isNull);
      expect(second.store.conflicts, isEmpty);
    },
    skip: skip,
  );

  test(
    'real server restart and token rotation preserve SQLite history for a fresh device',
    () async {
      final server = await _GoServer.start();
      final first = _Device(server, 'first');
      first.settings({'aiSubtitleModel': 'persistent-model'});
      first.secrets.values['aiSubtitleToken'] = 'persistent-private-key';
      await first.sync();
      final cursor = (await server.changes())['cursor'] as int;

      const replacement = 'rotated-real-server-token-with-24-characters';
      await server.restart(replacement);
      await expectLater(
        first.sync(),
        throwsA(
          isA<AppFailure>().having((error) => error.status, 'status', 401),
        ),
      );
      await first.sync(token: replacement);
      final fresh = _Device(server, 'fresh');
      await fresh.sync(token: replacement);
      expect(
        (fresh.store.local('settings') as Map)['aiSubtitleModel'],
        'persistent-model',
      );
      expect(fresh.secrets.values['aiSubtitleToken'], 'persistent-private-key');
      final history = await server.changes(token: replacement);
      expect(history['cursor'], greaterThan(cursor));
      expect(
        fresh.store.local('syncCursor:${server.origin}'),
        history['cursor'],
      );
      expect(fresh.store.conflicts, isEmpty);
    },
    skip: skip,
  );
}

String _watchedKey(SyncRecord record) => sha256
    .convert(
      utf8.encode(
        '${record.data['series']}:${record.data['season']}:${record.data['episode']}',
      ),
    )
    .toString();

class _GoServer {
  final Directory directory;
  final int port;
  Process? _process;
  final _logs = StringBuffer();
  _GoServer(this.directory, this.port);
  String get origin => 'http://127.0.0.1:$port';

  static Future<_GoServer> start() async {
    final directory = await Directory.systemTemp.createTemp(
      'aiplayer-sync-e2e-',
    );
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final server = _GoServer(directory, port);
    addTearDown(() async {
      await server.stop();
      await directory.delete(recursive: true);
    });
    await server.restart(_token);
    return server;
  }

  Future<void> restart(String token) async {
    await stop();
    final process = await Process.start(
      _binary.path,
      [],
      environment: {
        'SYNC_ADDR': '127.0.0.1:$port',
        'SYNC_DB': '${directory.path}/server.sqlite',
        'SYNC_TOKEN': token,
      },
    );
    _process = process;
    process.stdout.transform(utf8.decoder).listen(_logs.write);
    process.stderr.transform(utf8.decoder).listen(_logs.write);
    int? exited;
    unawaited(
      process.exitCode.then((code) {
        exited = code;
      }),
    );
    final transport = IoJsonTransport(inactivity: const Duration(seconds: 1));
    for (var attempt = 0; attempt < 100; attempt++) {
      if (exited != null) {
        throw StateError('Go sync service exited ($exited): $_logs');
      }
      try {
        final health = await transport.send(Uri.parse('$origin/healthz'));
        if (health['ok'] == true) return;
      } on AppFailure {
        // The child may still be opening the temporary SQLite database.
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Go sync service did not become healthy: $_logs');
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<Map<String, dynamic>> changes({String token = _token}) =>
      IoJsonTransport().send(
        Uri.parse('$origin/v1/changes?after=0'),
        headers: {'Authorization': 'Bearer $token'},
      );
}

class _Device {
  final _GoServer server;
  final AppStore store;
  final secrets = _MemorySecrets();
  late final SyncClient client;
  _Device(this.server, String name)
    : store = AppStore('${server.directory.path}/$name.sqlite') {
    addTearDown(store.dispose);
    client = SyncClient(
      store,
      profile: SyncProfile(store, secrets, watchedKey: _watchedKey),
      transport: IoJsonTransport(),
    );
  }
  Future<void> sync({String token = _token}) =>
      client.synchronize(server.origin, token);
  void settings(Map<String, dynamic> patch) => store.setLocal('settings', {
    ...?store.local('settings') as Map?,
    ...patch,
  });

  void seedRemote() {
    settings({
      'syncOrigin': server.origin,
      'metadataStrategy': 'balanced',
      'aiSubtitleModel': 'translation-model',
      'aiSubtitleOrigin': 'https://api.example.com/v1',
    });
    secrets.values.addAll({
      'aiSubtitleToken': 'private-ai-key',
      'tmdb.apiKey': 'private-tmdb-key',
      'danmuToken': 'private-danmu-key',
      'source:nas': 'private-nas-password',
      'syncToken': _token,
    });
    store.setLocal('sources', [
      {
        'id': 'nas',
        'kind': 'webdav',
        'url': 'https://private-nas.example/dav/',
        'label': 'NAS',
        'username': 'user',
      },
    ]);
    store.setLocal('appearance:theme', 'dark');
    store.save('media', 'remote-video', {
      'title': '示例第一集',
      'series': '示例系列',
      'season': '1',
      'episode': '1',
      'fileName': 'E01.mkv',
      'size': 64,
      'bangumiId': '12',
      'metadataProvider': 'bangumi',
      'metadataTitle': '识别后的名称',
      'rating': 8.5,
      'totalEpisodes': 12,
      'genres': ['动画'],
    });
    store.setLocal('location:remote-video', {
      'id': 'remote-video',
      'source': 'nas',
      'path': 'Series/E01.mkv',
      'size': 64,
      'modified': 123,
    });
    store.setLocal('episodeTitle:remote-video', '相逢');
    store.setLocal('manualMetadata:remote-video', true);
    SourceFavorites(store).toggle(
      const SourceFavorite(sourceId: 'nas', path: 'Series/', name: '剧集'),
    );
    store.save('progress', 'remote-video:64', {
      'position': 42,
      'duration': 100,
    });
    store.save('match', 'remote-video', {
      'provider': 'https://danmu.example.com',
      'episodeId': '123',
      'label': '第1集',
      'shift': 0,
      'offset': 0,
    });
    store.save('watched', _watchedKey(store.get('media', 'remote-video')!), {
      'watched': true,
    });
  }

  void seedLocal() {
    store.save('media', 'local-only', {'title': '本机视频'});
    store.setLocal('location:local-only', {
      'id': 'local-only',
      'source': 'local',
      'path': '/device/private.mkv',
      'size': 8,
    });
    store.save('progress', 'local-only:8', {'position': 3, 'duration': 8});
    SourceFavorites(store).toggle(
      const SourceFavorite(sourceId: 'local', path: '/private/', name: '本机'),
    );
  }
}

class _MemorySecrets extends FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);
}
