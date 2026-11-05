import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cache budgets default independently and persist after model reopen',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'album-cache-prefs-',
      );
      AppStore? store = await AppStore.open('${directory.path}/library.db');
      AppModel? model = AppModel(store, directory, backgroundWork: false);
      try {
        expect(model.preferences.albumThumbnailCacheMiB, 512);
        expect(model.preferences.albumOriginalCacheMiB, 1024);
        expect(model.preferences.albumMetadataCacheMiB, 16);
        expect(model.preferences.decodedImageCacheMiB, 100);
        expect(model.preferences.externalFileCacheMiB, 512);
        await model.updatePreferences({
          'albumThumbnailCacheMiB': 768,
          'albumOriginalCacheMiB': 2048,
          'albumMetadataCacheMiB': 24,
          'decodedImageCacheMiB': 128,
          'externalFileCacheMiB': 768,
        });
        model.dispose();
        await model.flushMetadataTasks();
        store.dispose();
        model = null;
        store = null;
        store = await AppStore.open('${directory.path}/library.db');
        model = AppModel(store, directory, backgroundWork: false);
        expect(model.preferences.albumThumbnailCacheMiB, 768);
        expect(model.preferences.albumOriginalCacheMiB, 2048);
        expect(model.preferences.albumMetadataCacheMiB, 24);
        expect(model.preferences.decodedImageCacheMiB, 128);
        expect(model.preferences.externalFileCacheMiB, 768);
        expect(model.preferences.albumThumbnailCacheBytes, 768 * 1024 * 1024);
        expect(model.preferences.albumOriginalCacheBytes, 2048 * 1024 * 1024);
        expect(model.preferences.albumMetadataCacheBytes, 24 * 1024 * 1024);
        expect(model.preferences.decodedImageCacheBytes, 128 * 1024 * 1024);
        expect(model.preferences.externalFileCacheBytes, 768 * 1024 * 1024);
      } finally {
        model?.dispose();
        await model?.flushMetadataTasks();
        store?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cache budgets sync, merge independent edits and reset remotely',
    () async {
      final server = _SyncServer();
      final first = _Device(server), second = _Device(server);
      first.patch({
        'albumThumbnailCacheMiB': 768,
        'albumOriginalCacheMiB': 2048,
        'albumMetadataCacheMiB': 24,
        'decodedImageCacheMiB': 128,
        'externalFileCacheMiB': 768,
      });
      await first.sync();
      await second.sync();
      expect(second.preferences.albumThumbnailCacheMiB, 768);
      expect(second.preferences.albumOriginalCacheMiB, 2048);
      expect(second.preferences.albumMetadataCacheMiB, 24);
      expect(second.preferences.decodedImageCacheMiB, 128);
      expect(second.preferences.externalFileCacheMiB, 768);

      first.patch({
        'albumThumbnailCacheMiB': 1024,
        'albumMetadataCacheMiB': 32,
        'externalFileCacheMiB': 1024,
      });
      second.patch({
        'albumOriginalCacheMiB': 4096,
        'decodedImageCacheMiB': 160,
      });
      await first.sync();
      await second.sync();
      await first.sync();
      for (final device in [first, second]) {
        expect(device.preferences.albumThumbnailCacheMiB, 1024);
        expect(device.preferences.albumOriginalCacheMiB, 4096);
        expect(device.preferences.albumMetadataCacheMiB, 32);
        expect(device.preferences.decodedImageCacheMiB, 160);
        expect(device.preferences.externalFileCacheMiB, 1024);
        expect(device.store.conflicts, isEmpty);
      }

      second.store.setLocal('settings', <String, dynamic>{});
      await second.sync();
      await first.sync();
      expect(first.preferences.albumThumbnailCacheMiB, 512);
      expect(first.preferences.albumOriginalCacheMiB, 1024);
      expect(first.preferences.albumMetadataCacheMiB, 16);
      expect(first.preferences.decodedImageCacheMiB, 100);
      expect(first.preferences.externalFileCacheMiB, 512);
    },
  );
}

class _Device {
  final store = AppStore(':memory:');
  late final SyncClient client;
  _Device(_SyncServer server) {
    addTearDown(store.dispose);
    client = SyncClient(
      store,
      transport: server,
      profile: SyncProfile(
        store,
        _Secrets(),
        watchedKey: (record) => record.id,
      ),
    );
  }

  AppPreferences get preferences =>
      AppPreferences(Map<String, dynamic>.from(store.local('settings') ?? {}));

  void patch(Map<String, dynamic> value) => store.setLocal('settings', {
    ...?store.local('settings') as Map?,
    ...preferences.checkedPatch(value),
  });

  Future<void> sync() => client.synchronize(
    'https://sync.example.com',
    'album-cache-test-sync-token-at-least-24-characters',
  );
}

class _SyncServer implements JsonTransport {
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];

  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (method == 'PUT') {
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
        deleted: incoming.deleted,
        version: (current?.version ?? 0) + 1,
      );
      records[key] = accepted;
      changes.add(accepted);
      return accepted.toJson();
    }
    final after = int.parse(uri.queryParameters['after']!);
    return {
      'changes': changes.skip(after).map((record) => record.toJson()).toList(),
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
