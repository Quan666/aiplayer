import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/network.dart';
import '../core/logger.dart';
import 'credential_storage.dart';
import 'poster_cache.dart';
import 'store.dart';
import 'record_keys.dart';
import 'sync_artwork.dart';
import 'sync_profile.dart';

part 'sync_worker.dart';

class SyncClient {
  static const _pendingProfileKey = 'syncProfile:pendingApply';
  final AppStore store;
  final JsonTransport transport;
  final SyncProfile? profile;
  final bool _useWorker;
  bool _running = false;
  Future<void> _tail = Future.value();
  int _queued = 0;
  int profileRevision = 0;
  bool _deviceRead = false;
  String? _workerDeviceName;
  _SyncWorkerSession? _worker;
  bool _disposed = false;
  @visibleForTesting
  int backgroundWorkerStarts = 0;
  SyncClient(this.store, {JsonTransport? transport, this.profile})
    : transport = transport ?? IoJsonTransport(),
      _useWorker = transport == null && store.path != ':memory:';
  Future<void> synchronize(
    String address,
    String token, {
    CancelToken? cancel,
    bool sharedOnly = false,
    Set<String> artworkIds = const {},
    bool deferProfile = false,
    bool playbackOnly = false,
  }) async {
    // Keep an invocation queued when another request is in flight: it may
    // contain a newer playback position written after that request's snapshot.
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    _queued++;
    try {
      await previous;
      if (_disposed) throw const Cancelled();
      cancel?.check();
      await _synchronize(
        address,
        token,
        cancel: cancel,
        sharedOnly: sharedOnly,
        artworkIds: artworkIds,
        deferProfile: deferProfile,
        playbackOnly: playbackOnly,
      );
    } finally {
      _queued--;
      completed.complete();
    }
  }

  Uri _address(String address, String token) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path)) {
      throw const AppFailure('同步地址须为 HTTP(S) 站点地址。');
    }
    if (token.length < 24) throw const AppFailure('同步 Token 至少需要 24 个字符。');
    // A token rotation does not change record identity; the origin does.
    final previous = store.local('syncOrigin');
    if (previous != null && previous != uri.origin) {
      throw const AppFailure('更换同步服务前，请先在设置中重置同步关联。');
    }
    return uri;
  }

  /// Long polling only signals work. The serialized synchronization operation
  /// owns the cursor, writes and conflict handling, so this can wait in parallel.
  Future<bool> waitForChanges(
    String address,
    String token, {
    CancelToken? cancel,
  }) async {
    final uri = _address(address, token);
    final cursor = (store.local('syncCursor:${uri.origin}') as int?) ?? 0;
    final page = await transport.send(
      uri
          .resolve('/v1/changes')
          .replace(queryParameters: {'after': '$cursor', 'wait': '20'}),
      headers: {'Authorization': 'Bearer $token'},
      cancel: cancel,
    );
    cancel?.check();
    _validatePage(page);
    return (page['changes'] as List).isNotEmpty;
  }

  Future<void> _synchronize(
    String address,
    String token, {
    CancelToken? cancel,
    required bool sharedOnly,
    required Set<String> artworkIds,
    required bool deferProfile,
    required bool playbackOnly,
  }) async {
    if (playbackOnly) {
      if (_useWorker) {
        await _runPlaybackSync(
          store.path,
          address,
          token,
          profile != null,
          cancel,
        );
      } else {
        await _uploadPlayback(address, token, cancel);
      }
      return;
    }
    if (_useWorker &&
        (profile == null || identical(profile!.watchedKey, mediaWatchedKey))) {
      if (!_deviceRead) {
        _workerDeviceName = await _nativeDeviceName();
        _deviceRead = true;
      }
      cancel?.check();
      if (_disposed) throw const Cancelled();
      _running = true;
      try {
        if (_worker == null || _worker!.closed) {
          _worker = _SyncWorkerSession(
            profile?.secrets,
            onPosterChanged: profile?.artwork?.posterCache.fileChanged,
          );
          backgroundWorkerStarts++;
        }
        profileRevision += await _worker!.run(
          _SyncWorkerRequest(
            path: store.path,
            address: address,
            token: token,
            withProfile: profile != null,
            sharedOnly: sharedOnly,
            artworkIds: artworkIds,
            deferProfile: deferProfile,
            recoverMissingCredentials:
                profile?.recoverMissingCredentials ?? false,
            localCredentialDocuments: profile?.secrets is LocalCredentialStorage
                ? (profile!.secrets as LocalCredentialStorage)
                      .directory
                      .parent
                      .path
                : null,
            artworkDocuments: profile?.artwork?.documents.path,
            artworkCache: profile?.artwork?.posterCache.directory.path,
            deviceName: _workerDeviceName,
          ),
          cancel,
        );
        _workerDeviceName = null;
      } finally {
        _running = false;
      }
      return;
    }
    final uri = _address(address, token);
    if (store.local('syncOrigin') != uri.origin) {
      store.setLocal('syncOrigin', uri.origin);
    }
    final headers = {'Authorization': 'Bearer $token'};
    await readDeviceInfo();
    _running = true;
    try {
      var profileUnlocked = false;
      Future<void> unlockProfile() async {
        if (profile == null || profileUnlocked) return;
        await profile!.unlock(uri.origin, token);
        cancel?.check();
        profileUnlocked = true;
      }

      var artworkRecords = <String>{};
      if (!sharedOnly || artworkIds.isNotEmpty) {
        await unlockProfile();
        if (!sharedOnly) {
          await profile?.prepare(cancel: cancel);
        } else {
          artworkRecords =
              await profile?.prepareArtwork(artworkIds, cancel: cancel) ?? {};
        }
      }
      for (final conflict in store.conflictRecords(includeVault: !sharedOnly)) {
        _resolveLatest(conflict);
      }
      cancel?.check();
      // Progress ticks must not read/decode pending encrypted artwork just to
      // discard it. Filter those potentially large rows before SQLite returns.
      Future<void> uploadPending({bool downloaded = false}) async {
        var pending = store.pendingRecords(includeVault: !sharedOnly);
        final mediaIds = {
          for (final record in pending)
            if (record.kind == 'media' &&
                !record.deleted &&
                profile?.shouldUpload(record) != false)
              record.id,
        };
        var dependencies = <String, Set<String>>{};
        if (profile != null && mediaIds.isNotEmpty) {
          await unlockProfile();
          dependencies = await profile!.prepareMediaBindings(
            mediaIds,
            cancel: cancel,
          );
        }
        final selectedVault = {
          ...artworkRecords,
          for (final ids in dependencies.values) ...ids,
        };
        for (final id in selectedVault) {
          final conflict = store.conflictRecord('vault', id);
          if (conflict != null) _resolveLatest(conflict);
        }
        // Preparing dependencies can create new vault rows. Read them only
        // after staging, without decoding unrelated artwork in shared syncs.
        pending = store.pendingRecords(includeVault: !sharedOnly);
        if (sharedOnly) {
          for (final id in selectedVault) {
            final record = store.pendingRecord('vault', id);
            if (record != null) pending.add(record);
          }
        }
        int priority(SyncRecord record) {
          if (record.kind == 'media' && record.deleted) return 0;
          if (record.kind == 'vault') {
            return switch (record.id.split(':').first) {
              'source' || 'external' => 1,
              'binding' => 2,
              _ => 5,
            };
          }
          return record.kind == 'media' ? 3 : 4;
        }

        pending.sort((a, b) {
          final order = priority(a).compareTo(priority(b));
          if (order != 0) return order;
          final kind = a.kind.compareTo(b.kind);
          return kind != 0 ? kind : a.id.compareTo(b.id);
        });
        for (final initial in pending) {
          var record = initial;
          if (profile?.shouldUpload(record) == false) continue;
          // Restore existing remote bindings before publishing a new local
          // catalogue, including after an interrupted full synchronization.
          if ((!downloaded || (profile != null && deferProfile)) &&
              record.kind == 'media' &&
              record.version == 0 &&
              store.isCatalogMedia(record.id)) {
            continue;
          }
          if (profile != null && record.kind == 'media' && !record.deleted) {
            final mediaDependencies = dependencies[record.id];
            if (mediaDependencies == null ||
                mediaDependencies.any((id) {
                  final dependency = store.get('vault', id);
                  return dependency == null ||
                      dependency.dirty ||
                      dependency.deleted ||
                      dependency.version == 0;
                })) {
              continue;
            }
          }
          for (var attempt = 0; attempt < 3; attempt++) {
            cancel?.check();
            Map<String, dynamic> response;
            try {
              response = await transport.send(
                uri.resolve('/v1/records'),
                method: 'PUT',
                body: store.syncPayload(record),
                headers: headers,
                cancel: cancel,
              );
            } on AppFailure catch (error) {
              if (record.kind == 'vault' && error.status == 400) {
                throw const AppFailure('同步服务尚不支持完整配置同步，请升级配套同步服务后重试。');
              }
              rethrow;
            }
            if (response['_status'] == 409) {
              final remote = SyncRecord.fromJson(response['current']);
              if (_resolveLatest(remote)) {
                final latest = store.get(record.kind, record.id);
                if (latest?.dirty == true) {
                  record = latest!;
                  continue;
                }
              }
            } else {
              store.acknowledge(record, SyncRecord.fromJson(response));
            }
            break;
          }
        }
      }

      await uploadPending();
      var cursor = (store.local('syncCursor:${uri.origin}') as int?) ?? 0;
      var vaultChanged = false;
      while (true) {
        final page = await transport.send(
          uri
              .resolve('/v1/changes')
              .replace(queryParameters: {'after': '$cursor'}),
          headers: headers,
          cancel: cancel,
        );
        _validatePage(page);
        final concurrent = <SyncRecord>[];
        store.transaction(() {
          for (final c in page['changes']) {
            final record = SyncRecord.fromJson(Map<String, dynamic>.from(c));
            if (store.shouldSyncRecord(record) &&
                profile?.shouldReceive(record) != false) {
              final own = store.get(record.kind, record.id);
              if (own == null || own.version < record.version) {
                if (record.kind == 'vault') {
                  vaultChanged = true;
                  store.setLocal(_pendingProfileKey, true);
                }
                store.applyRemote(record);
                if (own?.dirty == true) concurrent.add(record);
              }
            }
          }
          if (page['cursor'] != cursor) {
            store.setLocal('syncCursor:${uri.origin}', page['cursor']);
          }
        });
        for (final conflict in concurrent) {
          _resolveLatest(conflict);
        }
        if (!page['hasMore']) break;
        if (page['cursor'] <= cursor) throw const AppFailure('同步游标未前进。');
        cursor = page['cursor'];
      }
      // History can contain ciphertext from a previous token. Finish all pages
      // before decrypting only each record's latest version.
      // During playback, retain downloaded vault records without walking or
      // decoding the library. Keep the pending marker until a later sync applies
      // every row, even though the download cursor has already advanced.
      if (!deferProfile &&
          profile != null &&
          (!sharedOnly ||
              vaultChanged ||
              store.local(_pendingProfileKey) == true)) {
        await unlockProfile();
        for (final record in store.records('vault')) {
          cancel?.check();
          await profile!.validate(record);
        }
        await profile!.apply(cancel: cancel);
        store.removeLocal(_pendingProfileKey);
        profileRevision++;
      }
      await uploadPending(downloaded: true);
      store.setLocal('lastSync', DateTime.now().toUtc().toIso8601String());
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _worker?.close();
  }

  /// Playback publishes progress and watched state only. Incoming catalogues,
  /// encrypted images and configuration wait for the normal sync after exit;
  /// in particular this path never advances the download cursor.
  Future<void> _uploadPlayback(
    String address,
    String token,
    CancelToken? cancel,
  ) async {
    cancel?.check();
    final uri = _address(address, token);
    if (store.local('syncOrigin') != uri.origin) {
      await retryStoreBusy(() {
        cancel?.check();
        store.setLocal('syncOrigin', uri.origin);
      });
    }
    for (final conflict in store.conflictRecords(playbackOnly: true)) {
      await retryStoreBusy(() {
        cancel?.check();
        _resolveLatest(conflict);
      });
    }
    final headers = {'Authorization': 'Bearer $token'};
    for (final initial in store.pendingRecords(playbackOnly: true)) {
      cancel?.check();
      var record = initial;
      if (profile?.shouldUpload(record) == false) continue;
      for (var attempt = 0; attempt < 3; attempt++) {
        cancel?.check();
        final response = await transport.send(
          uri.resolve('/v1/records'),
          method: 'PUT',
          body: record.toJson(),
          headers: headers,
          cancel: cancel,
        );
        cancel?.check();
        if (response['_status'] == 409) {
          final remote = SyncRecord.fromJson(response['current']);
          await retryStoreBusy(() {
            cancel?.check();
            _resolveLatest(remote);
          });
          final latest = store.get(record.kind, record.id);
          if (latest?.dirty == true) {
            record = latest!;
            continue;
          }
        } else {
          await retryStoreBusy(() {
            cancel?.check();
            store.acknowledge(record, SyncRecord.fromJson(response));
          });
        }
        break;
      }
    }
    await retryStoreBusy(() {
      cancel?.check();
      store.setLocal('lastSync', DateTime.now().toUtc().toIso8601String());
    });
  }

  static void _validatePage(Map<String, dynamic> page) {
    if (page['changes'] is! List ||
        page['cursor'] is! int ||
        page['hasMore'] is! bool ||
        page['cursor'] < 0) {
      throw const AppFailure('同步响应格式无效。');
    }
  }

  /// Stable last-write-wins for every record, including deletions and vaults.
  /// Version is a server concurrency token, never a wall-clock timestamp.
  bool _resolveLatest(SyncRecord remote) {
    // The progress writer can commit from another isolate between reads.
    // Compare and resolve under the same database transaction.
    if (remote.kind == 'vault') store.setLocal(_pendingProfileKey, true);
    store.resolveLatest(remote);
    return true;
  }

  Future<void> readDeviceInfo() async {
    if (_deviceRead) return;
    _deviceRead = true;
    final name = await _nativeDeviceName();
    if (name != null) _applyDeviceName(store, name);
  }

  Future<String?> _nativeDeviceName() async {
    for (final name in [
      'app.aiplayer/desktop_player',
      'app.aiplayer/device_info',
    ]) {
      try {
        final info = await MethodChannel(
          name,
        ).invokeMapMethod<String, dynamic>('getDeviceInfo');
        final deviceName = info?['name'];
        final platform = info?['platform'];
        final model = info?['model'];
        if (deviceName is String && deviceName.trim().isNotEmpty) {
          return [
            deviceName.trim(),
            if (model is String &&
                model.isNotEmpty &&
                !deviceName.contains(model))
              model,
            if (platform is String && platform.isNotEmpty) platform,
          ].join(' · ');
        }
      } catch (_) {
        // Tests, older native shells and headless engines retain the OS host
        // name; no serial number, network address or hardware ID is collected.
      }
    }
    return null;
  }

  Future<void> resolve(
    SyncRecord remote, {
    required bool keepLocal,
    required String address,
    required String token,
  }) async {
    if (_running || _queued > 0) throw const AppFailure('请等待当前同步完成后再处理冲突。');
    final completed = Completer<void>();
    _tail = completed.future;
    _running = true;
    try {
      await profile?.unlock(Uri.parse(address).origin, token);
      if (!keepLocal) await profile?.validate(remote);
      store.resolve(remote, keepLocal: keepLocal);
      if (!keepLocal) await profile?.apply(forceId: remote.id);
    } finally {
      _running = false;
      completed.complete();
    }
  }

  void resetAssociation() {
    if (_running || _queued > 0) throw const AppFailure('请等待当前同步完成后再重置关联。');
    final origin = store.local('syncOrigin');
    store.transaction(() {
      store.db.execute('UPDATE records SET version=0,dirty=1');
      store.db.execute('DELETE FROM conflicts');
      // Regenerate encrypted items from the actual local settings when joining
      // another service. The old service's key must not block the migration.
      store.db.execute("DELETE FROM records WHERE kind='vault'");
      store.removeLocal('syncProfile:baseline');
      store.removeLocal(_pendingProfileKey);
      for (final key in store.localEntries('syncProfile:applied:').keys) {
        store.removeLocal(key);
      }
      store.removeLocal('syncOrigin');
      store.removeLocal('syncCursor:$origin');
    });
  }
}

Future<void> _runPlaybackSync(
  String path,
  String address,
  String token,
  bool withProfile,
  CancelToken? cancel,
) async {
  cancel?.check();
  final messages = ReceivePort();
  SendPort? commands;
  var finished = false;
  messages.listen((message) {
    if (message is SendPort) {
      commands = message;
      if (cancel?.cancelled == true) message.send(null);
    }
  });
  unawaited(
    cancel?.whenCancelled.then((_) {
      if (!finished) commands?.send(null);
    }),
  );
  final reply = messages.sendPort;
  try {
    await _spawnPlaybackSync(path, address, token, withProfile, reply);
    cancel?.check();
  } finally {
    finished = true;
    messages.close();
  }
}

// Keep the spawning closure outside the port/cancellation scope so Dart cannot
// capture a shared closure context containing native receive-port resources.
Future<void> _spawnPlaybackSync(
  String path,
  String address,
  String token,
  bool withProfile,
  SendPort reply,
) => Isolate.run(
  () => _playbackSyncWorker(path, address, token, withProfile, reply),
);

Future<void> _playbackSyncWorker(
  String path,
  String address,
  String token,
  bool withProfile,
  SendPort reply,
) async {
  final commands = ReceivePort();
  final cancel = CancelToken();
  commands.listen((_) => cancel.cancel());
  reply.send(commands.sendPort);
  AppStore? store;
  try {
    final opened = await retryStoreBusy(() {
      cancel.check();
      return AppStore.openExisting(path);
    });
    store = opened;
    final client = SyncClient(
      opened,
      profile: withProfile
          ? SyncProfile(
              opened,
              const FlutterSecureStorage(),
              watchedKey: mediaWatchedKey,
            )
          : null,
    );
    // This path uses only database ownership checks, with no plugin calls,
    // secret reads, image processing or profile snapshot construction.
    await client._uploadPlayback(address, token, cancel);
  } finally {
    store?.dispose();
    commands.close();
  }
}
