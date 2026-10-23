import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class SyncRecord {
  final String id, kind;
  final String modifiedAt, deviceId, deviceName;
  final int version, revision;
  final bool deleted, dirty;
  final Map<String, dynamic> data;
  const SyncRecord({
    required this.id,
    required this.kind,
    required this.data,
    this.modifiedAt = '',
    this.deviceId = '',
    this.deviceName = '',
    this.version = 0,
    this.revision = 0,
    this.deleted = false,
    this.dirty = false,
  });
  factory SyncRecord.fromJson(Map<String, dynamic> j) => SyncRecord(
    id: j['id'],
    kind: j['kind'],
    data: Map<String, dynamic>.from(j['data']),
    version: j['version'],
    modifiedAt: j['modifiedAt'] as String? ?? '',
    deviceId: j['deviceId'] as String? ?? '',
    deviceName: j['deviceName'] as String? ?? '',
    deleted: j['deleted'] == true,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'version': version,
    'deleted': deleted,
    'data': data,
    if (modifiedAt.isNotEmpty) 'modifiedAt': modifiedAt,
    if (deviceId.isNotEmpty) 'deviceId': deviceId,
    if (deviceName.isNotEmpty) 'deviceName': deviceName,
  };
}

/// Compare edit time first, then use stable tie breakers on every device.
/// Older clients without clocks defer to a dated edit or the server version.
bool newerLocalRecord(SyncRecord local, SyncRecord remote) {
  DateTime? time(SyncRecord record) => DateTime.tryParse(
    record.modifiedAt.isNotEmpty
        ? record.modifiedAt
        : (record.data['updatedAt'] as String? ?? ''),
  );
  final own = time(local), other = time(remote);
  if (own == null) return false;
  if (other == null) return true;
  final order = own.compareTo(other);
  if (order != 0) return order > 0;
  if (local.deleted != remote.deleted) return local.deleted;
  return local.deviceId.compareTo(remote.deviceId) > 0;
}

class AppStore {
  final String path;
  final Database db;
  final _statements = <String, PreparedStatement>{};
  final _localKeyRevisions = <String, int>{};
  Map<String, Map<String, dynamic>>? _locationIndex;
  final Map<String, String> _locationKeys = {};
  final Map<String, int> _recordRevisions = {};
  int _revision = 0, _unknownRevision = 0;
  int _localRevision = 0, _locationRevision = 0;
  int _knownChanges = 0;
  late int _dataVersion;
  AppStore(this.path) : db = sqlite3.open(path) {
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      '''CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 0,revision INTEGER NOT NULL DEFAULT 0,dirty INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,data TEXT NOT NULL,PRIMARY KEY(kind,id));
      CREATE TABLE IF NOT EXISTS local(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS cache(key TEXT PRIMARY KEY,created INTEGER NOT NULL,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS conflicts(kind TEXT NOT NULL,id TEXT NOT NULL,remote TEXT NOT NULL,PRIMARY KEY(kind,id));''',
    );
    final columns = db
        .select('PRAGMA table_info(records)')
        .map((r) => r['name'])
        .toSet();
    for (final name in ['modified_at', 'device_id', 'device_name']) {
      if (!columns.contains(name)) {
        db.execute(
          "ALTER TABLE records ADD COLUMN $name TEXT NOT NULL DEFAULT ''",
        );
      }
    }
    db.execute('PRAGMA user_version=2');
    _dataVersion = db.select('PRAGMA data_version').first.values.first as int;
    if (local('syncDevice:id') == null) {
      setLocal('syncDevice:id', const Uuid().v4());
    }
    if (local('syncDevice:name') == null) {
      final platform = switch (Platform.operatingSystem) {
        'macos' => 'macOS',
        'windows' => 'Windows',
        'ios' => 'iOS',
        'android' => 'Android',
        _ => 'Linux',
      };
      setLocal('syncDevice:name', '${Platform.localHostname} · $platform');
    }
  }

  PreparedStatement _statement(String sql) =>
      _statements.putIfAbsent(sql, () => db.prepare(sql));

  ResultSet _select(String sql, [List<Object?> parameters = const []]) =>
      _statement(sql).select(parameters);

  void _execute(String sql, [List<Object?> parameters = const []]) =>
      _statement(sql).execute(parameters);

  /// Track only requested keys, so preview/cache writes cannot invalidate
  /// settings or force large media-binding lists to be decoded again.
  int localKeyRevision(String key) {
    _checkChanges();
    final own = _localKeyRevisions.putIfAbsent(key, () => 0);
    return own > _unknownRevision ? own : _unknownRevision;
  }

  /// Cheap invalidation for view snapshots. Known writes only invalidate their
  /// own kind; SQL issued directly and commits from another database connection
  /// invalidate every snapshot. No record JSON is read to check freshness.
  int recordsRevision(String kind) {
    _checkChanges();
    final own = _recordRevisions[kind] ?? 0;
    return own > _unknownRevision ? own : _unknownRevision;
  }

  int get localRevision {
    _checkChanges();
    return _localRevision > _unknownRevision
        ? _localRevision
        : _unknownRevision;
  }

  int get locationRevision {
    _checkChanges();
    return _locationRevision > _unknownRevision
        ? _locationRevision
        : _unknownRevision;
  }

  void _checkChanges() {
    final row = _select(
      'SELECT total_changes() AS changes, data_version FROM pragma_data_version',
    ).first;
    final changes = row['changes'] as int;
    final version = row['data_version'] as int;
    if (changes != _knownChanges || version != _dataVersion) {
      _unknownRevision = ++_revision;
      _locationIndex = null;
      _locationKeys.clear();
    }
    _knownChanges = changes;
    _dataVersion = version;
  }

  void _written({String? kind, String? localKey}) {
    final count = db.updatedRows;
    _knownChanges += count;
    if (count == 0) return;
    final revision = ++_revision;
    if (kind != null) _recordRevisions[kind] = revision;
    if (localKey != null) {
      _localRevision = revision;
      if (_localKeyRevisions.containsKey(localKey)) {
        _localKeyRevisions[localKey] = revision;
      }
      if (localKey.startsWith('location:')) _locationRevision = revision;
    }
  }

  SyncRecord _row(Row r) => SyncRecord(
    id: r['id'],
    kind: r['kind'],
    version: r['version'],
    revision: r['revision'],
    modifiedAt: r['modified_at'],
    deviceId: r['device_id'],
    deviceName: r['device_name'],
    dirty: r['dirty'] == 1,
    deleted: r['deleted'] == 1,
    data: Map<String, dynamic>.from(jsonDecode(r['data'])),
  );
  SyncRecord? get(String kind, String id) {
    final r = _select('SELECT * FROM records WHERE kind=? AND id=?', [
      kind,
      id,
    ]);
    return r.isEmpty ? null : _row(r.first);
  }

  List<SyncRecord> all(String kind) => _select(
    'SELECT * FROM records WHERE kind=? AND deleted=0 ORDER BY id',
    [kind],
  )
      .map(_row)
      .where((record) => record.data['transient'] != true)
      .toList();
  List<SyncRecord> records(String kind) => _select(
    'SELECT * FROM records WHERE kind=? ORDER BY id',
    [kind],
  )
      .map(_row)
      .toList();
  Map<String, dynamic> localEntries(String prefix) {
    // substr(key, ...) forces a scan of the complete local/cache table. A
    // binary range uses its primary-key index and treats SQL wildcards literally.
    final points = prefix.runes.toList();
    while (points.isNotEmpty && points.last == 0x10ffff) {
      points.removeLast();
    }
    String? upper;
    if (points.isNotEmpty) {
      points[points.length - 1]++;
      if (points.last == 0xd800) points[points.length - 1] = 0xe000;
      upper = String.fromCharCodes(points);
    }
    final rows = upper == null
        ? _select('SELECT key,value FROM local WHERE key>=?', [prefix])
        : _select('SELECT key,value FROM local WHERE key>=? AND key<?', [
            prefix,
            upper,
          ]);
    return {
      for (final row in rows)
        row['key'] as String: jsonDecode(row['value'] as String),
    };
  }

  List<SyncRecord> get pending => pendingRecords();

  SyncRecord? pendingRecord(String kind, String id) {
    final rows = _select(
      'SELECT r.* FROM records r LEFT JOIN conflicts c ON c.kind=r.kind AND c.id=r.id WHERE r.kind=? AND r.id=? AND r.dirty=1 AND c.id IS NULL',
      [kind, id],
    );
    final record = rows.isEmpty ? null : _row(rows.single);
    return record != null && shouldSyncRecord(record) ? record : null;
  }

  List<SyncRecord> pendingRecords({bool includeVault = true}) => _select(
        'SELECT r.* FROM records r LEFT JOIN conflicts c ON c.kind=r.kind AND c.id=r.id WHERE r.dirty=1 AND c.id IS NULL${includeVault ? '' : " AND r.kind!='vault'"} ORDER BY r.kind,r.id',
      )
      .map(_row)
      .where(shouldSyncRecord)
      .toList();

  String get deviceId => local('syncDevice:id') as String;
  String get deviceName => local('syncDevice:name') as String;

  bool isPrivateMedia(String id) {
    final data = get('media', id)?.data;
    return data?['localOnly'] == true ||
        data?['transient'] == true ||
        (local('location:$id') as Map?)?['source'] == 'local' ||
        (local('syncProfile:localMedia') as List? ?? []).contains(id);
  }

  /// Applies even when lightweight synchronization has no profile adapter.
  bool shouldSyncRecord(SyncRecord record) {
    if (record.data['localOnly'] == true || record.data['transient'] == true) {
      return false;
    }
    var id = record.id;
    if (record.kind == 'progress' && id.contains(':')) {
      id = id.substring(0, id.lastIndexOf(':'));
    }
    if (['media', 'match', 'progress'].contains(record.kind)) {
      return !isPrivateMedia(id);
    }
    if (record.kind == 'watched') return !isPrivateMedia(id);
    return true;
  }

  void save(
    String kind,
    String id,
    Map<String, dynamic> data, {
    bool deleted = false,
    String? modifiedAt,
    String? deviceId,
    String? deviceName,
  }) {
    final previous = get(kind, id);
    if (kind == 'media' && (data['localOnly'] == true || isPrivateMedia(id))) {
      data = {...data, 'localOnly': true};
    }
    final encoded = jsonEncode(data);
    if (previous != null &&
        previous.deleted == deleted &&
        jsonEncode(previous.data) == encoded) {
      return;
    }
    var timestamp =
        modifiedAt ??
        (kind == 'progress' && !deleted ? data['updatedAt'] as String? : null);
    if (timestamp == null || DateTime.tryParse(timestamp) == null) {
      var now = DateTime.now().toUtc();
      final last = DateTime.tryParse(previous?.modifiedAt ?? '');
      if (last != null && !now.isAfter(last)) {
        now = last.add(const Duration(microseconds: 1));
      }
      timestamp = now.toIso8601String();
    }
    _execute(
      '''INSERT INTO records(kind,id,data,dirty,deleted,revision,modified_at,device_id,device_name) VALUES(?,?,?,1,?,1,?,?,?)
      ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data,dirty=1,deleted=excluded.deleted,revision=records.revision+1,modified_at=excluded.modified_at,device_id=excluded.device_id,device_name=excluded.device_name''',
      [
        kind,
        id,
        encoded,
        deleted ? 1 : 0,
        timestamp,
        deviceId ?? this.deviceId,
        deviceName ?? this.deviceName,
      ],
    );
    _written(kind: kind);
  }

  void acknowledge(SyncRecord sent, SyncRecord accepted) {
    _execute(
      'UPDATE records SET version=?,dirty=CASE WHEN revision=? THEN 0 ELSE 1 END WHERE kind=? AND id=?',
      [accepted.version, sent.revision, sent.kind, sent.id],
    );
    _written(kind: sent.kind);
  }

  void applyRemote(SyncRecord r) {
    final own = get(r.kind, r.id);
    if (own != null && own.version >= r.version) return;
    if (own?.dirty == true) {
      conflict(r);
      return;
    }
    _execute(
      '''INSERT INTO records(kind,id,version,deleted,data,modified_at,device_id,device_name) VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(kind,id) DO UPDATE SET version=excluded.version,deleted=excluded.deleted,data=excluded.data,dirty=0,revision=records.revision+1,modified_at=excluded.modified_at,device_id=excluded.device_id,device_name=excluded.device_name''',
      [
        r.kind,
        r.id,
        r.version,
        r.deleted ? 1 : 0,
        jsonEncode(r.data),
        r.modifiedAt,
        r.deviceId,
        r.deviceName,
      ],
    );
    _written(kind: r.kind);
  }

  void conflict(SyncRecord r) {
    _execute(
      'INSERT OR REPLACE INTO conflicts(kind,id,remote) VALUES(?,?,?)',
      [r.kind, r.id, jsonEncode(r.toJson())],
    );
    _written();
  }

  List<SyncRecord> get conflicts => _select('SELECT remote FROM conflicts')
      .map((r) => SyncRecord.fromJson(jsonDecode(r['remote'])))
      .toList();
  void resolve(SyncRecord remote, {required bool keepLocal}) {
    transaction(() {
      if (keepLocal) {
        _execute(
          'UPDATE records SET version=?,dirty=1,revision=revision+1 WHERE kind=? AND id=?',
          [remote.version, remote.kind, remote.id],
        );
        _written(kind: remote.kind);
      } else {
        _execute('DELETE FROM records WHERE kind=? AND id=?', [
          remote.kind,
          remote.id,
        ]);
        _written(kind: remote.kind);
        applyRemote(remote);
      }
      _execute('DELETE FROM conflicts WHERE kind=? AND id=?', [
        remote.kind,
        remote.id,
      ]);
      _written();
    });
  }

  dynamic local(String key) {
    final r = _select('SELECT value FROM local WHERE key=?', [key]);
    return r.isEmpty ? null : jsonDecode(r.first['value']);
  }

  void markLocalModified(String key, {String? at}) {
    _execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)', [
      'syncModified:$key',
      jsonEncode(at ?? DateTime.now().toUtc().toIso8601String()),
    ]);
    _written(localKey: 'syncModified:$key');
  }

  String? localModified(String key) => local('syncModified:$key') as String?;

  void _markLocalChanges(String key, dynamic before, dynamic after) {
    if (key.startsWith('sync') ||
        key == 'lastSync' ||
        jsonEncode(before) == jsonEncode(after)) {
      return;
    }
    if (key == 'settings') {
      final old = before is Map ? before : const {},
          next = after is Map ? after : const {};
      for (final field in {...old.keys, ...next.keys}) {
        if (jsonEncode(old[field]) != jsonEncode(next[field])) {
          markLocalModified('setting:$field');
        }
      }
    } else if (key == 'sources') {
      final old = {
        for (final item in (before as List? ?? []).whereType<Map>())
          item['id']: item,
      };
      final next = {
        for (final item in (after as List? ?? []).whereType<Map>())
          item['id']: item,
      };
      for (final id in {...old.keys, ...next.keys}) {
        if (jsonEncode(old[id]) != jsonEncode(next[id])) {
          markLocalModified('source:$id');
        }
      }
    } else if (key == 'sourceFavorites') {
      Map<String, Map> favorites(dynamic value) => {
        for (final item in (value as List? ?? []).whereType<Map>())
          '${item['sourceId']}\u0000${p.posix.normalize('${item['path'] ?? ''}'.replaceAll('\\', '/')).replaceFirst(RegExp(r'^\.$'), '')}':
              item,
      };
      final old = favorites(before), next = favorites(after);
      for (final id in {...old.keys, ...next.keys}) {
        if (jsonEncode(old[id]) != jsonEncode(next[id])) {
          markLocalModified('favorite:$id');
        }
      }
    }
    markLocalModified(key);
  }

  void setLocal(String key, dynamic value) {
    final encoded = jsonEncode(value);
    final previous = _select('SELECT value FROM local WHERE key=?', [key]);
    if (previous.isNotEmpty && previous.first['value'] == encoded) return;
    if (!key.startsWith('sync') && key != 'lastSync') {
      _markLocalChanges(
        key,
        previous.isEmpty ? null : jsonDecode(previous.first['value']),
        value,
      );
    }
    _execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)', [
      key,
      encoded,
    ]);
    _written(localKey: key);
    if (key.startsWith('location:') && _locationIndex != null) {
      _indexLocation(key.substring('location:'.length), value);
    }
  }

  void removeLocal(String key) {
    if (!key.startsWith('sync')) _markLocalChanges(key, local(key), null);
    _execute('DELETE FROM local WHERE key=?', [key]);
    _written(localKey: key);
    if (key.startsWith('location:') && _locationIndex != null) {
      _indexLocation(key.substring('location:'.length), null);
    }
  }

  void _indexLocation(String id, dynamic value) {
    final previous = _locationKeys.remove(id);
    if (previous != null && _locationIndex?[previous]?['id'] == id) {
      _locationIndex?.remove(previous);
      if (value is! Map ||
          '${value['source']}\u0000${value['path']}' != previous) {
        final fallback = _locationKeys.entries
            .where((entry) => entry.value == previous)
            .lastOrNull;
        if (fallback != null) {
          final saved = local('location:${fallback.key}');
          if (saved is Map) {
            _locationIndex?[previous] = Map<String, dynamic>.from(saved);
          }
        }
      }
    }
    if (value is Map && value['source'] is String && value['path'] is String) {
      final key = '${value['source']}\u0000${value['path']}';
      _locationKeys[id] = key;
      _locationIndex?[key] = Map<String, dynamic>.from(value);
    }
  }

  Map<String, dynamic>? locationFor(String sourceId, String path) {
    if (_locationIndex == null) {
      _locationIndex = {};
      _locationKeys.clear();
      for (final location in locations) {
        if (location['id'] is String) _indexLocation(location['id'], location);
      }
    }
    final value = _locationIndex!['$sourceId\u0000$path'];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  List<Map<String, dynamic>> get locations => _select(
        "SELECT value FROM local WHERE key>='location:' AND key<'location;' ORDER BY rowid",
      )
      .map((r) => Map<String, dynamic>.from(jsonDecode(r['value'])))
      .toList();
  dynamic cached(String key, {DateTime? now}) {
    final text = cachedJson(key);
    if (text == null) return null;
    final value = jsonDecode(text);
    // Empty replies may be temporary; successful data has no time expiry.
    return (value is List && value.isEmpty) || (value is Map && value.isEmpty)
        ? null
        : value;
  }

  /// Encoded access lets large payloads be processed outside the UI isolate.
  String? cachedJson(String key) {
    final rows = _select('SELECT value FROM cache WHERE key=?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void cache(String key, dynamic value, {DateTime? now}) =>
      cacheJson(key, jsonEncode(value), now: now);

  void cacheJson(String key, String encoded, {DateTime? now}) {
    if (cachedJson(key) == encoded) return;
    _execute(
      'INSERT OR REPLACE INTO cache(key,created,value) VALUES(?,?,?)',
      [key, (now ?? DateTime.now()).millisecondsSinceEpoch, encoded],
    );
    _written();
  }

  void transaction(void Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      action();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      // A caller may have cached uncommitted rows from inside the transaction.
      _unknownRevision = ++_revision;
      _locationIndex = null;
      _locationKeys.clear();
      rethrow;
    }
  }

  void dispose() {
    for (final statement in _statements.values) {
      statement.dispose();
    }
    _statements.clear();
    db.dispose();
  }
}
