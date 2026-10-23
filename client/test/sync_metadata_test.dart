import 'dart:convert';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'metadata-synchronization-token-with-24-characters';
const _origin = 'https://sync.example.com';
String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'technical facts, translations and remote directory matches survive a second device',
    () async {
      final server = _Server();
      final first = _Device(server)..seed(), second = _Device(server);
      first.store.setLocal('metadataCredentialsRevision', 111);
      second.store.setLocal('metadataCredentialsRevision', 222);
      final displayKey = 'media-title-display:${_digest('display')}';
      final titleKey = 'media-title-translation:${_digest('title')}';
      final summaryKey = 'summary-translation:${_digest('summary')}';
      final subtitleKey =
          'subtitle-ai:${_digest('source')}:${_digest('profile')}';
      final directoryKey = 'directory-preview:${_digest(['nas', 'Shows'])}';
      final extra = <String, dynamic>{
        'metadataEpisodeNames:示例:1': {'1': '第一集'},
        displayKey: {
          'visible': true,
          'titles': {'Episode one': '第一集'},
        },
        titleKey: '第一集',
        summaryKey: '故事简介译文',
        subtitleKey: {
          'version': 1,
          'values': {'0': '你好'},
        },
      };
      for (final row in extra.entries) {
        first.store.setLocal(row.key, row.value);
      }
      first.store.setLocal(directoryKey, _directory());
      await first.sync();
      await second.sync();
      for (final row in extra.entries) {
        expect(second.store.local(row.key), row.value);
      }
      expect(
        second.store.local('location:video'),
        first.store.local('location:video'),
      );
      expect(
        second.store.local('mediaMetadata:video'),
        first.store.local('mediaMetadata:video'),
      );
      final info = MediaTechnicalInfo.forRecord(
        second.store,
        second.store.get('media', 'video')!,
      );
      expect(info.codec, 'H.265');
      expect(info.width, 1920);
      expect(info.duration, 1420);
      final catalog = LibraryCatalog(
        second.store,
        aiContext: () => jsonEncode([false, null, null, 222]),
      );
      final directory = catalog.directoryPreview('nas', 'Shows/');
      expect(
        directory?.collection?.poster,
        'https://images.example.com/poster.jpg',
      );
      expect(directory?.collection?.episodeTitles, {'Shows/E01.mkv': '第一集'});
      expect(second.store.local('metadataCredentialsRevision'), 222);
      final puts = server.puts;
      await first.sync();
      await second.sync();
      expect(
        server.puts,
        puts,
        reason:
            'rebuilt local context must not dirty the shared directory result',
      );
      expect(first.store.conflicts, isEmpty);
      expect(second.store.conflicts, isEmpty);
    },
  );

  test(
    'stale facts, local directory paths and device state never enter expanded records',
    () async {
      final server = _Server();
      final first = _Device(server)..seed(), second = _Device(server);
      first.store.setLocal('mediaMetadata:video', {
        'fingerprint': 'obsolete',
        'width': 4000,
      });
      first.store.setLocal('technical:video', {
        'fingerprint': 'obsolete',
        'codec': 'old',
      });
      first.store.setLocal('directory-preview:${_digest('local')}', {
        ..._directory(),
        'sourceId': 'local',
      });
      first.store.setLocal('sourceBrowser:nas', {
        'paths': [
          {'path': 'Shows/'},
        ],
      });
      first.store.setLocal('metadata:pending-tasks', [
        {'id': 'running-only-on-device'},
      ]);
      first.store.setLocal('preview:video', {
        'path': '/private/device/frame.jpg',
      });
      await first.sync();
      await second.sync();
      expect(second.store.local('mediaMetadata:video'), isNull);
      expect(second.store.local('technical:video'), isNull);
      expect(second.store.localEntries('directory-preview:'), isEmpty);
      expect(second.store.local('sourceBrowser:nas'), isNull);
      expect(second.store.local('metadata:pending-tasks'), isNull);
      expect(second.store.local('preview:video'), isNull);
      final vault = SyncVault(await SyncVault.derive(_token));
      final payloads = [
        for (final record in server.records.values.where(
          (r) => r.kind == 'vault',
        ))
          await vault.open(record),
      ];
      expect(jsonEncode(payloads), isNot(contains('/private/device')));
      expect(jsonEncode(payloads), isNot(contains('sourceBrowser')));
    },
  );

  test(
    'cache eviction and oversized optional results do not delete shared data or block settings',
    () async {
      final server = _Server();
      final first = _Device(server), second = _Device(server);
      final key = 'summary-translation:${_digest('retained')}';
      first.store.setLocal(key, '已成功翻译');
      await first.sync();
      await second.sync();
      first.store.removeLocal(key);
      first.store.setLocal(
        'summary-translation:${_digest('oversized')}',
        '啊' * 80000,
      );
      first.store.setLocal('settings', {'playbackRate': 1.5});
      const rotated = 'rotated-metadata-synchronization-token-long-enough';
      await first.sync(token: rotated);
      final fresh = _Device(server);
      await fresh.sync(token: rotated);
      expect(fresh.store.local(key), '已成功翻译');
      expect(
        fresh.store.local('summary-translation:${_digest('oversized')}'),
        isNull,
      );
      expect(fresh.store.local('settings'), {'playbackRate': 1.5});
      expect(server.records.values.where((record) => record.deleted), isEmpty);
    },
  );

  test(
    'a new file revision removes facts belonging to the old location',
    () async {
      final server = _Server();
      final first = _Device(server)..seed(), second = _Device(server);
      await first.sync();
      await second.sync();
      first.store.setLocal('location:video', {
        ...first.store.local('location:video') as Map,
        'size': 2048,
        'modified': 999,
        'previewRevision': 'replacement-file',
      });
      await first.sync();
      await second.sync();
      expect(second.store.local('mediaMetadata:video'), isNull);
      expect(second.store.local('technical:video'), isNull);
    },
  );

  test(
    'portable record validators reject unrecognized local keys and invalid facts',
    () async {
      final device = _Device(_Server());
      await device.profile.unlock(_origin, _token);
      final vault = SyncVault(await SyncVault.derive(_token));
      for (final entry in [
        {
          'type': 'local',
          'key': 'sourceBrowser:nas',
          'value': {'paths': []},
        },
        {
          'type': 'local',
          'key': 'media-title-display:${_digest('invalid')}',
          'value': {'visible': true, 'path': '/private/file'},
        },
        {
          'type': 'local',
          'key': 'directory-preview:${_digest('local')}',
          'value': {..._directory(), 'sourceId': 'local'},
        },
        {
          'type': 'binding',
          'key': 'video',
          'value': {
            'location': _location(),
            'technical': {'fingerprint': 'wrong', 'width': -1},
          },
        },
      ]) {
        final id =
            '${entry['type']}:${sha256.convert(utf8.encode(entry['key'] as String))}';
        final record = SyncRecord(
          id: id,
          kind: 'vault',
          data: await vault.seal(id, entry),
        );
        await expectLater(
          device.profile.validate(record),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
}

Map<String, dynamic> _location() => {
  'id': 'video',
  'source': 'nas',
  'path': 'Shows/E01.mkv',
  'size': 1024,
  'modified': 100,
  'previewRevision': 'source-revision',
};

Map<String, dynamic> _directory() => {
  'sourceId': 'nas',
  'context': 'device-context',
  'fingerprint': 'folder-files',
  'at': 100,
  'modified': 100,
  'collection': {
    'title': '示例',
    'season': '1',
    'videos': [
      {
        'name': 'E01.mkv',
        'path': 'Shows/E01.mkv',
        'size': 1024,
        'modified': 100,
        'hidden': false,
      },
    ],
    'identities': {
      'Shows/E01.mkv': ['示例', '1', '1'],
    },
    'subject': {
      'id': 12,
      'provider': 'bangumi',
      'name': '示例',
      'images': {'large': 'https://images.example.com/poster.jpg'},
    },
    'episodeTitles': {'Shows/E01.mkv': '第一集'},
  },
};

class _Device {
  final store = AppStore(':memory:');
  final secrets = _Secrets();
  late final SyncProfile profile = SyncProfile(
    store,
    secrets,
    watchedKey: (record) => record.id,
  );
  late final SyncClient client;
  _Device(_Server server) {
    addTearDown(store.dispose);
    client = SyncClient(store, profile: profile, transport: server);
  }
  Future<void> sync({String token = _token}) =>
      client.synchronize(_origin, token);
  void seed() {
    store.setLocal('sources', [
      {'id': 'nas', 'kind': 'webdav', 'url': 'https://nas.example.com/dav/'},
    ]);
    store.save('media', 'video', {'title': '示例', 'size': 1024});
    store.setLocal('location:video', _location());
    store.setLocal('mediaMetadata:video', {
      'fingerprint': const MediaPreviewRequest(
        'video',
        'nas',
        'Shows/E01.mkv',
        1024,
        revision: 'source-revision',
      ).contentFingerprint,
      'width': 1920,
      'height': 1080,
      'duration': 1420,
    });
    const MediaTechnicalInfo(
      codec: 'H.265',
      container: 'Matroska',
      width: 1920,
      height: 1080,
      duration: 1420,
      bitrate: 1000000,
    ).save(store, store.get('media', 'video')!);
  }
}

class _Server implements JsonTransport {
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];
  int puts = 0;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    if (method == 'PUT') {
      puts++;
      final incoming = SyncRecord.fromJson(body!);
      final key = '${incoming.kind}:${incoming.id}';
      final current = records[key];
      if (incoming.version != (current?.version ?? 0)) {
        return {'_status': 409, 'current': current!.toJson()};
      }
      final accepted = SyncRecord(
        id: incoming.id,
        kind: incoming.kind,
        modifiedAt: incoming.modifiedAt,
        deviceId: incoming.deviceId,
        deviceName: incoming.deviceName,
        data: incoming.data,
        version: incoming.version + 1,
        deleted: incoming.deleted,
      );
      records[key] = accepted;
      changes.add(accepted);
      return accepted.toJson();
    }
    final after = int.parse(uri.queryParameters['after']!);
    return {
      'changes': changes.skip(after).map((r) => r.toJson()).toList(),
      'cursor': changes.length,
      'hasMore': false,
    };
  }
}

class _Secrets extends FlutterSecureStorage {
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
}
