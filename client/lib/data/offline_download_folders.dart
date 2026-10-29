part of 'offline_downloads.dart';

const _folderDirectoryLimit = 4096;
const _folderListingLimit = 20000;

String _canonicalDownloadPath(String path) {
  _checkedSegments(path);
  final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
  return normalized == '.' ? '' : normalized;
}

String _downloadBindingKey(String source, String path) => '$source\u0000$path';

String _downloadExclusionKey(String source, String path) =>
    'automatic-import-excluded:${sha256.convert(utf8.encode(jsonEncode([source, path])))}';

String _folderDownloadRelativePath(Map<String, dynamic> folder, String path) {
  final selected = folder['downloadRoot'] as String;
  final relative = p.posix.relative(
    path,
    from: selected.isEmpty ? '.' : selected,
  );
  _checkedSegments(relative);
  final segments = _checkedSegments(selected);
  var name =
      segments.lastOrNull ??
      p.posix.basename((folder['name'] as String).replaceAll('\\', '/'));
  if (name.isEmpty || name == '.' || name == '..' || name == '/') name = '下载';
  return p.posix.join(name, relative);
}

extension _OfflineFolderWork on _OfflineWorker {
  Future<void> _enqueueFolder(Map<String, dynamic> input) async {
    final source = input['sourceId'] as String;
    if (source.isEmpty || source == 'local') {
      throw const AppFailure('请选择远程文件夹下载。');
    }
    final path = _canonicalDownloadPath(input['remotePath'] as String);
    final id =
        'folder:${sha256.convert(utf8.encode(_downloadBindingKey(source, path)))}';
    await _ensureDatabase();
    final existing = rows[id];
    if (existing != null) {
      if (existing['status'] == 'failed') {
        existing['userPaused'] = false;
        existing['status'] = _readyStatus(existing);
        existing['error'] = '';
        _save(existing);
      }
      _pump();
      return;
    }
    if (rows.values.where((row) => row['status'] != 'completed').length >=
        _downloadCapacity) {
      throw const AppFailure('下载队列已满，请等待部分任务完成。');
    }
    final row = <String, dynamic>{
      'mediaId': id,
      'sourceId': source,
      'remotePath': path,
      'downloadRoot': path,
      'name': input['name'] as String? ?? '文件夹',
      'isDirectory': true,
      // An explicit folder selection may restore older library removals, but
      // must never undo deletions made while this task is queued or paused.
      'exclusionSequence': store?.importExclusionSequence ?? 0,
      'discoveredFiles': 0,
      'scannedFolders': 0,
      'received': 0,
      'total': 0,
      'localPath': '',
      'userPaused': false,
      'createdOrder': ++nextOrder,
      'status': active ? 'queued' : 'paused',
      'error': '',
    };
    db!.execute('BEGIN IMMEDIATE');
    try {
      _save(row, notify: false);
      db!.execute('INSERT INTO download_folder_paths(task,path) VALUES(?,?)', [
        id,
        path,
      ]);
      db!.execute('COMMIT');
    } catch (_) {
      db!.execute('ROLLBACK');
      rethrow;
    }
    rows[id] = row;
    if (!closing) reply.send(['changed', row]);
    _pump();
  }

  void _deleteFolderState(String id) {
    db!.execute('DELETE FROM download_folder_paths WHERE task=?', [id]);
    db!.execute('DELETE FROM download_folder_files WHERE task=?', [id]);
  }

  void _validateFolderSource(Map<String, dynamic> row) {
    if (storePath == ':memory:') return;
    final library = store;
    if (library == null) throw const AppFailure('本机媒体库不可用，请重试。');
    final sourceId = row['sourceId'] as String;
    final current =
        (library.local('sources') as List? ?? const [])
            .whereType<Map>()
            .where((source) => source['id'] == sourceId)
            .firstOrNull ??
        library.local('externalSource:$sourceId') as Map?;
    if (current == null ||
        (row['identity'] != null &&
            _sourceIdentity(Map<String, dynamic>.from(current)) !=
                row['identity'])) {
      throw const AppFailure('来源已删除或地址已改变，请重新选择文件夹。');
    }
  }

  int _folderCount(String table, String id, {bool pending = false}) =>
      db!.select(
            'SELECT COUNT(*) AS count FROM $table WHERE task=?'
            '${pending ? ' AND scanned=0' : ''}',
            [id],
          ).first['count']
          as int;

  Future<void> _scanFolder(
    Map<String, dynamic> row,
    _DownloadAttempt attempt,
  ) async {
    final id = row['mediaId'] as String;
    var admitted = false;
    Object? failure;
    try {
      final config = await _configuration(row['sourceId'] as String, attempt);
      attempt.cancel.check();
      final identity = _sourceIdentity(config);
      if (row['identity'] != null && row['identity'] != identity) {
        throw const AppFailure('来源地址已改变，请删除旧扫描后重新选择文件夹。');
      }
      row['identity'] = identity;
      _validateFolderSource(row);
      _save(row);
      // Retrying a previously empty folder should discover videos added later.
      if (_folderCount('download_folder_files', id) == 0 &&
          _folderCount('download_folder_paths', id, pending: true) == 0) {
        _deleteFolderState(id);
        db!.execute(
          'INSERT INTO download_folder_paths(task,path) VALUES(?,?)',
          [id, row['remotePath']],
        );
        row['scannedFolders'] = 0;
      }
      final connection = connectSource(
        config,
        password: config['password'] as String? ?? '',
      );
      unawaited(
        connection.then<void>((source) {
          if (attempt.cancel.cancelled) {
            unawaited(source.close().catchError((Object _) {}));
          }
        }, onError: (Object _) {}),
      );
      final source = await _wait(connection, attempt);
      attempt.source = source;
      final clock = Stopwatch()..start();
      while (true) {
        attempt.cancel.check();
        _validateFolderSource(row);
        final pending = db!.select(
          'SELECT path FROM download_folder_paths '
          'WHERE task=? AND scanned=0 ORDER BY rowid LIMIT 1',
          [id],
        );
        if (pending.isEmpty) break;
        final directory = pending.first['path'] as String;
        final listing = await _wait(source.list(directory), attempt);
        _validateFolderSource(row);
        if (listing.length > _folderListingLimit) {
          throw const AppFailure('单个文件夹项目过多，请选择更小的子文件夹。');
        }
        // Incremental checkpoints keep the current directory pending until all
        // its children are persisted. Cancellation then safely re-enumerates it.
        for (var offset = 0; offset < listing.length; offset += 64) {
          attempt.cancel.check();
          _validateFolderSource(row);
          db!.execute('BEGIN IMMEDIATE');
          try {
            for (final entry in listing.skip(offset).take(64)) {
              final child = _canonicalDownloadPath(entry.path);
              final rawParent = p.posix.dirname(child);
              final parent = rawParent == '.' ? '' : rawParent;
              // Adapters use paths relative to their configured root. Reject
              // self/parent/sibling aliases even if a server includes them in DAV.
              if (child == directory || parent != directory || child.isEmpty) {
                continue;
              }
              if (_checkedSegments(child).length > 128) {
                throw const AppFailure('文件夹层级过深，请选择更小的子文件夹。');
              }
              if (entry.directory) {
                db!.execute(
                  'INSERT OR IGNORE INTO download_folder_paths(task,path) VALUES(?,?)',
                  [id, child],
                );
              } else if (isVideo(entry.name)) {
                final location = store?.locationFor(
                  row['sourceId'] as String,
                  child,
                );
                final record = location == null
                    ? null
                    : store?.get('media', location['id'] as String);
                db!.execute(
                  'INSERT OR IGNORE INTO download_folder_files(task,path,name,size,modified,expected_id,expected_revision,expected_deleted,expected_record_revision) '
                  'VALUES(?,?,?,?,?,?,?,?,?)',
                  [
                    id,
                    child,
                    entry.name,
                    entry.size,
                    entry.modified,
                    location?['id'],
                    location == null ? null : location['previewRevision'] ?? '',
                    record?.deleted == true ? 1 : 0,
                    record?.revision,
                  ],
                );
              }
            }
            if (_folderCount('download_folder_paths', id) >
                    _folderDirectoryLimit ||
                _folderCount('download_folder_files', id) > _downloadCapacity) {
              throw const AppFailure('文件夹最多包含 2000 个视频、4096 个目录，请选择更小的子文件夹。');
            }
            db!.execute('COMMIT');
          } catch (_) {
            db!.execute('ROLLBACK');
            rethrow;
          }
          row['discoveredFiles'] = _folderCount('download_folder_files', id);
          if (clock.elapsedMilliseconds >= 500) {
            if (!closing) reply.send(['changed', row]);
            clock.reset();
          }
          // This already runs in a background isolate. Yield only to its own
          // pause/cancel port between bounded database batches, never for UI work.
          await Future<void>.delayed(Duration.zero);
        }
        attempt.cancel.check();
        _validateFolderSource(row);
        db!.execute(
          'UPDATE download_folder_paths SET scanned=1 WHERE task=? AND path=?',
          [id, directory],
        );
        row['scannedFolders'] =
            _folderCount('download_folder_paths', id) -
            _folderCount('download_folder_paths', id, pending: true);
        row['discoveredFiles'] = _folderCount('download_folder_files', id);
        final notify = clock.elapsedMilliseconds >= 500;
        _save(row, notify: notify);
        if (notify) clock.reset();
        await Future<void>.delayed(Duration.zero);
      }
      attempt.cancel.check();
      _validateFolderSource(row);
      _admitFolder(row);
      admitted = true;
    } catch (error) {
      failure = error;
    } finally {
      final cancelled = attempt.cancel.cancelled || failure is Cancelled;
      attempt.stop();
      try {
        await attempt.source?.close();
      } catch (_) {}
      if (!admitted && !deleting.contains(id)) {
        row['status'] = cancelled ? _readyStatus(row) : 'failed';
        row['error'] = cancelled
            ? ''
            : _downloadError(failure ?? const AppFailure('读取文件夹失败，请重试。'));
        _save(row);
      }
    }
  }

  bool _folderFileIsCurrent(
    AppStore library,
    Map<String, dynamic> folder,
    Map<String, Object?> file,
  ) {
    final source = folder['sourceId'] as String;
    final path = file['path'] as String;
    final excluded = _downloadExclusionKey(source, path);
    var restoreRemoved = false;
    if (library.local(excluded) == true) {
      final revision = library.importExclusionRevision(excluded);
      restoreRemoved =
          revision != null &&
          revision <= (folder['exclusionSequence'] as int? ?? 0);
      if (!restoreRemoved) return false;
    }
    final expected = file['expected_id'] as String?;
    if (expected != null) {
      final record = library.get('media', expected);
      final location = library.local('location:$expected') as Map?;
      // Sync can deliver a location before its media record. A binding that
      // was already orphaned when discovered is still a downloadable file;
      // a record removed after discovery must retain its deletion protection.
      final recordIsCurrent = record == null
          ? file['expected_record_revision'] == null &&
                file['expected_deleted'] == 0
          : (!record.deleted ||
                (restoreRemoved &&
                    file['expected_deleted'] == 1 &&
                    record.revision == file['expected_record_revision']));
      return recordIsCurrent &&
          location?['source'] == source &&
          location?['path'] == path &&
          (location?['previewRevision'] ?? '') ==
              (file['expected_revision'] ?? '');
    }
    final location = library.locationFor(source, path);
    // A record may have been imported and then deleted while this scan paused.
    // Even direct tombstones without an exclusion must not be resurrected.
    // A newly synchronized orphan binding still has no deletion to preserve.
    return location == null ||
        library.get('media', location['id'])?.deleted != true;
  }

  void _admitFolder(Map<String, dynamic> folder) {
    final id = folder['mediaId'] as String,
        sourceId = folder['sourceId'] as String;
    final discovered = db!.select(
      'SELECT path,name,size,modified,expected_id,expected_revision,expected_deleted,expected_record_revision '
      'FROM download_folder_files WHERE task=? ORDER BY rowid',
      [id],
    );
    if (discovered.isEmpty) throw const AppFailure('文件夹中没有可下载的视频。');
    // Library guards and registration run under one write transaction, so a
    // paused scan cannot restore a subsequently deleted or rebound media item.
    // Metadata edits keep the current record and are not overwritten.
    final library = store ??= AppStore(':memory:');
    final admitted = <Map<String, dynamic>>[];
    var skipped = 0, bound = 0, added = 0, retried = 0, existingFiles = 0;
    db!.execute('BEGIN IMMEDIATE');
    try {
      library.transaction(() {
        _validateFolderSource(folder);
        final files = <SourceEntry>[];
        for (final file in discovered) {
          if (!_folderFileIsCurrent(library, folder, file)) {
            skipped++;
            continue;
          }
          final path = file['path'] as String;
          final excluded = _downloadExclusionKey(sourceId, path);
          // Clear only removals validated against this task's original cutoff,
          // under the same transaction as registration. A failed admission rolls
          // this back too; scanning/cancelling alone never changes exclusions.
          if (library.local(excluded) == true) library.removeLocal(excluded);
          files.add(
            SourceEntry(
              name: file['name'] as String,
              path: path,
              size: file['size'] as int,
              modified: file['modified'] as int,
            ),
          );
        }
        final existing = {
          for (final task in rows.values)
            if (task['isDirectory'] != true)
              _downloadBindingKey(
                task['sourceId'] as String,
                task['remotePath'] as String,
              ): task,
        };
        final additional = files
            .where(
              (file) => !existing.containsKey(
                _downloadBindingKey(sourceId, file.path),
              ),
            )
            .length;
        final pending = rows.values
            .where(
              (task) => task['mediaId'] != id && task['status'] != 'completed',
            )
            .length;
        if (pending + additional > _downloadCapacity) {
          throw const AppFailure('下载队列不足以容纳此文件夹，请等待任务完成后重试。');
        }
        final bindings = prepareOfflineMediaBindings(
          library,
          sourceId: sourceId,
          entries: files,
          inTransaction: true,
          restoreExcluded: false,
        );
        bound = bindings.length;
        for (final (media, location) in bindings) {
          final sameId = rows[media.id];
          if (sameId != null &&
              (sameId['isDirectory'] == true ||
                  sameId['sourceId'] != sourceId ||
                  sameId['remotePath'] != location['path'] ||
                  (sameId['bindingRevision'] ?? '') !=
                      (location['previewRevision'] ?? ''))) {
            throw const AppFailure('已有下载来自旧视频位置，请删除旧下载后重试。');
          }
          final old =
              existing[_downloadBindingKey(
                sourceId,
                location['path'] as String,
              )];
          if (old != null) {
            if (old['mediaId'] != media.id ||
                (old['bindingRevision'] ?? '') !=
                    (location['previewRevision'] ?? '')) {
              throw const AppFailure('已有下载来自旧视频位置，请删除旧下载后重试。');
            }
            if (old['status'] == 'failed' && old['userPaused'] != true) {
              // Reselecting a folder retries failed children just like selecting
              // those files individually. Publish copies only after commit so a
              // later binding conflict cannot leave rolled-back retries running.
              final retry = <String, dynamic>{
                ...old,
                'status': _readyStatus(old),
                'error': '',
              };
              _save(retry, notify: false);
              admitted.add(retry);
              retried++;
            } else {
              existingFiles++;
            }
            continue;
          }
          final row = <String, dynamic>{
            'mediaId': media.id,
            'sourceId': sourceId,
            'remotePath': location['path'],
            if (folder['downloadRoot'] is String) ...{
              'downloadRoot': folder['downloadRoot'],
              'downloadRelativePath': _folderDownloadRelativePath(
                folder,
                location['path'] as String,
              ),
            },
            'bindingRevision': location['previewRevision'] as String? ?? '',
            'name':
                media.data['fileName'] ?? media.data['title'] ?? 'video.mp4',
            'total': location['size'] ?? media.data['size'] ?? 0,
            'received': 0,
            'checkpointBytes': 0,
            'userPaused': false,
            'createdOrder': ++nextOrder,
            'localPath': '',
            'error': '',
            'status': active ? 'queued' : 'paused',
          };
          _save(row, notify: false);
          admitted.add(row);
          added++;
        }
        _deleteFolderState(id);
        db!.execute('DELETE FROM downloads WHERE id=?', [id]);
      });
      // If this final commit fails, registrations are harmlessly retained and
      // the durable scan retries them by their existing media IDs.
      db!.execute('COMMIT');
    } catch (_) {
      db!.execute('ROLLBACK');
      rethrow;
    }
    for (final row in admitted) {
      rows[row['mediaId'] as String] = row;
    }
    rows.remove(id);
    if (!closing) {
      // One bounded summary per successful scan, never filenames, URLs,
      // credentials or per-file/progress log traffic.
      reply.send([
        'admitted',
        id,
        admitted,
        {
          'folders': folder['scannedFolders'],
          'discovered': discovered.length,
          'bound': bound,
          'added': added,
          'retried': retried,
          'existing': existingFiles,
          'skipped': skipped,
        },
      ]);
    }
  }
}
