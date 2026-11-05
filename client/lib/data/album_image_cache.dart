import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/network.dart';

/// Worker-only disk accounting shared by independently owned album services.
/// An indexed LRU and transactional totals avoid directory walks and full sorts
/// on writes. JPEG + sidecar are one victim; originals cannot evict thumbnails.
class AlbumImageDiskCache {
  final String directory;
  final String? ownerId;
  final bool adaptiveOriginals;
  int? _ownerSession, _ownerRevision;
  List<String> _liveOwners = const [];
  int originalBytes, thumbnailBytes, metadataBytes;
  final int originalFiles, thumbnailFiles;
  final Future<void> Function(File, List<int>, CancelToken) publish;
  final void Function(List<String>) onEvicted;
  Database? _database;
  bool _closed = false;

  AlbumImageDiskCache({
    required this.directory,
    this.ownerId,
    this.adaptiveOriginals = false,
    required this.originalBytes,
    required this.originalFiles,
    required this.thumbnailBytes,
    required this.thumbnailFiles,
    this.metadataBytes = 16 * 1024 * 1024,
    required this.publish,
    required this.onEvicted,
  });

  (int, int) _budget(String tier) => switch (tier) {
    'thumbnail' => (thumbnailBytes, thumbnailFiles),
    'metadata' => (metadataBytes, 100000),
    _ => (originalBytes, originalFiles),
  };

  Future<T> _busy<T>(T Function() action, CancelToken cancel) async {
    var delay = 5;
    for (var attempt = 0; ; attempt++) {
      cancel.check();
      if (_closed) throw const Cancelled();
      try {
        return action();
      } on SqliteException catch (error) {
        if (error.resultCode != 5 && error.resultCode != 6 || attempt >= 100) {
          rethrow;
        }
        await Future.any([
          Future<void>.delayed(Duration(milliseconds: delay)),
          cancel.whenCancelled,
        ]);
        delay = math.min(100, delay * 2);
      }
    }
  }

  Future<Database> _open(CancelToken cancel) async {
    if (_database case final database?) return database;
    await Directory(directory).create(recursive: true);
    cancel.check();
    final database = sqlite3.open(p.join(directory, 'album-cache-v1.sqlite'));
    try {
      database.execute('PRAGMA busy_timeout=0');
      await _busy(() => database.execute('PRAGMA journal_mode=WAL'), cancel);
      await _busy(
        () => database.execute('''
        CREATE TABLE IF NOT EXISTS entries(
          path TEXT PRIMARY KEY, tier TEXT NOT NULL,
          bytes INTEGER NOT NULL, files INTEGER NOT NULL, used INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS entries_lru ON entries(tier, used, path);
        CREATE TABLE IF NOT EXISTS original_fallbacks(path TEXT PRIMARY KEY);
        CREATE TRIGGER IF NOT EXISTS original_fallback_delete
        AFTER DELETE ON entries BEGIN
          DELETE FROM original_fallbacks WHERE path=OLD.path;
        END;
        CREATE TABLE IF NOT EXISTS totals(
          tier TEXT PRIMARY KEY, bytes INTEGER NOT NULL, files INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value INTEGER);
        CREATE TABLE IF NOT EXISTS live_pins(
          owner TEXT NOT NULL, role TEXT NOT NULL, path TEXT NOT NULL,
          priority INTEGER NOT NULL, PRIMARY KEY(owner,role,path)
        );
        CREATE INDEX IF NOT EXISTS live_pins_path ON live_pins(path,priority);
        CREATE TABLE IF NOT EXISTS live_owners(owner TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS owner_generation(
          id INTEGER PRIMARY KEY CHECK(id=1), session INTEGER, revision INTEGER
        );
        CREATE TRIGGER IF NOT EXISTS entries_insert AFTER INSERT ON entries
        BEGIN
          INSERT INTO totals VALUES(NEW.tier, NEW.bytes, NEW.files)
          ON CONFLICT(tier) DO UPDATE SET
            bytes=bytes+NEW.bytes, files=files+NEW.files;
        END;
        CREATE TRIGGER IF NOT EXISTS entries_delete AFTER DELETE ON entries
        BEGIN
          UPDATE totals SET bytes=bytes-OLD.bytes, files=files-OLD.files
            WHERE tier=OLD.tier;
        END;
        CREATE TRIGGER IF NOT EXISTS entries_update AFTER UPDATE OF bytes,files ON entries
        BEGIN
          UPDATE totals SET bytes=bytes+NEW.bytes-OLD.bytes,
            files=files+NEW.files-OLD.files WHERE tier=OLD.tier;
        END;
      '''),
        cancel,
      );
      _database = database;
      await _transaction(cancel, () async {
        _applyOwners(database);
        if (database
            .select("SELECT value FROM state WHERE key='imported'")
            .isNotEmpty) {
          return;
        }
        // Import old files once. Each await is on this worker; cancellation
        // rolls back the index so another worker can finish the import later.
        for (final (name, tier) in [
          ('album-images-v2', 'original'),
          ('album-thumbnails-v1', 'thumbnail'),
          ('album-metadata-v3', 'metadata'),
        ]) {
          final folder = Directory(p.join(directory, name));
          if (!await folder.exists()) continue;
          await for (final entity in folder.list(followLinks: false)) {
            cancel.check();
            if (entity is! File ||
                !(tier == 'metadata'
                    ? entity.path.endsWith('.json')
                    : entity.path.endsWith('.jpg'))) {
              continue;
            }
            final stat = await entity.stat();
            if (stat.type != FileSystemEntityType.file) continue;
            var bytes = stat.size, files = 1;
            if (tier != 'metadata') {
              final sidecar = await File('${entity.path}.json').stat();
              if (sidecar.type == FileSystemEntityType.file) {
                bytes += sidecar.size;
                files++;
              }
            }
            _record(
              database,
              entity.path,
              tier,
              bytes,
              files,
              stat.modified.millisecondsSinceEpoch,
            );
          }
        }
        database.execute("INSERT INTO state VALUES('imported',1)");
      });
      return database;
    } catch (_) {
      _database = null;
      database.dispose();
      rethrow;
    }
  }

  Future<T> _transaction<T>(
    CancelToken cancel,
    Future<T> Function() action,
  ) async {
    final database = _database!;
    await _busy(() => database.execute('BEGIN IMMEDIATE'), cancel);
    try {
      final result = await action();
      cancel.check();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _record(
    Database database,
    String path,
    String tier,
    int bytes,
    int files,
    int used,
  ) {
    database.execute(
      '''INSERT INTO entries VALUES(?,?,?,?,?)
      ON CONFLICT(path) DO UPDATE SET bytes=excluded.bytes,
        files=excluded.files,used=excluded.used''',
      [path, tier, bytes, files, used],
    );
  }

  /// Main-isolate lifecycle generations reject late startup snapshots. Live
  /// windows are scoped to one application process; independent instances still
  /// share the hard byte cap but do not coordinate their active viewer windows.
  Future<void> updateOwners(
    int session,
    int revision,
    List<String> owners,
    CancelToken cancel,
  ) async {
    if (session == _ownerSession && revision < (_ownerRevision ?? -1)) {
      return;
    }
    _ownerSession = session;
    _ownerRevision = revision;
    _liveOwners = List.unmodifiable(owners);
    if (_database == null) return;
    await _transaction(cancel, () async => _applyOwners(_database!));
  }

  void _applyOwners(Database database) {
    final session = _ownerSession, revision = _ownerRevision;
    if (session == null || revision == null) return;
    final rows = database.select(
      'SELECT session,revision FROM owner_generation WHERE id=1',
    );
    if (rows.isNotEmpty) {
      final previous = rows.first;
      if (session == previous['session'] &&
          revision <= (previous['revision'] as int)) {
        return;
      }
    }
    database.execute('DELETE FROM live_owners');
    for (final owner in _liveOwners) {
      database.execute('INSERT INTO live_owners VALUES(?)', [owner]);
    }
    database.execute(
      'DELETE FROM live_pins WHERE owner NOT IN (SELECT owner FROM live_owners)',
    );
    database.execute('INSERT OR REPLACE INTO owner_generation VALUES(1,?,?)', [
      session,
      revision,
    ]);
  }

  Future<void> pinOriginals(
    String role,
    Map<String, int> paths,
    CancelToken cancel,
  ) async {
    if (ownerId == null) return;
    final database = await _open(cancel);
    await _transaction(cancel, () async {
      _applyOwners(database);
      if (database.select('SELECT owner FROM live_owners WHERE owner=?', [
        ownerId,
      ]).isEmpty) {
        return;
      }
      database.execute('DELETE FROM live_pins WHERE owner=? AND role=?', [
        ownerId,
        role,
      ]);
      for (final entry in paths.entries) {
        database.execute('INSERT INTO live_pins VALUES(?,?,?,?)', [
          ownerId,
          role,
          entry.key,
          entry.value,
        ]);
      }
    });
  }

  Future<void> releaseOriginals(String role) async {
    final database = _database;
    if (database == null || ownerId == null) return;
    await _transaction(CancelToken(), () async {
      database.execute('DELETE FROM live_pins WHERE owner=? AND role=?', [
        ownerId,
        role,
      ]);
    });
  }

  List<Row> _victims(
    Database database,
    String tier, {
    String? except,
    int? maximumPriority,
  }) {
    final exclusion = except == null ? '' : ' AND e.path<>?';
    final args = <Object?>[tier, ?except];
    if (tier != 'original') {
      return database.select(
        'SELECT e.path,e.bytes,e.files FROM entries e WHERE e.tier=?$exclusion ORDER BY e.used,e.path LIMIT 64',
        args,
      );
    }
    final unprotected = database.select(
      '''SELECT e.path,e.bytes,e.files FROM entries e
      WHERE e.tier=?$exclusion AND NOT EXISTS(SELECT 1 FROM live_pins p WHERE p.path=e.path)
      ORDER BY e.used,e.path LIMIT 64''',
      args,
    );
    if (unprotected.isNotEmpty) return unprotected;
    if (maximumPriority != null) {
      return database.select(
        '''SELECT e.path,e.bytes,e.files,
        (SELECT MAX(priority) FROM live_pins p WHERE p.path=e.path) AS importance
        FROM entries e WHERE e.tier=?$exclusion AND NOT EXISTS(
          SELECT 1 FROM live_pins p WHERE p.path=e.path AND p.priority>?)
        ORDER BY importance,e.used,e.path LIMIT 64''',
        [...args, maximumPriority],
      );
    }
    // Hard limits win; only the small live pin set needs a priority sort.
    return database.select(
      '''SELECT e.path,e.bytes,e.files,
      (SELECT MAX(priority) FROM live_pins p WHERE p.path=e.path) AS importance
      FROM entries e WHERE e.tier=?$exclusion ORDER BY importance,e.used,e.path LIMIT 64''',
      args,
    );
  }

  Future<bool> canAdmitOriginal(
    int bytes,
    int priority,
    CancelToken cancel,
  ) async {
    if (bytes > originalBytes) return false;
    final database = await _open(cancel);
    final totals = database.select(
      "SELECT bytes,files FROM totals WHERE tier='original'",
    );
    if (totals.isEmpty ||
        (totals.first['bytes'] as int) + bytes <= originalBytes &&
            (totals.first['files'] as int) + 2 <= originalFiles) {
      return true;
    }
    final protected = database
        .select(
          '''SELECT COALESCE(SUM(e.bytes),0) AS bytes,
      COALESCE(SUM(e.files),0) AS files FROM entries e WHERE e.tier='original'
      AND e.path IN (SELECT path FROM live_pins WHERE priority>?)''',
          [priority],
        )
        .single;
    return (protected['bytes'] as int) + bytes <= originalBytes &&
        (protected['files'] as int) + 2 <= originalFiles;
  }

  List<Row> _coldOriginals(Database database) {
    if (!adaptiveOriginals) return const [];
    final recent = database.select('''SELECT e.path,e.bytes FROM entries e
      WHERE e.tier='original' AND NOT EXISTS(SELECT 1 FROM live_pins p WHERE p.path=e.path)
      AND NOT EXISTS(SELECT 1 FROM original_fallbacks f WHERE f.path=e.path)
      ORDER BY e.used DESC,e.path DESC LIMIT 8''');
    final keep = <String>[];
    final budget = math.min(originalBytes ~/ 4, 128 * 1024 * 1024);
    var bytes = 0;
    for (final entry in recent) {
      if (bytes + (entry['bytes'] as int) > budget) break;
      keep.add(entry['path'] as String);
      bytes += entry['bytes'] as int;
    }
    final retained = keep.isEmpty
        ? ''
        : ' AND e.path NOT IN (${List.filled(keep.length, '?').join(',')})';
    return database.select('''SELECT e.path,e.bytes,e.files FROM entries e
      WHERE e.tier='original'$retained AND NOT EXISTS(SELECT 1 FROM live_pins p WHERE p.path=e.path)
      AND NOT EXISTS(SELECT 1 FROM original_fallbacks f WHERE f.path=e.path)
      ORDER BY e.used,e.path LIMIT 64''', keep);
  }

  /// A gallery source is still its only durable preview until a thumbnail is
  /// published. Keep this fact in the shared ledger, independently of the
  /// bounded derivative queue and service lifetime. Normal hard-budget LRU
  /// eviction still applies; only proactive original reclamation skips it.
  Future<void> retainOriginalUntilThumbnail(
    String path,
    CancelToken cancel,
  ) async {
    final database = await _open(cancel);
    await _transaction(cancel, () async {
      database.execute(
        '''INSERT OR IGNORE INTO original_fallbacks
        SELECT path FROM entries WHERE path=? AND tier='original' ''',
        [path],
      );
    });
  }

  void updateLimits(int thumbnails, int originals, {int? metadata}) {
    thumbnailBytes = thumbnails;
    originalBytes = originals;
    if (metadata != null) metadataBytes = metadata;
  }

  Future<void> touch(List<String> paths, [CancelToken? token]) async {
    if (_closed || paths.isEmpty) return;
    final cancel = token ?? CancelToken();
    final now = DateTime.now().millisecondsSinceEpoch;
    final database = await _open(cancel);
    // The UI already coalesces paths. Publish the bounded batch now: keeping
    // accesses only in this worker would make a peer's eviction order stale.
    await _transaction(cancel, () async {
      for (final path in paths.take(128)) {
        database.execute('UPDATE entries SET used=? WHERE path=?', [now, path]);
      }
    });
  }

  /// One maintenance turn deletes at most 64 pairs. The caller yields to source
  /// requests between turns and cancels directly on pause/scroll/disposal.
  Future<bool> maintain(CancelToken cancel) async {
    if (_database == null &&
        !await File(p.join(directory, 'album-cache-v1.sqlite')).exists()) {
      return false;
    }
    final database = await _open(cancel);
    final evicted = <String>[], deleted = <String>[];
    var more = false;
    try {
      await _transaction(cancel, () async {
        final cold = _coldOriginals(database);
        for (final victim in cold) {
          cancel.check();
          final path = victim['path'] as String;
          await _deletePair(path, 'original');
          deleted.add(path);
          evicted.add(path);
          database.execute('DELETE FROM entries WHERE path=?', [path]);
        }
        more = cold.length == 64;
        for (final tier in ['original', 'thumbnail', 'metadata']) {
          final (byteBudget, fileBudget) = _budget(tier);
          final totals = database.select(
            'SELECT bytes,files FROM totals WHERE tier=?',
            [tier],
          );
          if (totals.isEmpty) continue;
          var bytes = totals.first['bytes'] as int;
          var files = totals.first['files'] as int;
          if (bytes <= byteBudget && files <= fileBudget) continue;
          if (deleted.isNotEmpty) {
            more = true;
            break;
          }
          final targetBytes = byteBudget * 9 ~/ 10,
              targetFiles = fileBudget * 9 ~/ 10;
          final victims = _victims(database, tier);
          for (final victim in victims) {
            if (bytes <= targetBytes && files <= targetFiles) break;
            cancel.check();
            final path = victim['path'] as String;
            await _deletePair(path, tier);
            deleted.add(path);
            bytes -= victim['bytes'] as int;
            files -= victim['files'] as int;
            database.execute('DELETE FROM entries WHERE path=?', [path]);
            if (tier != 'metadata') evicted.add(path);
          }
          more = bytes > byteBudget || files > fileBudget;
        }
      });
    } catch (_) {
      await _reconcileDeleted(database, deleted);
      rethrow;
    } finally {
      if (evicted.isNotEmpty) onEvicted(evicted);
    }
    return more;
  }

  Future<void> _accountExisting(
    Database database,
    String path, {
    String? tier,
  }) async {
    final rows = database.select('SELECT tier,used FROM entries WHERE path=?', [
      path,
    ]);
    tier ??= rows.isEmpty
        ? path.endsWith('.json')
              ? 'metadata'
              : p.basename(p.dirname(path)) == 'album-thumbnails-v1'
              ? 'thumbnail'
              : 'original'
        : rows.first['tier'] as String;
    var bytes = 0, files = 0;
    for (final name in [path, if (tier != 'metadata') '$path.json']) {
      final stat = await File(name).stat();
      if (stat.type == FileSystemEntityType.file) {
        bytes += stat.size;
        files++;
      }
    }
    if (files == 0) {
      database.execute('DELETE FROM entries WHERE path=?', [path]);
    } else {
      // Another worker may have recreated the victim while rollback released
      // the lock. Preserve its new bytes and access time under this new lock.
      _record(
        database,
        path,
        tier,
        bytes,
        files,
        rows.isEmpty
            ? DateTime.now().millisecondsSinceEpoch
            : rows.first['used'] as int,
      );
    }
  }

  Future<void> _reconcileDeleted(
    Database database,
    List<String> deleted,
  ) async {
    if (deleted.isEmpty) return;
    try {
      await _transaction(CancelToken(), () async {
        for (final path in deleted) {
          await _accountExisting(database, path);
        }
      });
    } catch (_) {
      // Explicit external removal can also unlink this disposable index.
    }
  }

  Future<void> _deletePair(String path, String tier) async {
    for (final name in [path, if (tier != 'metadata') '$path.json']) {
      try {
        await File(name).delete();
      } on FileSystemException {
        if (await File(name).exists()) rethrow;
      }
    }
  }

  Future<bool> write(
    String tier,
    Map<File, List<int>> contents,
    CancelToken cancel, {
    int? admissionPriority,
    String? releasesOriginalFallback,
  }) async {
    if (contents.isEmpty) return true;
    final path = contents.keys.first.path;
    final bytes = contents.values.fold<int>(
      0,
      (total, value) => total + value.length,
    );
    final (byteBudget, fileBudget) = _budget(tier);
    if (bytes > byteBudget || contents.length > fileBudget) {
      throw const AppFailure('缩略图超出缓存预算。');
    }
    final database = await _open(cancel);
    while (true) {
      cancel.check();
      final evicted = <String>[], deleted = <String>[];
      var needsRoom = false, admitted = true;
      try {
        await _transaction(cancel, () async {
          // Keep replacement accounting intact when an earlier bounded prune
          // must commit before publication. Exclude this path from victims.
          final old = database.select(
            'SELECT bytes,files FROM entries WHERE path=?',
            [path],
          );
          final totals = database.select(
            'SELECT bytes,files FROM totals WHERE tier=?',
            [tier],
          );
          var usedBytes =
              (totals.isEmpty ? 0 : totals.first['bytes'] as int) -
              (old.isEmpty ? 0 : old.first['bytes'] as int);
          var usedFiles =
              (totals.isEmpty ? 0 : totals.first['files'] as int) -
              (old.isEmpty ? 0 : old.first['files'] as int);
          if (usedBytes + bytes > byteBudget ||
              usedFiles + contents.length > fileBudget) {
            if (tier == 'original' && admissionPriority != null) {
              final protected = database
                  .select(
                    '''SELECT COALESCE(SUM(e.bytes),0) AS bytes,
                COALESCE(SUM(e.files),0) AS files FROM entries e
                WHERE e.tier='original' AND e.path<>? AND e.path IN (
                  SELECT path FROM live_pins WHERE priority>?)''',
                    [path, admissionPriority],
                  )
                  .single;
              if ((protected['bytes'] as int) + bytes > byteBudget ||
                  (protected['files'] as int) + contents.length > fileBudget) {
                admitted = false;
                return;
              }
            }
            // The original tier already has a separate small recent tail.
            // Admission must not sacrifice another protected frame merely to
            // reach the generic cache's extra hysteresis headroom.
            final preserveWindow =
                tier == 'original' && admissionPriority != null;
            final targetBytes = math.max(
              0,
              (preserveWindow ? byteBudget : byteBudget * 9 ~/ 10) - bytes,
            );
            final targetFiles = math.max(
              0,
              (preserveWindow ? fileBudget : fileBudget * 9 ~/ 10) -
                  contents.length,
            );
            final victims = _victims(
              database,
              tier,
              except: path,
              maximumPriority: admissionPriority,
            );
            if (victims.isEmpty) {
              if (tier == 'original' && admissionPriority != null) {
                admitted = false;
                return;
              }
              throw const AppFailure('缩略图超出缓存预算。');
            }
            for (final victim in victims) {
              if (usedBytes <= targetBytes && usedFiles <= targetFiles) break;
              cancel.check();
              final victimPath = victim['path'] as String;
              await _deletePair(victimPath, tier);
              deleted.add(victimPath);
              usedBytes -= victim['bytes'] as int;
              usedFiles -= victim['files'] as int;
              database.execute('DELETE FROM entries WHERE path=?', [
                victimPath,
              ]);
              if (tier != 'metadata') evicted.add(victimPath);
            }
            if (usedBytes + bytes > byteBudget ||
                usedFiles + contents.length > fileBudget) {
              needsRoom = true;
              return;
            }
          }
          cancel.check();
          await contents.keys.first.parent.create(recursive: true);
          for (final entry in contents.entries) {
            await publish(entry.key, entry.value, cancel);
          }
          _record(
            database,
            path,
            tier,
            bytes,
            contents.length,
            DateTime.now().millisecondsSinceEpoch,
          );
          if (tier == 'thumbnail' && releasesOriginalFallback != null) {
            database.execute('DELETE FROM original_fallbacks WHERE path=?', [
              releasesOriginalFallback,
            ]);
          }
        });
      } catch (_) {
        try {
          await _transaction(CancelToken(), () async {
            for (final victim in deleted) {
              await _accountExisting(database, victim);
            }
            await _accountExisting(database, path, tier: tier);
          });
        } catch (_) {
          // Explicit external removal can also unlink this disposable index.
        }
        rethrow;
      } finally {
        if (evicted.isNotEmpty) onEvicted(evicted);
      }
      if (!needsRoom) return admitted;
      // A much lower user limit may require several batches. Never retain the
      // SQLite writer lock across all of them or ignore a queued pause/cancel.
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    if (_database != null && ownerId != null) {
      try {
        await _transaction(CancelToken(), () async {
          _database!.execute('DELETE FROM live_pins WHERE owner=?', [ownerId]);
        });
      } catch (_) {}
    }
    _closed = true;
    _database?.dispose();
    _database = null;
  }
}
