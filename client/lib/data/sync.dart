import 'dart:async';

import 'package:flutter/services.dart';

import '../core/network.dart';
import 'store.dart';
import 'sync_profile.dart';

class SyncClient {
  final AppStore store;
  final JsonTransport transport;
  final SyncProfile? profile;
  bool _running = false;
  Future<void> _tail = Future.value();
  int _queued = 0;
  int profileRevision = 0;
  bool _deviceRead = false;
  SyncClient(this.store, {JsonTransport? transport, this.profile})
    : transport = transport ?? IoJsonTransport();
  Future<void> synchronize(
    String address,
    String token, {
    CancelToken? cancel,
    bool sharedOnly = false,
    Set<String> artworkIds = const {},
    bool deferProfile = false,
  }) async {
    // Keep an invocation queued when another request is in flight: it may
    // contain a newer playback position written after that request's snapshot.
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    _queued++;
    try {
      await previous;
      cancel?.check();
      await _synchronize(
        address,
        token,
        cancel: cancel,
        sharedOnly: sharedOnly,
        artworkIds: artworkIds,
        deferProfile: deferProfile,
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
  }) async {
    final uri = _address(address, token);
    if (store.local('syncOrigin') != uri.origin) {
      store.setLocal('syncOrigin', uri.origin);
    }
    final headers = {'Authorization': 'Bearer $token'};
    await readDeviceInfo();
    _running = true;
    try {
      var artworkRecords = <String>{};
      if (!sharedOnly || artworkIds.isNotEmpty) {
        await profile?.unlock(uri.origin, token);
        cancel?.check();
        if (!sharedOnly) {
          await profile?.prepare(cancel: cancel);
        } else {
          artworkRecords =
              await profile?.prepareArtwork(artworkIds, cancel: cancel) ?? {};
        }
      }
      for (final conflict in store.conflicts) {
        if (sharedOnly && conflict.kind == 'vault') continue;
        _resolveLatest(conflict);
      }
      cancel?.check();
      // Progress ticks must not read/decode pending encrypted artwork just to
      // discard it. Filter those potentially large rows before SQLite returns.
      Future<void> uploadPending() async {
        final pending = store.pendingRecords(includeVault: !sharedOnly);
        if (sharedOnly) {
          for (final id in artworkRecords) {
            final record = store.pendingRecord('vault', id);
            if (record != null) pending.add(record);
          }
        }
        for (final initial in pending) {
          var record = initial;
          if (profile?.shouldUpload(record) == false) continue;
          for (var attempt = 0; attempt < 3; attempt++) {
            cancel?.check();
            Map<String, dynamic> response;
            try {
              response = await transport.send(
                uri.resolve('/v1/records'),
                method: 'PUT',
                body: record.toJson(),
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
                if (record.kind == 'vault') vaultChanged = true;
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
      // decoding the library. The next full sync applies every unapplied row,
      // even though the download cursor has already advanced.
      if (!deferProfile && profile != null && (!sharedOnly || vaultChanged)) {
        if (sharedOnly) await profile!.unlock(uri.origin, token);
        for (final record in store.records('vault')) {
          cancel?.check();
          await profile!.validate(record);
        }
        await profile!.apply(cancel: cancel);
        profileRevision++;
      }
      await uploadPending();
      store.setLocal('lastSync', DateTime.now().toUtc().toIso8601String());
    } finally {
      _running = false;
    }
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
    final own = store.get(remote.kind, remote.id);
    if (own != null && own.version > remote.version) {
      store.db.execute('DELETE FROM conflicts WHERE kind=? AND id=?', [
        remote.kind,
        remote.id,
      ]);
      return true;
    }
    final keepLocal = own != null && own.dirty && newerLocalRecord(own, remote);
    store.resolve(remote, keepLocal: keepLocal);
    return true;
  }

  Future<void> readDeviceInfo() async {
    if (_deviceRead) return;
    _deviceRead = true;
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
          store.setLocal(
            'syncDevice:name',
            [
              deviceName.trim(),
              if (model is String &&
                  model.isNotEmpty &&
                  !deviceName.contains(model))
                model,
              if (platform is String && platform.isNotEmpty) platform,
            ].join(' · '),
          );
          // Offline edits may have been staged before native device details
          // were available. Attach the real name without changing edit time.
          store.db.execute(
            'UPDATE records SET device_name=? WHERE dirty=1 AND device_id=?',
            [store.deviceName, store.deviceId],
          );
          return;
        }
      } catch (_) {
        // Tests, older native shells and headless engines retain the OS host
        // name; no serial number, network address or hardware ID is collected.
      }
    }
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
      for (final key in store.localEntries('syncProfile:applied:').keys) {
        store.removeLocal(key);
      }
      store.removeLocal('syncOrigin');
      store.removeLocal('syncCursor:$origin');
    });
  }
}
