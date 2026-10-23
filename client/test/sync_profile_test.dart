import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/credential_storage.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _origin = 'https://sync.example.com';
const _token = 'synchronization-token-at-least-24-characters';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a new catalogue waits for deferred bindings before its first upload',
    () async {
      final server = _SyncServer();
      final first = _Device(server)..seedRemote();
      final second = _Device(server)..seedLocal('remote-video');
      await first.sync();
      await second.profile.unlock(_origin, _token);
      await second.profile.prepare();
      final puts = server.puts;
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        deferProfile: true,
      );
      expect(server.puts, puts);
      expect(server.records['media:remote-video']!.data['title'], '示例第一集');
      await second.sync();
      expect(server.records['media:remote-video']!.data['title'], '示例第一集');
      expect(second.store.get('media', 'remote-video')!.data['title'], '本地文件');
    },
  );

  test(
    'local catalogue edits and deletions converge without sharing files or progress',
    () async {
      final server = _SyncServer();
      final first = _Device(server)..seedLocal('local-catalogue');
      final second = _Device(server);
      final original = first.store.get('media', 'local-catalogue')!;
      first.store.save('media', original.id, {
        ...original.data,
        'fileName': 'Episode.mkv',
        'size': 12,
        'poster': 'https://images.example/poster.jpg',
        'path': '/device/private/should-never-sync.mkv',
        'accessToken': 'private-file-token',
      });
      final location = first.store.local('location:${original.id}');
      await first.sync();
      await second.sync();
      final received = second.store.get('media', original.id)!;
      expect(received.data['title'], original.data['title']);
      expect(received.data['poster'], 'https://images.example/poster.jpg');
      expect(second.store.local('location:${original.id}'), isNull);
      expect(second.store.all('progress'), isEmpty);
      expect(second.store.all('watched'), isEmpty);
      final wire = jsonEncode(
        server.records.values.map((r) => r.toJson()).toList(),
      );
      expect(wire, isNot(contains('/device/private')));
      expect(wire, isNot(contains('private-file-token')));
      expect(wire, isNot(contains('localOnly')));

      second.store.save('media', received.id, {
        ...received.data,
        'title': '改名',
      });
      await second.sync();
      await first.sync();
      expect(first.store.get('media', original.id)!.data['title'], '改名');
      expect(first.store.local('location:${original.id}'), location);
      expect(
        first.store.get('progress', '${original.id}:12')!.data['position'],
        10,
      );

      second.store.save('media', received.id, received.data, deleted: true);
      await second.sync();
      await first.sync();
      expect(first.store.get('media', original.id)!.deleted, true);
      expect(first.store.local('location:${original.id}'), location);
      final puts = server.puts;
      await first.sync();
      await second.sync();
      expect(server.puts, puts);
    },
  );

  test(
    'removing a local catalogue file on its original device synchronizes the removal',
    () async {
      final server = _SyncServer();
      final first = _Device(server)..seedLocal('local-catalogue');
      final second = _Device(server);
      await first.sync();
      await second.sync();
      first.store.save('media', 'local-catalogue', {}, deleted: true);
      first.store.removeLocal('location:local-catalogue');
      await first.sync();
      await second.sync();
      expect(second.store.get('media', 'local-catalogue')!.deleted, true);
      expect(server.records['media:local-catalogue']!.deleted, true);
    },
  );

  test(
    'a downloaded catalogue can use a different local file and still synchronize edits',
    () async {
      final server = _SyncServer();
      final first = _Device(server)..seedLocal('local-catalogue');
      final second = _Device(server);
      await first.sync();
      await second.sync();
      final record = second.store.get('media', 'local-catalogue')!;
      second.store.setLocal('location:${record.id}', {
        'id': record.id,
        'source': 'local',
        'path': '/other-device/linked.mkv',
        'size': 12,
      });
      second.profile.rememberLocalMedia(record.id);
      second.store.save('media', record.id, {
        ...record.data,
        'title': '本机关联后改名',
      });
      await second.sync();
      await first.sync();
      expect(first.store.get('media', record.id)!.data['title'], '本机关联后改名');
      expect(
        second.store.local('location:${record.id}')['path'],
        '/other-device/linked.mkv',
      );
      expect(
        first.store.local('location:${record.id}')['path'],
        '/device/private/${record.id}.mkv',
      );
      second.store.save('media', record.id, record.data, deleted: true);
      second.store.removeLocal('location:${record.id}');
      await second.sync();
      await first.sync();
      expect(first.store.get('media', record.id)!.deleted, true);
      expect(
        jsonEncode(server.records.values.map((r) => r.toJson()).toList()),
        isNot(contains('/other-device')),
      );
    },
  );

  test(
    'external link sessions never publish their source, binding or media',
    () async {
      final server = _SyncServer();
      final device = _Device(server);
      device.store.setLocal('externalSource:external-one', {
        'id': 'external-one',
        'kind': 'http',
        'url': 'https://private.example/video?token=private',
        'transient': true,
      });
      device.store.save('media', 'temporary-one', {
        'title': 'External video',
        'localOnly': true,
        'transient': true,
      });
      device.store.setLocal('location:temporary-one', {
        'id': 'temporary-one',
        'source': 'external-one',
        'path': '',
        'size': 12,
      });
      await device.sync();
      expect(server.records, isEmpty);
      expect(device.store.all('media'), isEmpty);
      expect(device.store.local('syncProfile:localMedia'), isEmpty);
      expect(device.store.local('syncProfile:remoteMedia'), isEmpty);
    },
  );

  test(
    'cancelling a full snapshot yields to input and preserves staged baselines',
    () async {
      final device = _Device(_SyncServer());
      device.settings({for (var i = 0; i < 80; i++) 'option$i': i});
      await device.profile.unlock(_origin, _token);
      final cancel = CancelToken();
      Timer.run(cancel.cancel);
      await expectLater(
        device.profile.prepare(cancel: cancel),
        throwsA(isA<Cancelled>()),
      );
      final staged = device.store.records('vault');
      expect(staged.length, inExclusiveRange(0, 80));
      expect(
        (device.store.local('syncProfile:baseline') as Map).length,
        staged.length,
      );
      await device.profile.prepare();
      expect(device.store.records('vault').length, 80);
      for (final record in staged) {
        expect(device.store.get('vault', record.id)!.revision, record.revision);
      }
    },
  );

  test(
    'playback downloads defer vault application until the next full sync',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        deferProfile: true,
      );
      expect(second.store.get('progress', 'remote-video:64'), isNotNull);
      expect(second.store.records('vault'), isNotEmpty);
      expect(second.store.local('settings'), isNull);
      expect(second.store.local('sources'), isNull);
      expect(second.client.profileRevision, 0);
      final cursor = second.store.local('syncCursor:$_origin');

      await second.sync();
      expect(second.store.local('syncCursor:$_origin'), cursor);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(
        (second.store.local('settings') as Map)['metadataStrategy'],
        'balanced',
      );
      expect(second.client.profileRevision, 1);
    },
  );

  test(
    'shared polling restores deferred bindings without downloading new changes',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        deferProfile: true,
      );
      expect(second.store.get('media', 'remote-video'), isNotNull);
      expect(second.store.local('sources'), isNull);
      expect(second.store.local('location:remote-video'), isNull);
      final cursor = second.store.local('syncCursor:$_origin');
      expect(cursor, server.changes.length);

      final restarted = SyncClient(
        second.store,
        profile: SyncProfile(
          second.store,
          second.secrets,
          watchedKey: second.profile.watchedKey,
        ),
        transport: server,
      );
      await restarted.synchronize(_origin, _token, sharedOnly: true);
      expect(second.store.local('syncCursor:$_origin'), cursor);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(second.secrets.values['source:nas'], 'nas-password');
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(restarted.profileRevision, 1);

      await restarted.synchronize(_origin, _token, sharedOnly: true);
      expect(restarted.profileRevision, 1);
    },
  );

  test(
    'deferred remote settings and bindings converge to the latest local edit',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.sync();
      first.settings({'metadataStrategy': 'off'});
      first.store.setLocal('episodeTitle:remote-video', 'Remote edit');
      await first.sync();
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        deferProfile: true,
      );
      second.settings({'metadataStrategy': 'conservative'});
      second.store.setLocal('episodeTitle:remote-video', 'Local edit');
      final puts = server.puts;
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        artworkIds: {'remote-video'},
        deferProfile: true,
      );
      expect(server.puts, puts);
      await second.sync();
      expect(server.puts, greaterThan(puts));
      expect(second.store.conflicts, isEmpty);
      expect(second.store.local('episodeTitle:remote-video'), 'Local edit');
      expect(
        (second.store.local('settings') as Map)['metadataStrategy'],
        'conservative',
      );
      final third = _Device(server);
      await third.sync();
      expect(third.store.local('episodeTitle:remote-video'), 'Local edit');
      expect(
        (third.store.local('settings') as Map)['metadataStrategy'],
        'conservative',
      );
    },
  );

  test(
    'preparing an active video without a local location keeps its binding',
    () async {
      final device = _Device(_SyncServer());
      device.seedRemote();
      await device.sync();
      final binding = device.store
          .records('vault')
          .singleWhere((record) => record.id.startsWith('binding:'));
      device.store.removeLocal('location:remote-video');

      await device.profile.prepare();

      final current = device.store.get('vault', binding.id)!;
      expect(current.deleted, false);
      expect(current.dirty, false);
      expect(current.revision, binding.revision);
      expect(device.store.get('media', 'remote-video')!.deleted, false);
    },
  );

  test('deleting a video still deletes its shared binding', () async {
    final server = _SyncServer();
    final first = _Device(server), second = _Device(server);
    first.seedRemote();
    await first.sync();
    await second.sync();
    final binding = first.store
        .records('vault')
        .singleWhere((record) => record.id.startsWith('binding:'));
    first.store.save('media', 'remote-video', {}, deleted: true);
    first.store.removeLocal('location:remote-video');

    await first.sync();
    await second.sync();

    expect(server.records['vault:${binding.id}']!.deleted, true);
    expect(second.store.get('vault', binding.id)!.deleted, true);
    expect(second.store.get('media', 'remote-video')!.deleted, true);
    expect(second.store.local('location:remote-video'), isNull);
    expect(second.store.conflicts, isEmpty);
  });

  test(
    'applying a live binding does not treat a missing location as deletion',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.sync();
      first.store.setLocal('episodeTitle:remote-video', 'Updated title');
      await first.sync();
      second.store.removeLocal('location:remote-video');
      await second.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        deferProfile: true,
      );
      final binding = second.store
          .records('vault')
          .singleWhere((record) => record.id.startsWith('binding:'));
      expect(second.store.local('location:remote-video'), isNull);

      await second.profile.apply();

      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(second.store.local('episodeTitle:remote-video'), 'Updated title');
      final current = second.store.get('vault', binding.id)!;
      expect(current.deleted, false);
      expect(current.dirty, false);
      expect(current.version, binding.version);
      expect(second.store.conflicts, isEmpty);
    },
  );

  test(
    'artwork checkpoint stages only selected bindings and sources',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      // An invalid unrelated binding must not be read by the checkpoint path.
      first.store.setLocal('location:unrelated', {
        'id': 'unrelated',
        'source': 'nas',
      });
      first.store.save('media', 'unrelated', {'title': 'Other'});
      await first.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        artworkIds: {'remote-video'},
        deferProfile: true,
      );
      final vault = server.records.values
          .where((r) => r.kind == 'vault')
          .toList();
      expect(vault.length, 2);
      expect(vault.map((r) => r.id.split(':').first).toSet(), {
        'binding',
        'source',
      });
      expect(
        first.store.local('syncProfile:remoteMedia'),
        isNull,
        reason: 'checkpoint must not enumerate all media locations',
      );
      await second.sync();
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(second.store.local('location:unrelated'), isNull);
      expect(second.store.local('settings'), isNull);

      final puts = server.puts;
      await first.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        artworkIds: {'remote-video'},
        deferProfile: true,
      );
      expect(
        server.puts,
        puts,
        reason: 'unchanged checkpoint must not republish ciphertext',
      );
      first.store.setLocal('episodeTitle:remote-video', 'Next checkpoint');
      await first.client.synchronize(
        _origin,
        _token,
        sharedOnly: true,
        artworkIds: {'remote-video'},
        deferProfile: true,
      );
      expect(
        server.puts,
        puts + 1,
        reason: 'own acknowledged checkpoint can be updated without full apply',
      );
      await second.sync();
      expect(
        second.store.local('episodeTitle:remote-video'),
        'Next checkpoint',
      );
    },
  );

  test(
    'two devices share settings, credentials and all video catalogue metadata',
    () async {
      final server = _SyncServer(pageSize: 3);
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      first.seedLocal('first-local');
      second.seedLocal('second-local');
      second.settings({'syncOrigin': 'https://second-device.example.com'});

      await first.sync();
      final uploaded = server.puts;
      final wire = jsonEncode(
        server.records.values.map((r) => r.toJson()).toList(),
      );
      for (final secret in [
        'ai-private-key',
        'tmdb-private-key',
        'danmu-private-key',
        'nas-password',
        'nas.internal',
      ]) {
        expect(wire, isNot(contains(secret)));
      }
      expect(
        server.records.values
            .where((r) => r.id.contains('first-local'))
            .map((r) => r.kind),
        ['media'],
      );
      expect(wire, isNot(contains('/device/private/')));
      expect(server.records.values.where((r) => r.kind == 'vault'), isNotEmpty);

      await second.sync();
      expect(
        server.puts,
        uploaded + 1,
        reason: 'only the second device local catalogue entry is new',
      );
      expect(
        server.gets,
        greaterThan(2),
        reason: 'all incremental pages must be consumed',
      );
      expect(second.store.local('settings'), {
        'syncOrigin': 'https://second-device.example.com',
        'metadataStrategy': 'balanced',
        'aiSubtitleModel': 'translation-model',
        'aiSubtitleOrigin': 'https://api.example.com/v1',
      });
      for (final key in SyncProfile.secretKeys) {
        expect(second.secrets.values[key], first.secrets.values[key]);
      }
      expect(second.secrets.values['source:nas'], 'nas-password');
      expect(second.secrets.values['syncToken'], isNull);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(
        (second.store.local('sources') as List).single.containsKey('password'),
        false,
      );
      expect(second.store.local('appearance:theme'), 'dark');
      expect(second.store.local('directorySort:nas:Shows/'), {
        'field': 'name',
        'descending': true,
      });
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(
        second.store.local('externalSource:direct'),
        first.store.local('externalSource:direct'),
      );
      expect(second.store.local('episodeTitle:remote-video'), '相逢');
      expect(second.store.local('manualMetadata:remote-video'), true);
      expect(
        second.store.get('media', 'remote-video')!.data,
        first.store.get('media', 'remote-video')!.data,
      );
      expect(second.store.get('match', 'remote-video')!.data, {
        'episodeId': 123,
        'animeId': 12,
      });
      expect(
        second.store.get('progress', 'remote-video:64')!.data['position'],
        42,
      );
      expect(second.store.get('watched', '示例系列:1:1')!.data['watched'], true);
      expect(second.store.get('media', 'first-local')!.data['title'], '本地文件');
      expect(second.store.local('location:first-local'), isNull);
      expect(second.store.get('media', 'second-local'), isNotNull);
      expect(SourceFavorites(second.store).contains('nas', 'Shows/'), true);
      expect(
        SourceFavorites(
          second.store,
        ).all.where((f) => f.sourceId == 'local').single.path,
        'second-local/',
      );

      second.settings({'metadataStrategy': 'conservative'});
      second.secrets.values['aiSubtitleToken'] = 'replacement-api-key';
      second.store.save('progress', 'remote-video:64', {
        'position': 84,
        'duration': 100,
      });
      second.store.setLocal('episodeTitle:remote-video', '更新的集标题');
      await second.sync();
      await first.sync();
      expect(
        (first.store.local('settings') as Map)['metadataStrategy'],
        'conservative',
      );
      expect(first.secrets.values['aiSubtitleToken'], 'replacement-api-key');
      expect(first.store.local('episodeTitle:remote-video'), '更新的集标题');
      expect(
        first.store.get('progress', 'remote-video:64')!.data['position'],
        84,
      );
      expect(first.store.conflicts, isEmpty);
      expect(second.store.conflicts, isEmpty);
      final beforeRepeat = server.puts;
      await second.sync();
      await first.sync();
      expect(
        server.puts,
        beforeRepeat,
        reason: 'applying remote values must establish a clean baseline',
      );
    },
  );

  test(
    'independent offline edits merge without replacing unrelated settings',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.settings({'speed': 1.0, 'subtitleSize': 24});
      await first.sync();
      await second.sync();
      first.settings({'speed': 1.5});
      second.settings({'subtitleSize': 30});
      await first.sync();
      await second.sync();
      await first.sync();
      expect(first.store.local('settings'), {'speed': 1.5, 'subtitleSize': 30});
      expect(second.store.local('settings'), first.store.local('settings'));
      expect(first.store.conflicts, isEmpty);
      expect(second.store.conflicts, isEmpty);
    },
  );

  test(
    'explicit removals propagate while device-local videos remain untouched',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      second.seedLocal('device-file');
      await first.sync();
      await second.sync();
      first.store.setLocal('settings', {'syncOrigin': _origin});
      first.store.setLocal('sources', []);
      first.store.setLocal(SourceFavorites.storageKey, []);
      first.store.removeLocal('externalSource:direct');
      first.store.removeLocal('location:remote-video');
      first.store.removeLocal('episodeTitle:remote-video');
      first.store.removeLocal('manualMetadata:remote-video');
      first.store.removeLocal('appearance:theme');
      first.store.removeLocal('directorySort:nas:Shows/');
      first.secrets.values.remove('aiSubtitleToken');
      first.secrets.values.remove('source:nas');
      for (final kind in ['media', 'match']) {
        first.store.save(kind, 'remote-video', {}, deleted: true);
      }
      first.store.save('progress', 'remote-video:64', {}, deleted: true);
      await first.sync();
      await second.sync();
      expect(second.store.local('settings'), <String, dynamic>{});
      expect(second.store.local('sources'), isEmpty);
      expect(second.secrets.values['aiSubtitleToken'], isNull);
      expect(second.secrets.values['source:nas'], isNull);
      expect(second.store.local('externalSource:direct'), isNull);
      expect(second.store.local('location:remote-video'), isNull);
      expect(second.store.local('episodeTitle:remote-video'), isNull);
      expect(second.store.local('manualMetadata:remote-video'), isNull);
      expect(second.store.local('appearance:theme'), isNull);
      expect(second.store.local('directorySort:nas:Shows/'), isNull);
      expect(second.store.get('media', 'remote-video')!.deleted, true);
      expect(second.store.get('match', 'remote-video')!.deleted, true);
      expect(second.store.get('progress', 'remote-video:64')!.deleted, true);
      expect(SourceFavorites(second.store).all.single.sourceId, 'local');
      expect(second.store.get('media', 'device-file')!.deleted, false);
      expect(
        second.store.localEntries('automatic-import-excluded:'),
        isNotEmpty,
      );
    },
  );

  for (final localIsNewest in [false, true]) {
    test(
      'same setting automatically chooses the latest edit ($localIsNewest)',
      () async {
        final server = _SyncServer();
        final first = _Device(server), second = _Device(server);
        first.settings({'aiSubtitleModel': 'initial'});
        await first.sync();
        await second.sync();
        first.settings({'aiSubtitleModel': 'server-change'});
        second.settings({'aiSubtitleModel': 'device-change'});
        first.store.markLocalModified(
          'setting:aiSubtitleModel',
          at: '2026-10-22T12:00:02Z',
        );
        second.store.markLocalModified(
          'setting:aiSubtitleModel',
          at: localIsNewest ? '2026-10-22T12:00:03Z' : '2026-10-22T12:00:01Z',
        );
        await first.sync();
        await second.sync();
        await first.sync();
        final expected = localIsNewest ? 'device-change' : 'server-change';
        expect(
          (first.store.local('settings') as Map)['aiSubtitleModel'],
          expected,
        );
        expect(
          (second.store.local('settings') as Map)['aiSubtitleModel'],
          expected,
        );
        expect(first.store.conflicts, isEmpty);
        expect(second.store.conflicts, isEmpty);
      },
    );
  }

  test(
    'an edit during a download is merged and uploaded without a prompt',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.settings({'aiSubtitleModel': 'initial'});
      await first.sync();
      await second.sync();
      first.settings({'aiSubtitleModel': 'remote-edit'});
      await first.sync();
      server.beforeRequest = (uri, method, body) async {
        if (method != 'GET') return;
        server.beforeRequest = null;
        second.settings({'aiSubtitleModel': 'in-flight-local-edit'});
      };
      await second.sync();
      expect(
        (second.store.local('settings') as Map)['aiSubtitleModel'],
        'in-flight-local-edit',
      );
      expect(second.store.conflicts, isEmpty);
      await second.sync();
      await first.sync();
      expect(
        (first.store.local('settings') as Map)['aiSubtitleModel'],
        'in-flight-local-edit',
      );
    },
  );

  test(
    'an edit during upload is staged on the next sync without being reverted',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.settings({'aiSubtitleModel': 'sent-value'});
      server.beforeRequest = (uri, method, body) async {
        if (method != 'PUT') return;
        server.beforeRequest = null;
        first.settings({'aiSubtitleModel': 'newer-value'});
      };
      await first.sync();
      expect(
        (first.store.local('settings') as Map)['aiSubtitleModel'],
        'newer-value',
      );
      expect(first.store.conflicts, isEmpty);
      await first.sync();
      await second.sync();
      expect(
        (second.store.local('settings') as Map)['aiSubtitleModel'],
        'newer-value',
      );
    },
  );

  test(
    'remote records cannot overwrite a deliberately linked local file',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      second.seedLocal('remote-video');
      second.store.setLocal('episodeTitle:remote-video', '本机的小标题');
      await first.sync();
      await second.sync();
      expect(
        (second.store.local('location:remote-video') as Map)['source'],
        'local',
      );
      expect(second.store.get('media', 'remote-video')!.data['title'], '本地文件');
      expect(second.store.local('episodeTitle:remote-video'), '本机的小标题');
      expect(second.store.get('match', 'remote-video'), isNull);
      expect(second.store.get('progress', 'remote-video:64'), isNull);
      expect(second.store.conflicts, isEmpty);
      expect(
        second.profile.shouldUpload(second.store.get('media', 'remote-video')!),
        false,
      );
    },
  );

  test(
    'relinking a synchronized video locally never deletes another device binding',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.sync();
      final uploaded = server.puts;
      second.seedLocal('remote-video');
      await second.sync();
      expect(server.puts, uploaded);
      second.store.save('media', 'remote-video', {}, deleted: true);
      second.store.removeLocal('location:remote-video');
      await second.sync();
      expect(server.puts, uploaded);
      final fresh = _Device(server);
      await fresh.sync();
      expect(fresh.store.get('media', 'remote-video')!.deleted, false);
      expect(
        (fresh.store.local('location:remote-video') as Map)['source'],
        'nas',
      );
      expect(fresh.store.local('episodeTitle:remote-video'), '相逢');
      expect(second.store.conflicts, isEmpty);
    },
  );

  test(
    'resetting association migrates local configuration to a new origin and token',
    () async {
      final oldServer = _SyncServer(), newServer = _SyncServer(pageSize: 2);
      final first = _Device(oldServer);
      first.seedRemote();
      first.seedLocal('device-file');
      await first.sync();
      final settings = first.store.local('settings');
      final sources = first.store.local('sources');
      final oldUploads = oldServer.puts;
      first.client.resetAssociation();
      expect(first.store.local('settings'), settings);
      expect(first.store.local('sources'), sources);
      expect(first.secrets.values['aiSubtitleToken'], 'ai-private-key');
      expect(first.secrets.values['source:nas'], 'nas-password');
      expect(first.store.local('syncOrigin'), isNull);
      expect(first.store.local('syncCursor:$_origin'), isNull);
      expect(first.store.local('syncProfile:baseline'), isNull);
      expect(first.store.localEntries('syncProfile:applied:'), isEmpty);
      expect(first.store.records('vault'), isEmpty);
      const newOrigin = 'https://replacement-sync.example.com';
      const newToken = 'new-service-token-with-at-least-24-characters';
      final migrated = SyncClient(
        first.store,
        profile: first.profile,
        transport: newServer,
      );
      await migrated.synchronize(newOrigin, newToken);
      expect(first.store.local('syncOrigin'), newOrigin);
      expect(first.store.conflicts, isEmpty);
      expect(oldServer.puts, oldUploads);
      final fresh = _Device(newServer);
      await fresh.sync(address: newOrigin, token: newToken);
      expect(
        (fresh.store.local('settings') as Map)['aiSubtitleModel'],
        'translation-model',
      );
      expect(fresh.store.local('sources'), sources);
      expect(fresh.secrets.values['source:nas'], 'nas-password');
      expect(fresh.secrets.values['aiSubtitleToken'], 'ai-private-key');
      expect(
        (fresh.store.local('location:remote-video') as Map)['source'],
        'nas',
      );
      expect(fresh.store.local('episodeTitle:remote-video'), '相逢');
      expect(fresh.store.get('media', 'device-file')!.data['title'], '本地文件');
      expect(fresh.store.local('location:device-file'), isNull);
      fresh.settings({'aiSubtitleModel': 'model-on-new-service'});
      await fresh.sync(address: newOrigin, token: newToken);
      await migrated.synchronize(newOrigin, newToken);
      expect(
        (first.store.local('settings') as Map)['aiSubtitleModel'],
        'model-on-new-service',
      );
      expect(first.store.conflicts, isEmpty);
      expect(fresh.store.conflicts, isEmpty);
    },
  );

  test(
    'token rotation preserves the remote binding after a device relinks locally',
    () async {
      final server = _SyncServer(pageSize: 1);
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      await second.sync();
      second.seedLocal('remote-video');
      const replacement =
          'relinked-device-rotated-token-at-least-24-characters';
      await second.sync(token: replacement);
      expect(
        (second.store.local('location:remote-video') as Map)['source'],
        'local',
      );
      expect(second.store.get('media', 'remote-video')!.data['title'], '本地文件');
      final binding = server.records.values.singleWhere(
        (r) => r.kind == 'vault' && r.id.startsWith('binding:'),
      );
      expect(binding.deleted, false);
      final decoded = await SyncVault(
        await SyncVault.derive(replacement),
      ).open(binding);
      expect(decoded['value']['location']['source'], 'nas');
      expect(decoded['value']['location']['path'], 'Shows/E01.mkv');
      final fresh = _Device(server);
      await fresh.sync(token: replacement);
      expect(
        (fresh.store.local('location:remote-video') as Map)['source'],
        'nas',
      );
      expect(fresh.store.get('media', 'remote-video')!.data['title'], '示例第一集');
      expect(fresh.store.local('episodeTitle:remote-video'), '相逢');
      expect(fresh.secrets.values['source:nas'], 'nas-password');
      expect(fresh.store.local('syncCursor:$_origin'), server.changes.length);
      expect(second.store.conflicts, isEmpty);
      expect(fresh.store.conflicts, isEmpty);
      final uploaded = server.puts;
      await second.sync(token: replacement);
      expect(server.puts, uploaded);
      await fresh.sync(token: replacement);
      expect(
        (fresh.store.local('location:remote-video') as Map)['source'],
        'nas',
      );
      expect(
        server.records.values.singleWhere((r) => r.id == binding.id).deleted,
        false,
      );
    },
  );

  test(
    'invalid vault content does not apply settings and remains retryable',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.settings({'aiSubtitleModel': 'private-model'});
      await first.sync();
      final record = server.changes.single;
      server.changes[0] = SyncRecord(
        id: record.id,
        kind: record.kind,
        data: {...record.data, 'mac': base64Encode(List<int>.filled(16, 0))},
        version: record.version,
      );
      await expectLater(second.sync(), throwsA(isA<AppFailure>()));
      expect(second.store.local('lastSync'), isNull);
      expect(second.store.local('settings'), isNull);
      server.changes.add(
        SyncRecord(
          id: record.id,
          kind: record.kind,
          data: record.data,
          version: record.version + 1,
        ),
      );
      await second.sync();
      expect(
        (second.store.local('settings') as Map)['aiSubtitleModel'],
        'private-model',
      );
    },
  );

  test(
    'wrong tokens cannot decrypt records and rotating a token retains old data',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.settings({'aiSubtitleModel': 'saved-model'});
      first.secrets.values['aiSubtitleToken'] = 'saved-secret';
      await first.sync();
      const replacement = 'replacement-synchronization-token-24-characters';
      await expectLater(
        second.sync(token: replacement),
        throwsA(isA<AppFailure>()),
      );
      expect(second.store.local('lastSync'), isNull);
      await first.sync(token: replacement);
      await second.sync(token: replacement);
      expect(second.secrets.values['aiSubtitleToken'], 'saved-secret');
      expect(
        (second.store.local('settings') as Map)['aiSubtitleModel'],
        'saved-model',
      );
      final vault = SyncVault(await SyncVault.derive(replacement));
      for (final record in server.records.values.where(
        (r) => r.kind == 'vault',
      )) {
        expect(await vault.open(record), isA<Map<String, dynamic>>());
      }
      final fresh = _Device(server);
      await fresh.sync(token: replacement);
      expect(fresh.secrets.values['aiSubtitleToken'], 'saved-secret');
      expect(
        (fresh.store.local('settings') as Map)['aiSubtitleModel'],
        'saved-model',
      );
    },
  );

  test(
    'secure storage failures retry both credential writes and deletions',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.secrets.values['aiSubtitleToken'] = 'must-be-persisted';
      await first.sync();
      second.secrets.failWriteKey = 'aiSubtitleToken';
      await expectLater(second.sync(), throwsStateError);
      expect(second.secrets.values['aiSubtitleToken'], isNull);
      expect(second.store.local('lastSync'), isNull);
      second.secrets.failWriteKey = null;
      await second.sync();
      expect(second.secrets.values['aiSubtitleToken'], 'must-be-persisted');
      expect(second.store.conflicts, isEmpty);
      first.secrets.values.remove('aiSubtitleToken');
      await first.sync();
      second.secrets.failDeleteKey = 'aiSubtitleToken';
      await expectLater(second.sync(), throwsStateError);
      expect(second.secrets.values['aiSubtitleToken'], 'must-be-persisted');
      second.secrets.failDeleteKey = null;
      await second.sync();
      expect(second.secrets.values['aiSubtitleToken'], isNull);
      expect(second.store.conflicts, isEmpty);
    },
  );

  test(
    'shared polling retries failed source restoration without new changes',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.seedRemote();
      await first.sync();
      second.secrets.failWriteKey = 'source:nas';
      await expectLater(
        second.client.synchronize(_origin, _token, sharedOnly: true),
        throwsStateError,
      );
      expect(second.store.get('media', 'remote-video'), isNotNull);
      expect(second.store.local('sources'), isNull);
      expect(second.store.local('location:remote-video'), isNull);
      expect(second.store.local('lastSync'), isNull);
      final cursor = second.store.local('syncCursor:$_origin');
      expect(cursor, server.changes.length);
      final uploads = server.puts;

      second.secrets.failWriteKey = null;
      await second.client.synchronize(_origin, _token, sharedOnly: true);
      expect(second.store.local('syncCursor:$_origin'), cursor);
      expect(server.puts, uploads);
      expect(second.store.local('sources'), first.store.local('sources'));
      expect(second.secrets.values['source:nas'], 'nas-password');
      expect(
        second.store.local('location:remote-video'),
        first.store.local('location:remote-video'),
      );
      expect(second.client.profileRevision, 1);

      await second.client.synchronize(_origin, _token, sharedOnly: true);
      expect(second.client.profileRevision, 1);
    },
  );

  test(
    'interrupted token rotation retries and a fresh device reads all history',
    () async {
      final server = _SyncServer(pageSize: 1);
      final first = _Device(server);
      first.settings({'aiSubtitleModel': 'model', 'speed': 1.25});
      first.secrets.values['aiSubtitleToken'] = 'key-survives-rotation';
      await first.sync();
      const replacement = 'rotated-synchronization-token-with-24-characters';
      var rotatingWrites = 0;
      server.beforeRequest = (uri, method, body) async {
        if (method == 'PUT' && ++rotatingWrites == 2) {
          throw const AppFailure('connection interrupted');
        }
      };
      await expectLater(
        first.sync(token: replacement),
        throwsA(isA<AppFailure>()),
      );
      expect(first.store.pending.where(first.profile.shouldUpload), isNotEmpty);
      server.beforeRequest = null;
      await first.sync(token: replacement);
      expect(first.store.pending.where(first.profile.shouldUpload), isEmpty);
      final fresh = _Device(server);
      await fresh.sync(token: replacement);
      expect(fresh.store.local('settings'), {
        'aiSubtitleModel': 'model',
        'speed': 1.25,
      });
      expect(fresh.secrets.values['aiSubtitleToken'], 'key-survives-rotation');
      expect(fresh.store.local('syncCursor:$_origin'), server.changes.length);
      expect(fresh.store.conflicts, isEmpty);
    },
  );

  test(
    'replacing credential storage restores vault values without uploading removals',
    () async {
      final server = _SyncServer();
      final first = _Device(server, recoverMissingCredentials: true);
      first.seedRemote();
      await first.sync();
      final uploaded = server.puts;
      final oldDigest = first.secrets.values['sync.digestKey'];
      first.secrets.values.clear();

      await first.sync();
      expect(first.secrets.values['sync.digestKey'], isNot(oldDigest));
      expect(first.secrets.values['aiSubtitleToken'], 'ai-private-key');
      expect(first.secrets.values['tmdb.apiKey'], 'tmdb-private-key');
      expect(first.secrets.values['danmuToken'], 'danmu-private-key');
      expect(first.secrets.values['source:nas'], 'nas-password');
      expect(server.puts, uploaded);
      expect(first.store.conflicts, isEmpty);

      // Only recovery is special; deliberate later removals still propagate.
      first.secrets.values.remove('aiSubtitleToken');
      first.secrets.values['source:nas'] = '';
      await first.sync();
      final fresh = _Device(server);
      await fresh.sync();
      expect(fresh.secrets.values['aiSubtitleToken'], isNull);
      expect(fresh.secrets.values['source:nas'], '');
    },
  );

  test(
    'credential recovery preserves manually reentered values and offline settings',
    () async {
      final server = _SyncServer();
      final first = _Device(server, recoverMissingCredentials: true);
      first.seedRemote();
      await first.sync();
      first.secrets.values
        ..clear()
        ..['aiSubtitleToken'] = 'manually-reentered-token'
        ..['source:nas'] = '';
      first.settings({'metadataStrategy': 'conservative'});

      await first.sync();
      final fresh = _Device(server);
      await fresh.sync();
      expect(
        fresh.secrets.values['aiSubtitleToken'],
        'manually-reentered-token',
      );
      expect(fresh.secrets.values['source:nas'], '');
      expect(
        (fresh.store.local('settings') as Map)['metadataStrategy'],
        'conservative',
      );
      expect(first.store.conflicts, isEmpty);
    },
  );

  test(
    'interrupted credential restoration retries after the digest was recreated',
    () async {
      final server = _SyncServer();
      final first = _Device(server, recoverMissingCredentials: true);
      first.seedRemote();
      await first.sync();
      final uploaded = server.puts;
      final baseline = first.store.local('syncProfile:baseline');
      first.secrets.values.clear();
      first.secrets.failWriteKey = 'aiSubtitleToken';

      await expectLater(first.sync(), throwsStateError);
      expect(server.puts, uploaded);
      expect(first.store.local('syncProfile:baseline'), baseline);
      expect(first.secrets.values['sync.digestKey'], isNotNull);
      first.secrets.failWriteKey = null;
      await first.sync();
      expect(first.secrets.values['aiSubtitleToken'], 'ai-private-key');
      expect(first.secrets.values['source:nas'], 'nas-password');
      expect(server.puts, uploaded);
      expect(first.store.conflicts, isEmpty);
    },
  );

  test(
    'missing rotation history blocks recovery without replacing ciphertext',
    () async {
      final server = _SyncServer();
      final first = _Device(server, recoverMissingCredentials: true);
      first.seedRemote();
      await first.sync();
      final uploaded = server.puts;
      final baseline = first.store.local('syncProfile:baseline');
      final ciphertext = jsonEncode(
        first.store.records('vault').map((record) => record.toJson()).toList(),
      );
      first.secrets.values.clear();
      const replacement = 'replacement-synchronization-token-24-characters';

      await expectLater(
        first.sync(token: replacement),
        throwsA(isA<AppFailure>()),
      );
      expect(server.puts, uploaded);
      expect(first.store.local('syncProfile:baseline'), baseline);
      expect(
        jsonEncode(
          first.store
              .records('vault')
              .map((record) => record.toJson())
              .toList(),
        ),
        ciphertext,
      );
      expect(first.secrets.values['source:nas'], isNull);
      await first.sync();
      await first.sync(token: replacement);
      final fresh = _Device(server);
      await fresh.sync(token: replacement);
      expect(fresh.secrets.values['source:nas'], 'nas-password');
      expect(fresh.secrets.values['aiSubtitleToken'], 'ai-private-key');
    },
  );

  test(
    'credential replacement cannot overwrite a downloaded but unapplied source',
    () async {
      final server = _SyncServer();
      final writer = _Device(server);
      final first = _Device(server, recoverMissingCredentials: true);
      writer.seedRemote();
      await writer.sync();
      await first.sync();
      writer.secrets.values['source:nas'] = 'updated-remote-password';
      final sources = writer.store.local('sources') as List;
      (sources.single as Map)['label'] = 'Updated remote NAS';
      writer.store.setLocal('sources', sources);
      await writer.sync();
      first.secrets.failWriteKey = 'source:nas';
      await expectLater(first.sync(), throwsStateError);
      expect(first.secrets.values['source:nas'], 'nas-password');
      expect(
        ((first.store.local('sources') as List).single as Map)['label'],
        'NAS',
      );
      final record = first.store
          .records('vault')
          .singleWhere((record) => record.id.startsWith('source:'));
      expect(record.dirty, false);
      final uploaded = server.puts;
      final baseline = first.store.local('syncProfile:baseline');
      first.secrets.values.clear();
      first.secrets.failWriteKey = null;

      await expectLater(first.sync(), throwsA(isA<AppFailure>()));
      expect(server.puts, uploaded);
      expect(first.store.local('syncProfile:baseline'), baseline);
      expect(first.store.get('vault', record.id)!.toJson(), record.toJson());
      expect(first.secrets.values['source:nas'], isNull);
      // Retrying after the new digest exists must remain blocked as well.
      await expectLater(first.sync(), throwsA(isA<AppFailure>()));
      expect(server.puts, uploaded);
      final fresh = _Device(server);
      await fresh.sync();
      expect(fresh.secrets.values['source:nas'], 'updated-remote-password');
      expect(
        ((fresh.store.local('sources') as List).single as Map)['label'],
        'Updated remote NAS',
      );
    },
  );

  test('unsynced source credentials must be reentered before upload', () async {
    final server = _SyncServer();
    final first = _Device(server, recoverMissingCredentials: true);
    first.seedRemote();
    first.secrets.values.clear();
    await expectLater(first.sync(), throwsA(isA<AppFailure>()));
    expect(server.puts, 0);
    expect(first.store.records('vault'), isEmpty);
    first.secrets.values['source:nas'] = '';
    await first.sync();
    final fresh = _Device(server);
    await fresh.sync();
    expect(fresh.secrets.values['source:nas'], '');
  });

  test(
    'separate player stores agree on the newly created digest key',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-sync-keys-',
      );
      final store = AppStore(':memory:');
      final firstSecrets = LocalCredentialStorage(directory);
      final secondSecrets = LocalCredentialStorage(directory);
      addTearDown(() async {
        await firstSecrets.close();
        await secondSecrets.close();
        store.dispose();
        directory.deleteSync(recursive: true);
      });
      store.setLocal('settings', {'speed': 1.25});
      SyncProfile profile(LocalCredentialStorage secrets) => SyncProfile(
        store,
        secrets,
        watchedKey: (record) => record.id,
        recoverMissingCredentials: true,
      );
      final first = profile(firstSecrets), second = profile(secondSecrets);
      await Future.wait([
        first.unlock(_origin, _token),
        second.unlock(_origin, _token),
      ]);
      await first.prepare();
      final record = store.records('vault').single;
      await second.prepare();
      expect(store.get('vault', record.id)!.revision, record.revision);
    },
  );
}

class _Device {
  final store = AppStore(':memory:');
  final secrets = _MemorySecrets();
  late final SyncProfile profile;
  late final SyncClient client;

  _Device(_SyncServer server, {bool recoverMissingCredentials = false}) {
    addTearDown(store.dispose);
    profile = SyncProfile(
      store,
      secrets,
      recoverMissingCredentials: recoverMissingCredentials,
      watchedKey: (record) =>
          '${record.data['series']}:${record.data['season']}:${record.data['episode']}',
    );
    client = SyncClient(store, profile: profile, transport: server);
  }

  Future<void> sync({String token = _token, String address = _origin}) =>
      client.synchronize(address, token);

  void settings(Map<String, dynamic> patch) => store.setLocal('settings', {
    ...?store.local('settings') as Map?,
    ...patch,
  });

  void seedRemote() {
    settings({
      'syncOrigin': _origin,
      'metadataStrategy': 'balanced',
      'aiSubtitleModel': 'translation-model',
      'aiSubtitleOrigin': 'https://api.example.com/v1',
    });
    secrets.values.addAll({
      'aiSubtitleToken': 'ai-private-key',
      'tmdb.apiKey': 'tmdb-private-key',
      'danmuToken': 'danmu-private-key',
      'source:nas': 'nas-password',
      'syncToken': _token,
    });
    store.setLocal('sources', [
      {
        'id': 'nas',
        'kind': 'webdav',
        'url': 'https://nas.internal/dav/',
        'label': 'NAS',
        'username': 'user',
      },
    ]);
    store.setLocal('appearance:theme', 'dark');
    store.setLocal('directorySort:nas:Shows/', {
      'field': 'name',
      'descending': true,
    });
    store.setLocal('externalSource:direct', {
      'id': 'direct',
      'kind': 'http',
      'url': 'https://cdn.example.com/video.mp4?token=private-link',
    });
    store.save('media', 'remote-video', {
      'title': '示例第一集',
      'series': '示例系列',
      'season': '1',
      'episode': '1',
      'size': 64,
      'bangumiId': 12,
      'metadataTitle': '识别后的名称',
    });
    store.setLocal('location:remote-video', {
      'id': 'remote-video',
      'source': 'nas',
      'path': 'Shows/E01.mkv',
      'size': 64,
      'modified': 123,
    });
    store.setLocal('episodeTitle:remote-video', '相逢');
    store.setLocal('manualMetadata:remote-video', true);
    SourceFavorites(
      store,
    ).toggle(const SourceFavorite(sourceId: 'nas', path: 'Shows/', name: '剧集'));
    store.save('progress', 'remote-video:64', {
      'position': 42,
      'duration': 100,
    });
    store.save('match', 'remote-video', {'episodeId': 123, 'animeId': 12});
    store.save('watched', '示例系列:1:1', {'watched': true});
  }

  void seedLocal(String id) {
    store.save('media', id, {
      'title': '本地文件',
      'series': id,
      'season': '1',
      'episode': '1',
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': 'local',
      'path': '/device/private/$id.mkv',
      'size': 12,
    });
    store.save('progress', '$id:12', {'position': 10, 'duration': 12});
    store.save('watched', '$id:1:1', {'watched': true});
    SourceFavorites(
      store,
    ).toggle(SourceFavorite(sourceId: 'local', path: '$id/', name: '本机文件夹'));
    store.setLocal('directorySort:local:imports', {'descending': true});
  }
}

class _SyncServer implements JsonTransport {
  final int pageSize;
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];
  int puts = 0, gets = 0, conflicts = 0;
  Future<void> Function(Uri, String, Map<String, dynamic>?)? beforeRequest;
  _SyncServer({this.pageSize = 4});

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    await beforeRequest?.call(uri, method, body);
    expect(headers['Authorization'], startsWith('Bearer '));
    if (method == 'PUT') {
      expect(uri.path, '/v1/records');
      puts++;
      final incoming = SyncRecord.fromJson(body!);
      final key = '${incoming.kind}:${incoming.id}';
      final current = records[key];
      if (incoming.version != (current?.version ?? 0)) {
        conflicts++;
        return {'_status': 409, 'current': current!.toJson()};
      }
      final accepted = SyncRecord(
        id: incoming.id,
        kind: incoming.kind,
        modifiedAt: incoming.modifiedAt,
        deviceId: incoming.deviceId,
        deviceName: incoming.deviceName,
        data: Map<String, dynamic>.from(jsonDecode(jsonEncode(incoming.data))),
        deleted: incoming.deleted,
        version: (current?.version ?? 0) + 1,
      );
      records[key] = accepted;
      changes.add(accepted);
      return accepted.toJson();
    }
    expect(uri.path, '/v1/changes');
    gets++;
    final after = int.parse(uri.queryParameters['after']!);
    final page = changes.skip(after).take(pageSize).toList();
    final cursor = after + page.length;
    return {
      'changes': page.map((r) => r.toJson()).toList(),
      'cursor': cursor,
      'hasMore': cursor < changes.length,
    };
  }
}

class _MemorySecrets extends FlutterSecureStorage {
  final values = <String, String>{};
  String? failWriteKey, failDeleteKey;

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
    if (key == failWriteKey) throw StateError('secure write failed');
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
  }) async {
    if (key == failDeleteKey) throw StateError('secure deletion failed');
    values.remove(key);
  }
}
