import 'dart:convert';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../sources/favorites.dart';
import 'credential_storage.dart';
import 'store.dart';
import 'preferences.dart';
import 'media_previews.dart';
import 'sync_artwork.dart';

/// Credentials are staged as authenticated ciphertext, never as plaintext sync
/// records. The server knows the authentication token: this protects stored
/// payloads, and is deliberately not advertised as end-to-end encryption.
class SyncVault {
  static final _aes = AesGcm.with256bits();
  final SecretKey key;
  final List<SecretKey> previous;
  SyncVault(this.key, [this.previous = const []]);

  static Future<SecretKey> derive(String token) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(utf8.encode(token)),
        nonce: utf8.encode('aiplayer-sync-vault-v1'),
        info: utf8.encode('AES-GCM-256'),
      );

  Future<Map<String, dynamic>> seal(
    String id,
    Map<String, dynamic> data,
  ) async {
    late final List<int> bytes;
    try {
      bytes = utf8.encode(jsonEncode(data));
    } catch (_) {
      throw const AppFailure('同步配置格式无效。');
    }
    if (bytes.length > 180 * 1024) {
      throw const AppFailure('单项同步配置过大，请缩短自定义内容。');
    }
    final box = await _aes.encrypt(
      bytes,
      secretKey: key,
      aad: utf8.encode('aiplayer:vault:1:$id'),
    );
    return {
      'algorithm': 'AES-GCM-256',
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> open(SyncRecord record) async {
    if (record.deleted) return const {};
    try {
      final data = record.data;
      if (data['algorithm'] != 'AES-GCM-256' || data.length != 4) {
        throw const FormatException();
      }
      final box = SecretBox(
        base64Decode(data['ciphertext'] as String),
        nonce: base64Decode(data['nonce'] as String),
        mac: Mac(base64Decode(data['mac'] as String)),
      );
      if (box.nonce.length != 12 ||
          box.mac.bytes.length != 16 ||
          box.cipherText.isEmpty ||
          box.cipherText.length > 180 * 1024) {
        throw const FormatException();
      }
      for (final candidate in [key, ...previous]) {
        try {
          final bytes = await _aes.decrypt(
            box,
            secretKey: candidate,
            aad: utf8.encode('aiplayer:vault:1:${record.id}'),
          );
          return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)));
        } on SecretBoxAuthenticationError {
          continue;
        }
      }
    } catch (_) {
      // No provider URL, decrypted payload, password or key in diagnostics.
    }
    throw const AppFailure(
      '无法解密同步配置，请确认各设备使用相同的同步 Token。更换 Token 后，请先在原设备同步一次。',
    );
  }
}

class _ProfileEntry {
  final String type, key;
  final dynamic value;
  const _ProfileEntry(this.type, this.key, this.value);
  String get id => '$type:${hash.sha256.convert(utf8.encode(key))}';
  Map<String, dynamic> get descriptor => {'type': type, 'key': key};
  Map<String, dynamic> get payload => {...descriptor, 'value': value};
  factory _ProfileEntry.fromJson(Map<String, dynamic> json) {
    if (json['type'] is! String || json['key'] is! String) {
      throw const AppFailure('同步配置格式无效。');
    }
    return _ProfileEntry(json['type'], json['key'], json['value']);
  }
}

/// Bridges device settings/credential storage to per-item, versioned sync records.
/// A baseline distinguishes an untouched new device from an explicit deletion.
class SyncProfile {
  final AppStore store;
  final FlutterSecureStorage secrets;
  final String Function(SyncRecord) watchedKey;
  final SyncArtwork? artwork;
  final bool recoverMissingCredentials;
  SyncProfile(
    this.store,
    this.secrets, {
    required this.watchedKey,
    this.artwork,
    this.recoverMissingCredentials = false,
  });
  static const secretKeys = ['danmuToken', 'tmdb.apiKey', 'aiSubtitleToken'];
  static const _baselineKey = 'syncProfile:baseline';
  static const _credentialRecoveryKey = 'syncProfile:credentialRecovery';
  static const _remoteMediaKey = 'syncProfile:remoteMedia';
  static const _localMediaKey = 'syncProfile:localMedia';
  static const _portablePrefixes = [
    'metadataEpisodeNames:',
    'media-title-display:',
    'media-title-translation:',
    'summary-translation:',
    'subtitle-ai:',
    'directory-preview:',
  ];
  late SyncVault _vault;
  late List<int> _digestKey;
  final Map<String, Map<String, dynamic>> _decoded = {};
  Set<String> _uploadIds = {}, _uploadWatched = {};
  (int, int)? _bindingsRevision;
  Set<String> _knownRemoteMedia = {}, _knownLocalMedia = {};

  Map<String, dynamic> get _baseline =>
      Map<String, dynamic>.from(store.local(_baselineKey) ?? {});
  void _readMediaBindings() {
    final revision = (
      store.localKeyRevision(_remoteMediaKey),
      store.localKeyRevision(_localMediaKey),
    );
    if (_bindingsRevision == revision) return;
    _knownRemoteMedia = (store.local(_remoteMediaKey) as List? ?? [])
        .cast<String>()
        .toSet();
    _knownLocalMedia = (store.local(_localMediaKey) as List? ?? [])
        .cast<String>()
        .toSet();
    _bindingsRevision = revision;
  }

  Set<String> get _remoteMedia {
    _readMediaBindings();
    return {..._knownRemoteMedia};
  }

  Set<String> get _localMedia {
    _readMediaBindings();
    return {..._knownLocalMedia};
  }

  static String _canonical(dynamic value) {
    dynamic sort(dynamic v) {
      if (v is Map) {
        final keys = v.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: sort(v[key])};
      }
      if (v is List) return v.map(sort).toList();
      return v;
    }

    return jsonEncode(sort(value));
  }

  String? _fingerprint(_ProfileEntry? value) => value == null
      ? null
      : hash.Hmac(
          hash.sha256,
          _digestKey,
        ).convert(utf8.encode(_canonical(value.payload))).toString();
  String _stamp(SyncRecord record) =>
      hash.sha256.convert(utf8.encode(_canonical(record.toJson()))).toString();

  /// Called before publishing or applying records. Prior keys remain solely in
  /// credential storage so token rotation can re-encrypt records already downloaded.
  Future<void> unlock(String origin, String token) async {
    _decoded.clear();
    final key = await SyncVault.derive(token);
    final bytes = await key.extractBytes();
    final encoded = base64Encode(bytes);
    final keyName =
        'sync.vaultKeys:${hash.sha256.convert(utf8.encode(origin))}';
    final saved = await secrets.read(key: keyName);
    final keys = saved == null
        ? <String>[]
        : (jsonDecode(saved) as List).cast<String>();
    _vault = SyncVault(key, [
      for (final k in keys.where((k) => k != encoded))
        SecretKey(base64Decode(k)),
    ]);
    if (keys.isEmpty || keys.first != encoded) {
      await secrets.write(
        key: keyName,
        value: jsonEncode(
          [encoded, ...keys.where((k) => k != encoded)].take(4).toList(),
        ),
      );
    }
    final digest = await secrets.read(key: 'sync.digestKey');
    if (digest == null) {
      if (recoverMissingCredentials && _baseline.isNotEmpty) {
        // Persist before writing the new digest so an interrupted recovery is
        // retried even after the replacement credential store has that key.
        store.setLocal(_credentialRecoveryKey, true);
      }
      _digestKey = await (await AesGcm.with256bits().newSecretKey())
          .extractBytes();
      final storage = secrets;
      if (storage is LocalCredentialStorage) {
        _digestKey = base64Decode(
          await storage.readOrCreate(
            key: 'sync.digestKey',
            value: base64Encode(_digestKey),
          ),
        );
      } else {
        await secrets.write(
          key: 'sync.digestKey',
          value: base64Encode(_digestKey),
        );
      }
    } else {
      _digestKey = base64Decode(digest);
    }
    if (recoverMissingCredentials &&
        store.local(_credentialRecoveryKey) == true) {
      await _recoverCredentialStorage();
    }
  }

  Future<void> _recoverCredentialStorage() async {
    final baseline = _baseline;
    final previous = <String, _ProfileEntry?>{};
    // Verify the whole previous baseline before writing credentials or sync
    // records. Lost rotation keys must never turn into uploaded deletions.
    for (final id in baseline.keys) {
      final record = store.get('vault', id);
      if (record == null) {
        throw const AppFailure('无法恢复已有同步凭据，请先恢复同步配置后重试。');
      }
      if (!record.dirty &&
          store.local('syncProfile:applied:$id') != _stamp(record)) {
        // A newer download may have failed to reach credential storage. Its
        // payload cannot reconstruct the older baseline: treating it as that
        // baseline would upload stale local values over the remote update.
        throw const AppFailure('存在尚未应用的同步配置，已暂停凭据恢复以避免覆盖远端修改。');
      }
      if (record.deleted) {
        previous[id] = null;
        continue;
      }
      final entry = _ProfileEntry.fromJson(await _vault.open(record));
      if (entry.id != id) throw const AppFailure('同步配置标识不匹配。');
      _validateEntry(entry);
      previous[id] = entry;
    }
    for (final entry in previous.values.whereType<_ProfileEntry>()) {
      final key = switch (entry.type) {
        'secret' => entry.key,
        'source' => 'source:${entry.key}',
        _ => null,
      };
      if (key != null && await secrets.read(key: key) == null) {
        final value = entry.type == 'source'
            ? entry.value['password'] as String
            : entry.value as String;
        AppLog.instance.rememberSecret(value);
        final storage = secrets;
        if (storage is LocalCredentialStorage) {
          await storage.readOrCreate(key: key, value: value);
        } else {
          await secrets.write(key: key, value: value);
        }
      }
    }
    for (final row in previous.entries) {
      baseline[row.key] = {
        // Use the old encrypted payload, not today's local snapshot: genuine
        // offline edits and explicitly reentered credentials still sync.
        'fingerprint': _fingerprint(row.value),
        'descriptor':
            row.value?.descriptor ?? (baseline[row.key] as Map?)?['descriptor'],
      };
    }
    store.transaction(() {
      store.setLocal(_baselineKey, baseline);
      store.removeLocal(_credentialRecoveryKey);
    });
  }

  Future<Map<String, _ProfileEntry>> _snapshot({CancelToken? cancel}) async {
    cancel?.check();
    final entries = <String, _ProfileEntry>{};
    void put(String type, String key, dynamic value) {
      final entry = _ProfileEntry(type, key, value);
      entries[entry.id] = entry;
    }

    final settings = Map<String, dynamic>.from(store.local('settings') ?? {});
    for (final key in settings.keys.where(
      (key) => key != 'syncOrigin' && key != 'syncToken',
    )) {
      put('setting', key, settings[key]);
    }
    for (final key in secretKeys) {
      final value = await secrets.read(key: key);
      if (value != null && value.isNotEmpty) put('secret', key, value);
    }
    final theme = store.local('appearance:theme');
    if (theme != null) put('local', 'appearance:theme', theme);
    final sources = (store.local('sources') as List? ?? []).whereType<Map>();
    for (final source in sources) {
      cancel?.check();
      final id = source['id'];
      if (id is! String || id == 'local' || source['kind'] == 'local') continue;
      final password = await secrets.read(key: 'source:$id');
      if (recoverMissingCredentials && password == null) {
        throw const AppFailure('来源密码尚未恢复，请重新保存来源密码后再同步。');
      }
      put('source', id, {
        'configuration': {...source}..remove('password'),
        'password': password ?? '',
      });
    }
    if (sources.isNotEmpty) {
      put(
        'local',
        'sourceOrder',
        sources.map((s) => s['id']).where((id) => id != 'local').toList(),
      );
    }
    for (final row in store.localEntries('externalSource:').entries) {
      final source = row.value;
      if (source is Map &&
          source['transient'] != true &&
          ['http', 'smb', 'webdav'].contains(source['kind'])) {
        put('external', row.key.substring('externalSource:'.length), source);
      }
    }
    final remoteIds = _remoteMedia;
    final localIds = _localMedia;
    final catalogIds = (store.local(AppStore.catalogMediaKey) as List? ?? [])
        .cast<String>()
        .toSet();
    var processed = 0;
    for (final record in store.records('media')) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      cancel?.check();
      if (!record.deleted &&
          record.data['transient'] != true &&
          (record.data['localOnly'] == true || localIds.contains(record.id)) &&
          !remoteIds.contains(record.id)) {
        catalogIds.add(record.id);
      }
    }
    for (final location in store.locations) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      cancel?.check();
      final id = location['id'], source = location['source'];
      if (id is! String || source is! String) continue;
      final record = store.get('media', id);
      if (record?.data['transient'] == true) continue;
      if (source == 'local' ||
          record?.data['localOnly'] == true ||
          localIds.contains(id)) {
        localIds.add(id);
        if (record?.deleted == false && !remoteIds.contains(id)) {
          catalogIds.add(id);
        }
        continue;
      }
      remoteIds.add(id);
      if (record?.deleted != false) continue;
      put('binding', id, {
        'location': {
          for (final key in [
            'id',
            'source',
            'path',
            'size',
            'modified',
            'previewRevision',
          ])
            if (location.containsKey(key)) key: location[key],
        },
        'episodeTitle': store.local('episodeTitle:$id'),
        'manualMetadata': store.local('manualMetadata:$id') == true,
        for (final kind in ['mediaMetadata', 'technical'])
          if (_validFacts(kind, store.local('$kind:$id'), location))
            kind: store.local('$kind:$id'),
      });
    }
    store.setLocal(_remoteMediaKey, remoteIds.toList());
    store.setLocal(_localMediaKey, localIds.toList());
    store.setLocal(AppStore.catalogMediaKey, catalogIds.toList());
    for (final favorite in SourceFavorites(store).all) {
      if (favorite.sourceId != 'local') {
        put('favorite', favorite.key, favorite.toJson());
      }
    }
    for (final row in store.localEntries('directorySort:').entries) {
      if (!row.key.startsWith('directorySort:local:')) {
        put('local', row.key, row.value);
      }
    }
    for (final prefix in _portablePrefixes) {
      for (final row in store.localEntries(prefix).entries) {
        final value = prefix == 'directory-preview:' && row.value is Map
            ? (Map<String, dynamic>.from(row.value)..remove('context'))
            : row.value;
        if (!_validPortableLocal(row.key, value)) continue;
        final entry = _ProfileEntry('local', row.key, value);
        // Successful caches can be much larger than a configuration record.
        // Leave an oversized cache local instead of blocking all syncing.
        if (utf8.encode(jsonEncode(entry.payload)).length <= 180 * 1024) {
          entries[entry.id] = entry;
        }
      }
    }
    for (final row
        in (await artwork?.snapshot(cancel: cancel) ?? <String, dynamic>{})
            .entries) {
      put('artwork', row.key, row.value);
    }
    // Cache eviction, a device without artwork support, and a missing image
    // file are not shared deletions. Retain the synchronized value until a
    // replacement exists, including while rotating the encryption token.
    final baseline = _baseline;
    for (final record in store.records('vault')) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      cancel?.check();
      if (record.deleted || entries.containsKey(record.id)) continue;
      final optional =
          record.id.startsWith('artwork:') ||
          (record.id.startsWith('local:') &&
              _portableKey(
                (baseline[record.id] as Map?)?['descriptor']?['key'],
              ));
      if (!optional && !record.id.startsWith('local:')) continue;
      try {
        final entry = _ProfileEntry.fromJson(await _vault.open(record));
        if (entry.id != record.id) continue;
        if (entry.type == 'artwork' ||
            (entry.type == 'local' && _portableKey(entry.key))) {
          _validateEntry(entry);
          entries[entry.id] = entry;
        }
      } on AppFailure {
        // Download/validation handles unavailable or obsolete ciphertext.
      }
    }
    return entries;
  }

  static bool _portableKey(dynamic key) =>
      key is String && _portablePrefixes.any(key.startsWith);

  static String _previewFingerprint(Map location) => MediaPreviewRequest(
    location['id'] as String,
    location['source'] as String,
    location['path'] as String,
    (location['size'] as num?)?.toInt() ?? 0,
    revision: location['previewRevision'] as String? ?? '',
  ).contentFingerprint;

  static String _technicalFingerprint(Map location) => hash.sha256
      .convert(
        utf8.encode(
          jsonEncode([
            location['source'],
            location['path'],
            location['size'],
            location['modified'],
          ]),
        ),
      )
      .toString();

  static bool _validFacts(String kind, dynamic value, Map location) {
    if (value is! Map || value.length < 2) return false;
    final allowed = kind == 'technical'
        ? {
            'fingerprint',
            'container',
            'codec',
            'width',
            'height',
            'bitrate',
            'duration',
          }
        : {'fingerprint', 'width', 'height', 'duration'};
    if (value.keys.any((key) => !allowed.contains(key)) ||
        value['fingerprint'] !=
            (kind == 'technical'
                ? _technicalFingerprint(location)
                : _previewFingerprint(location))) {
      return false;
    }
    for (final row in value.entries) {
      if (row.key == 'fingerprint') continue;
      if (row.key == 'container' || row.key == 'codec') {
        if (row.value is! String || (row.value as String).length > 200) {
          return false;
        }
      } else if (row.value is! num ||
          !(row.value as num).isFinite ||
          (row.value as num) <= 0) {
        return false;
      }
    }
    return true;
  }

  static bool _strings(dynamic value, {int max = 8000}) =>
      value is Map &&
      value.entries.every(
        (row) =>
            row.key is String &&
            (row.key as String).length <= max &&
            row.value is String &&
            (row.value as String).length <= max,
      );

  static bool _validPortableLocal(String key, dynamic value) {
    final suffix = key.substring(key.indexOf(':') + 1);
    if (key.startsWith('metadataEpisodeNames:')) {
      return suffix.isNotEmpty && suffix.length <= 2000 && _strings(value);
    }
    if (key.startsWith('subtitle-ai:')) {
      return RegExp(r'^[a-f0-9]{64}:[a-f0-9]{64}$').hasMatch(suffix) &&
          value is Map &&
          value.length == 2 &&
          value['version'] == 1 &&
          _strings(value['values'], max: 32000) &&
          (value['values'] as Map).keys.every(
            (id) => RegExp(r'^\d{1,7}$').hasMatch(id as String),
          );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(suffix)) return false;
    if (key.startsWith('media-title-translation:')) {
      return value is String && value.isNotEmpty && value.length <= 8000;
    }
    if (key.startsWith('summary-translation:')) {
      return value is String && value.isNotEmpty && value.length <= 128000;
    }
    if (key.startsWith('media-title-display:')) {
      return value is Map &&
          value.keys.every((k) => ['visible', 'titles'].contains(k)) &&
          value['visible'] is bool &&
          (value['titles'] == null || _strings(value['titles']));
    }
    if (key.startsWith('directory-preview:')) return _validDirectory(value);
    return false;
  }

  static bool _validDirectory(dynamic value) {
    if (value is! Map ||
        value['sourceId'] is! String ||
        value['sourceId'] == 'local' ||
        (value['sourceId'] as String).isEmpty ||
        value['fingerprint'] is! String ||
        value['at'] is! int ||
        value['modified'] is! int ||
        value['collection'] is! Map ||
        value.keys.any(
          (key) => ![
            'sourceId',
            'fingerprint',
            'at',
            'modified',
            'collection',
          ].contains(key),
        )) {
      return false;
    }
    final collection = value['collection'] as Map;
    if (collection['title'] is! String ||
        collection['season'] is! String ||
        collection['videos'] is! List ||
        collection['identities'] is! Map ||
        collection['subject'] is! Map ||
        !_strings(collection['episodeTitles']) ||
        collection.keys.any(
          (key) => ![
            'title',
            'season',
            'videos',
            'identities',
            'subject',
            'episodeTitles',
          ].contains(key),
        )) {
      return false;
    }
    // Only successful catalogue matches are portable. Paths here are relative
    // to the encrypted remote source, never locations on the current device.
    final subject = collection['subject'] as Map;
    if (!['bangumi', 'tmdb'].contains(subject['provider']) ||
        (subject['id'] is! String && subject['id'] is! num)) {
      return false;
    }
    for (final video in collection['videos'] as List) {
      if (video is! Map ||
          video['name'] is! String ||
          video['path'] is! String ||
          video['size'] is! int ||
          video['size'] < 0 ||
          (video['modified'] != null && video['modified'] is! int) ||
          video['hidden'] is! bool ||
          video.keys.any(
            (key) =>
                !['name', 'path', 'size', 'modified', 'hidden'].contains(key),
          )) {
        return false;
      }
    }
    return (collection['identities'] as Map).entries.every(
      (row) =>
          row.key is String &&
          row.value is List &&
          (row.value as List).length == 3 &&
          (row.value as List).every((item) => item is String),
    );
  }

  Future<void> prepare({CancelToken? cancel}) async {
    final snapshot = await _snapshot(cancel: cancel);
    _uploadIds = _remoteMedia.difference(_localMedia);
    _uploadWatched = {
      for (final record in store.records('media'))
        if (_uploadIds.contains(record.id)) watchedKey(record),
    };
    await _prepareEntries(snapshot, {
      ...snapshot.keys,
      ..._baseline.keys,
      ...store.records('vault').map((r) => r.id),
    }, cancel: cancel);
  }

  /// Stages only the encrypted playback dependencies of the selected media.
  /// The caller must acknowledge these records before publishing their media.
  Future<Map<String, Set<String>>> prepareMediaBindings(
    Set<String> mediaIds, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final snapshot = <String, _ProfileEntry>{};
    final dependencies = await _snapshotMediaBindings(
      mediaIds,
      snapshot,
      cancel: cancel,
    );
    await _prepareEntries(snapshot, snapshot.keys.toSet(), cancel: cancel);
    return dependencies;
  }

  Future<Map<String, Set<String>>> _snapshotMediaBindings(
    Set<String> mediaIds,
    Map<String, _ProfileEntry> snapshot, {
    CancelToken? cancel,
  }) async {
    final dependencies = <String, Set<String>>{};
    _readMediaBindings();
    final sources = (store.local('sources') as List? ?? []).whereType<Map>();
    final sourceEntries = <String, _ProfileEntry?>{};
    var processed = 0;
    for (final id in mediaIds) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      cancel?.check();
      final location = store.local('location:$id');
      if (store.isCatalogMedia(id) ||
          (location == null &&
              !store.isPrivateMedia(id) &&
              !_knownRemoteMedia.contains(id))) {
        dependencies[id] = {};
        continue;
      }
      if (id.isEmpty ||
          location is! Map ||
          location['id'] != id ||
          location['source'] is! String ||
          (location['source'] as String).isEmpty ||
          location['source'] == 'local' ||
          location['path'] is! String ||
          store.isPrivateMedia(id) ||
          store.get('media', id)?.deleted != false) {
        continue;
      }
      final sourceId = location['source'] as String;
      if (!sourceEntries.containsKey(sourceId)) {
        final source = sources
            .where((source) => source['id'] == sourceId)
            .firstOrNull;
        _ProfileEntry? entry;
        if (source != null) {
          if (source['transient'] != true && _validSource(sourceId, source)) {
            final password = await secrets.read(key: 'source:$sourceId');
            cancel?.check();
            if (recoverMissingCredentials && password == null) {
              throw const AppFailure('来源密码尚未恢复，请重新保存来源密码后再同步。');
            }
            entry = _ProfileEntry('source', sourceId, {
              'configuration': {...source}..remove('password'),
              'password': password ?? '',
            });
          }
        } else {
          final external = store.local('externalSource:$sourceId');
          if (external is Map &&
              external['transient'] != true &&
              _validSource(sourceId, external)) {
            entry = _ProfileEntry('external', sourceId, external);
          }
        }
        sourceEntries[sourceId] = entry;
      }
      final source = sourceEntries[sourceId];
      if (source == null) continue;
      final binding = _ProfileEntry('binding', id, {
        'location': {
          for (final key in [
            'id',
            'source',
            'path',
            'size',
            'modified',
            'previewRevision',
          ])
            if (location.containsKey(key)) key: location[key],
        },
        'episodeTitle': store.local('episodeTitle:$id'),
        'manualMetadata': store.local('manualMetadata:$id') == true,
        for (final kind in ['mediaMetadata', 'technical'])
          if (_validFacts(kind, store.local('$kind:$id'), location))
            kind: store.local('$kind:$id'),
      });
      snapshot[source.id] = source;
      snapshot[binding.id] = binding;
      dependencies[id] = {source.id, binding.id};
    }
    return dependencies;
  }

  /// A paused/exiting player's screenshot needs only its source, binding and
  /// artwork. Avoid scanning every library location and encoding other posters.
  Future<Set<String>> prepareArtwork(
    Set<String> mediaIds, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final snapshot = <String, _ProfileEntry>{};
    await _snapshotMediaBindings(mediaIds, snapshot, cancel: cancel);
    for (final row
        in (await artwork?.snapshot(mediaIds: mediaIds, cancel: cancel) ??
                <String, dynamic>{})
            .entries) {
      final entry = _ProfileEntry('artwork', row.key, row.value);
      snapshot[entry.id] = entry;
    }
    await _prepareEntries(snapshot, snapshot.keys.toSet(), cancel: cancel);
    return snapshot.keys.toSet();
  }

  List<String> _entryKeys(Map? descriptor) {
    final type = descriptor?['type'], key = descriptor?['key'];
    return switch (type) {
      'setting' => ['setting:$key'],
      'secret' => ['secret:$key'],
      'source' => ['source:$key'],
      'external' => ['externalSource:$key'],
      'binding' => [
        'location:$key',
        'episodeTitle:$key',
        'manualMetadata:$key',
        'mediaMetadata:$key',
        'technical:$key',
      ],
      'artwork' => ['$key'],
      'favorite' => ['favorite:$key'],
      'local' => ['$key'],
      _ => [],
    };
  }

  String? _entryModified(Map? descriptor) {
    DateTime? latest;
    for (final key in _entryKeys(descriptor)) {
      final time = DateTime.tryParse(store.localModified(key) ?? '');
      if (time != null && (latest == null || time.isAfter(latest))) {
        latest = time;
      }
    }
    return latest?.toUtc().toIso8601String();
  }

  Future<void> _prepareEntries(
    Map<String, _ProfileEntry> snapshot,
    Set<String> ids, {
    CancelToken? cancel,
  }) async {
    final baseline = _baseline;
    final localMedia = _localMedia;
    // Recover rotation even after interruption: each entry is compared with the
    // current key, so a previous failed upload cannot leave old ciphertext.
    var processed = 0;
    try {
      for (final id in ids) {
        if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
        cancel?.check();
        final entry = snapshot[id];
        final old = baseline[id] as Map?;
        final bindingKey = old?['descriptor']?['type'] == 'binding'
            ? old?['descriptor']?['key'] as String?
            : null;
        final preserveBinding =
            bindingKey != null &&
            (localMedia.contains(bindingKey) ||
                (entry == null &&
                    store.get('media', bindingKey)?.deleted != true));
        final fingerprint = _fingerprint(entry);
        final record = store.get('vault', id);
        if (entry == null && old == null && record?.dirty != true) continue;
        if (record != null &&
            !record.dirty &&
            store.local('syncProfile:applied:$id') != _stamp(record)) {
          // Playback can download a newer remote version without applying it.
          // Do not base a local upload on that unseen version: it would bypass
          // the server's conflict check. apply() compares it with the original
          // baseline and either merges or exposes the concurrent local edit.
          // Our own acknowledged checkpoint has the baseline fingerprint and
          // may safely be replaced by the next pause/exit capture.
          try {
            final remote = record.deleted
                ? null
                : _ProfileEntry.fromJson(await _vault.open(record));
            if (_fingerprint(remote) != old?['fingerprint']) continue;
          } on AppFailure {
            // Validation after downloading the latest version reports damaged
            // or obsolete ciphertext without uploading over it.
            continue;
          }
        }
        var rotate = false;
        if (record != null && !record.deleted) {
          try {
            await SyncVault(_vault.key).open(record);
          } on AppFailure {
            try {
              await _vault.open(record);
              rotate = true;
            } on AppFailure {
              // A clean download may be corrupt or encrypted with an older token.
              // Fetch its latest server version before reporting an error, so a
              // repaired record can recover without resetting the entire profile.
              if (record.dirty) rethrow;
              continue;
            }
          }
        }
        if (preserveBinding || (entry == null && old == null)) {
          // A missing location or local override does not delete a shared
          // binding. Only an explicit media deletion does; rotation preserves it.
          if (rotate) {
            store.save(
              'vault',
              id,
              await _vault.seal(id, await _vault.open(record!)),
            );
          }
          continue;
        }
        if (old?['fingerprint'] == fingerprint && !rotate) continue;
        if (entry == null && old == null) continue;
        final data = entry == null
            ? <String, dynamic>{}
            : await _vault.seal(id, entry.payload);
        store.save(
          'vault',
          id,
          data,
          deleted: entry == null,
          modifiedAt: rotate && old?['fingerprint'] == fingerprint
              ? record?.modifiedAt
              : _entryModified(entry?.descriptor ?? old?['descriptor']),
          deviceId: rotate && old?['fingerprint'] == fingerprint
              ? record?.deviceId
              : null,
          deviceName: rotate && old?['fingerprint'] == fingerprint
              ? record?.deviceName
              : null,
        );
        baseline[id] = {
          'fingerprint': fingerprint,
          'descriptor': entry?.descriptor ?? old?['descriptor'],
        };
      }
    } finally {
      // Cancellation must retain the baseline of ciphertext already staged.
      store.setLocal(_baselineKey, baseline);
    }
  }

  bool shouldUpload(SyncRecord record) {
    if (record.kind == 'vault') return true;
    if (record.kind == 'media' &&
        (store.isCatalogMedia(record.id) ||
            (store.local('location:${record.id}') == null &&
                !store.isPrivateMedia(record.id)))) {
      return record.data['transient'] != true;
    }
    // Lightweight progress sync skips the full encrypted snapshot. Remembered
    // remote bindings still identify eligible records after an app restart.
    _readMediaBindings();
    bool eligible(String id) {
      if (_knownLocalMedia.contains(id)) return false;
      final data = store.get('media', id)?.data;
      if (data?['localOnly'] == true || data?['transient'] == true) {
        return false;
      }
      final location = store.local('location:$id');
      if (location is Map && location['source'] == 'local') {
        return false;
      }
      return _uploadIds.contains(id) ||
          _knownRemoteMedia.contains(id) ||
          location is Map && location['source'] is String;
    }

    if (record.kind == 'media' || record.kind == 'match') {
      return eligible(record.id);
    }
    if (record.kind == 'progress') {
      final separator = record.id.lastIndexOf(':');
      return separator > 0 && eligible(record.id.substring(0, separator));
    }
    if (record.kind == 'watched') {
      final matches = store
          .records('media')
          .where((media) => watchedKey(media) == record.id)
          .toList();
      return matches.any((media) => eligible(media.id)) ||
          (matches.isEmpty && _uploadWatched.contains(record.id));
    }
    return false;
  }

  bool shouldReceive(SyncRecord record) {
    if (record.kind == 'media' && store.isCatalogMedia(record.id)) {
      // A previously synchronized record may be deliberately associated with
      // a different local file before this device first connects. Wait until
      // its encrypted binding distinguishes that override from a catalogue.
      return (store.get('media', record.id)?.version ?? 0) > 0;
    }
    var id = record.id;
    if (record.kind == 'progress' && id.contains(':')) {
      id = id.substring(0, id.lastIndexOf(':'));
    }
    if (['media', 'match', 'progress'].contains(record.kind)) {
      _readMediaBindings();
      return !_knownLocalMedia.contains(id) &&
          (store.local('location:$id') as Map?)?['source'] != 'local';
    }
    return true;
  }

  Future<void> validate(SyncRecord record) async {
    if (record.kind != 'vault' || record.deleted) return;
    if (store.local('syncProfile:applied:${record.id}') == _stamp(record)) {
      return;
    }
    final data = await _vault.open(record);
    final entry = _ProfileEntry.fromJson(data);
    if (entry.id != record.id) throw const AppFailure('同步配置标识不匹配。');
    _validateEntry(entry);
    _decoded[_stamp(record)] = data;
  }

  void _validateEntry(_ProfileEntry entry) {
    final value = entry.value;
    final valid = switch (entry.type) {
      'setting' => _validSetting(entry.key, value),
      'secret' => secretKeys.contains(entry.key) && value is String,
      'source' =>
        entry.key != 'local' &&
            value is Map &&
            value['password'] is String &&
            _validSource(entry.key, value['configuration']),
      'external' => _validSource(entry.key, value),
      'binding' =>
        value is Map &&
            value['location'] is Map &&
            value['location']['id'] == entry.key &&
            value['location']['source'] is String &&
            value['location']['source'] != 'local' &&
            value['location']['path'] is String &&
            (value['location']['size'] == null ||
                value['location']['size'] is num) &&
            (value['location']['modified'] == null ||
                value['location']['modified'] is num) &&
            (value['location']['previewRevision'] == null ||
                value['location']['previewRevision'] is String) &&
            (value['episodeTitle'] == null ||
                value['episodeTitle'] is String) &&
            (value['manualMetadata'] == null ||
                value['manualMetadata'] is bool) &&
            ['mediaMetadata', 'technical'].every(
              (kind) =>
                  !value.containsKey(kind) ||
                  _validFacts(kind, value[kind], value['location']),
            ),
      'artwork' => SyncArtwork.valid(entry.key, value),
      'favorite' =>
        value is Map &&
            value['sourceId'] is String &&
            value['sourceId'] != 'local' &&
            value['path'] is String &&
            value['name'] is String &&
            SourceFavorite(
                  sourceId: value['sourceId'],
                  path: value['path'],
                  name: value['name'],
                ).key ==
                entry.key,
      'local' =>
        (entry.key == 'appearance:theme' &&
                ['dark', 'light'].contains(value)) ||
            (entry.key == 'sourceOrder' &&
                value is List &&
                value.every((id) => id is String && id != 'local') &&
                value.toSet().length == value.length) ||
            (entry.key.startsWith('directorySort:') &&
                !entry.key.startsWith('directorySort:local:') &&
                value is Map) ||
            _validPortableLocal(entry.key, value),
      _ => false,
    };
    if (!valid) throw const AppFailure('同步配置内容无效，请更新各设备的播放器版本。');
  }

  bool _validSource(String id, dynamic value) {
    if (id == 'local' ||
        value is! Map ||
        value['id'] != id ||
        !['smb', 'webdav', 'http'].contains(value['kind'])) {
      return false;
    }
    for (final key in [
      'label',
      'host',
      'share',
      'url',
      'path',
      'user',
      'domain',
      'smbSecurity',
    ]) {
      if (value.containsKey(key) && value[key] is! String) return false;
    }
    return (!value.containsKey('port') || value['port'] is int) &&
        (!value.containsKey('encrypted') || value['encrypted'] is bool);
  }

  bool _validSetting(String key, dynamic value) {
    if (key == 'syncOrigin' || key == 'syncToken') return false;
    try {
      if (AppPreferences.defaults.containsKey(key) || key == 'shortcuts') {
        AppPreferences(const {}).checkedPatch({key: value});
        return true;
      }
      if ([
        'danmuOrigin',
        'metadataProvider',
        'metadataStrategy',
        'aiSubtitleOrigin',
        'aiSubtitleModel',
        'aiSubtitleTarget',
        'aiSubtitlePrompt',
      ].contains(key)) {
        return value is String;
      }
      // Preserve future scalar preferences without arbitrary local-store writes.
      return value is String || value is num || value is bool;
    } catch (_) {
      return false;
    }
  }

  Future<void> apply({String? forceId, CancelToken? cancel}) async {
    final current = await _snapshot(cancel: cancel);
    final baseline = _baseline;
    final conflicts = store.conflicts
        .where((r) => r.kind == 'vault')
        .map((r) => r.id)
        .toSet();
    final records = store.records('vault');
    int priority(SyncRecord record) => switch (record.id.split(':').first) {
      'source' || 'external' || 'setting' || 'secret' => 0,
      'binding' => 1,
      'artwork' => 3,
      _ => 2,
    };
    records.sort((a, b) {
      final order = priority(a).compareTo(priority(b));
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    for (final record in records) {
      cancel?.check();
      if (record.dirty || conflicts.contains(record.id)) continue;
      final stamp = _stamp(record);
      if (store.local('syncProfile:applied:${record.id}') == stamp &&
          forceId != record.id &&
          !record.id.startsWith('artwork:')) {
        continue;
      }
      final data = record.deleted
          ? null
          : (_decoded[stamp] ?? await _vault.open(record));
      final entry = data == null ? null : _ProfileEntry.fromJson(data);
      if (entry != null) _validateEntry(entry);
      final old = baseline[record.id] as Map?;
      final now = current[record.id];
      final fingerprint = _fingerprint(now);
      final remoteFingerprint = _fingerprint(entry);
      final descriptor =
          entry?.descriptor ?? (old?['descriptor'] as Map?) ?? now?.descriptor;
      if (descriptor?['type'] == 'binding' &&
          _localMedia.contains(descriptor?['key'])) {
        final key = descriptor!['key'] as String;
        store.setLocal(_remoteMediaKey, (_remoteMedia..add(key)).toList());
        store.setLocal(
          AppStore.catalogMediaKey,
          (store.local(AppStore.catalogMediaKey) as List? ?? [])
              .where((id) => id != key)
              .toList(),
        );
        // A local association is a device override, not a deletion of the
        // shared binding, including when its ciphertext/version has changed.
        baseline[record.id] = {
          'fingerprint': remoteFingerprint,
          'descriptor': descriptor,
        };
        store.setLocal(_baselineKey, baseline);
        store.setLocal('syncProfile:applied:${record.id}', stamp);
        continue;
      }
      final missingBinding =
          now == null &&
          descriptor?['type'] == 'binding' &&
          store.get('media', descriptor!['key'] as String)?.deleted != true;
      if (forceId != record.id &&
          !missingBinding &&
          fingerprint != old?['fingerprint'] &&
          fingerprint != remoteFingerprint) {
        final editTime = _entryModified(now?.descriptor ?? descriptor);
        final local = SyncRecord(
          kind: 'vault',
          id: record.id,
          data: const {},
          modifiedAt: editTime ?? DateTime.now().toUtc().toIso8601String(),
          deviceId: store.deviceId,
          deleted: now == null,
        );
        // A changed setting or binding may have been edited before an offline
        // device reconnects. Compare the edit itself, not this sync's start time.
        if (remoteFingerprint == old?['fingerprint'] ||
            newerLocalRecord(local, record)) {
          store.save(
            'vault',
            record.id,
            now == null ? {} : await _vault.seal(record.id, now.payload),
            deleted: now == null,
            modifiedAt: local.modifiedAt,
          );
          baseline[record.id] = {
            'fingerprint': fingerprint,
            'descriptor': now?.descriptor ?? old?['descriptor'],
          };
          continue;
        }
      }
      if (descriptor != null) {
        await _applyEntry(
          _ProfileEntry(descriptor['type'], descriptor['key'], entry?.value),
          deleted: record.deleted,
        );
      }
      for (final key in _entryKeys(descriptor)) {
        store.markLocalModified(key, at: record.modifiedAt);
      }
      baseline[record.id] = {
        'fingerprint': remoteFingerprint,
        'descriptor': descriptor,
      };
      // Commit after credential storage succeeds; failures remain retriable even
      // though the download cursor has advanced.
      store.setLocal(_baselineKey, baseline);
      store.setLocal('syncProfile:applied:${record.id}', stamp);
    }
    store.setLocal(_baselineKey, baseline);
    _applySourceOrder();
    _removeDeletedBindings();
  }

  Future<void> _applyEntry(_ProfileEntry entry, {required bool deleted}) async {
    final key = entry.key, value = entry.value;
    switch (entry.type) {
      case 'setting':
        final settings = Map<String, dynamic>.from(
          store.local('settings') ?? {},
        );
        if (deleted) {
          settings.remove(key);
        } else {
          settings[key] = value;
        }
        store.setLocal('settings', settings);
      case 'secret':
        if (deleted) {
          await secrets.delete(key: key);
        } else {
          AppLog.instance.rememberSecret(value as String);
          await secrets.write(key: key, value: value);
        }
      case 'source':
        if (deleted) {
          await secrets.delete(key: 'source:$key');
        } else {
          AppLog.instance.rememberSecret(value['password']);
          await secrets.write(key: 'source:$key', value: value['password']);
        }
        final sources = (store.local('sources') as List? ?? [])
            .whereType<Map>()
            .toList();
        final index = sources.indexWhere((source) => source['id'] == key);
        if (deleted) {
          sources.removeWhere((source) => source['id'] == key);
        } else if (index < 0) {
          sources.add(
            Map<String, dynamic>.from(value['configuration'])
              ..remove('password'),
          );
        } else {
          sources[index] = Map<String, dynamic>.from(value['configuration'])
            ..remove('password');
        }
        store.setLocal('sources', sources);
      case 'external':
        if (deleted) {
          store.removeLocal('externalSource:$key');
        } else {
          store.setLocal('externalSource:$key', value);
        }
      case 'binding':
        // A device can explicitly associate an existing record with a local
        // file. Such a location is never replaced by another device's path.
        if (_localMedia.contains(key) ||
            (store.local('location:$key') as Map?)?['source'] == 'local') {
          final ids = _remoteMedia..add(key);
          store.setLocal(_remoteMediaKey, ids.toList());
          final catalog = (store.local(AppStore.catalogMediaKey) as List? ?? [])
              .where((id) => id != key)
              .toList();
          store.setLocal(AppStore.catalogMediaKey, catalog);
          return;
        }
        if (deleted) {
          _removeBinding(key);
        } else {
          store.setLocal('location:$key', value['location']);
          final ids = _remoteMedia..add(key);
          store.setLocal(_remoteMediaKey, ids.toList());
          if (value['episodeTitle'] == null) {
            store.removeLocal('episodeTitle:$key');
          } else {
            store.setLocal('episodeTitle:$key', value['episodeTitle']);
          }
          store.setLocal(
            'manualMetadata:$key',
            value['manualMetadata'] == true,
          );
          for (final kind in ['mediaMetadata', 'technical']) {
            if (value.containsKey(kind)) {
              store.setLocal('$kind:$key', value[kind]);
            } else {
              final saved = store.local('$kind:$key');
              if (saved != null &&
                  !_validFacts(kind, saved, value['location'])) {
                store.removeLocal('$kind:$key');
              }
            }
          }
        }
      case 'artwork':
        await artwork?.apply(key, value, deleted: deleted);
      case 'favorite':
        final favorites = SourceFavorites(
          store,
        ).all.where((f) => f.key != key).map((f) => f.toJson()).toList();
        if (!deleted) favorites.add(Map<String, dynamic>.from(value));
        store.setLocal(SourceFavorites.storageKey, favorites);
      case 'local':
        if (deleted) {
          store.removeLocal(key);
        } else {
          store.setLocal(
            key,
            key.startsWith('directory-preview:')
                ? {
                    ...value as Map,
                    'context': _directoryContext(value['sourceId']),
                  }
                : value,
          );
        }
    }
  }

  String _directoryContext(String sourceId) {
    final settings = Map<String, dynamic>.from(store.local('settings') ?? {});
    final source = (store.local('sources') as List? ?? [])
        .whereType<Map>()
        .where((source) => source['id'] == sourceId)
        .firstOrNull;
    final aiContext = jsonEncode([
      AppPreferences(settings).aiMetadataEnabled,
      settings['aiSubtitleOrigin'],
      settings['aiSubtitleModel'],
      store.local('metadataCredentialsRevision'),
    ]);
    return hash.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'catalog-v5',
              source,
              settings['metadataStrategy'] ?? 'conservative',
              aiContext,
            ]),
          ),
        )
        .toString();
  }

  void _applySourceOrder() {
    final order = (store.local('sourceOrder') as List? ?? []).cast<String>();
    final sources = (store.local('sources') as List? ?? [])
        .whereType<Map>()
        .toList();
    final ordered = [
      for (final id in order) ...sources.where((s) => s['id'] == id),
      ...sources.where((s) => !order.contains(s['id'])),
    ];
    store.setLocal('sources', ordered);
  }

  void _removeBinding(String id) {
    final location = store.local('location:$id');
    if (location is! Map || location['source'] == 'local') return;
    final excluded = hash.sha256.convert(
      utf8.encode(jsonEncode([location['source'], location['path']])),
    );
    store.setLocal('automatic-import-excluded:$excluded', true);
    store.removeLocal('location:$id');
    store.removeLocal('episodeTitle:$id');
    store.removeLocal('manualMetadata:$id');
    store.removeLocal('mediaMetadata:$id');
    store.removeLocal('technical:$id');
  }

  void _removeDeletedBindings() {
    for (final record
        in store.records('media').where((r) => r.deleted && !r.dirty)) {
      _removeBinding(record.id);
    }
  }

  void rememberLocalMedia(String id) => rememberMediaBindings(localIds: [id]);

  void rememberRemoteMedia(String id) => rememberMediaBindings(remoteIds: [id]);

  /// A scan persists each complete binding set once per committed batch.
  void rememberMediaBindings({
    Iterable<String> localIds = const [],
    Iterable<String> remoteIds = const [],
  }) {
    _readMediaBindings();
    final local = {..._knownLocalMedia}, remote = {..._knownRemoteMedia};
    var localChanged = false, remoteChanged = false;
    for (final id in localIds) {
      localChanged = local.add(id) || localChanged;
    }
    for (final id in remoteIds) {
      localChanged = local.remove(id) || localChanged;
      remoteChanged = remote.add(id) || remoteChanged;
    }
    if (localChanged) store.setLocal(_localMediaKey, local.toList());
    if (remoteChanged) store.setLocal(_remoteMediaKey, remote.toList());
  }

  String conflictLabel(SyncRecord record) {
    final descriptor = (_baseline[record.id] as Map?)?['descriptor'] as Map?;
    final key = descriptor?['key'] as String? ?? '';
    final category = switch (record.id.split(':').first) {
      'setting' => '应用设置',
      'secret' => 'API Key / 连接凭证',
      'source' || 'external' => '远程来源及凭证',
      'binding' => '视频位置与匹配信息',
      'artwork' => '海报与视频封面',
      'favorite' => '收藏文件夹',
      _ => _portableKey(key) ? '作品资料与翻译' : '显示与排序设置',
    };
    final label = switch (record.id.split(':').first) {
      'source' =>
        ((store.local('sources') as List? ?? [])
                    .whereType<Map>()
                    .where((s) => s['id'] == key)
                    .firstOrNull?['label'] ??
                '')
            .toString(),
      'binding' => (store.get('media', key)?.data['title'] ?? '').toString(),
      'favorite' =>
        SourceFavorites(
              store,
            ).all.where((f) => f.key == key).firstOrNull?.name ??
            '',
      'secret' =>
        {
              'danmuToken': '弹幕',
              'tmdb.apiKey': 'TMDB',
              'aiSubtitleToken': 'AI 翻译',
            }[key] ??
            '',
      'setting' => key,
      _ => '',
    };
    return label.isEmpty ? category : '$category · $label';
  }
}
