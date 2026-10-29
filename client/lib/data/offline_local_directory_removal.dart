part of 'offline_downloads.dart';

class _LocalRemovalTarget {
  final String id;
  final Map<String, dynamic>? binding, download;
  final String? file;
  final List<Object?>? fingerprint;
  const _LocalRemovalTarget(
    this.id,
    this.binding,
    this.download,
    this.file,
    this.fingerprint,
  );
}

class _LocalRemovalPlan {
  final LocalDirectoryRemovalPlan summary;
  final LocalDirectoryRemovalScope scope;
  final String documents;
  final List<_LocalRemovalTarget> targets;
  const _LocalRemovalPlan(
    this.summary,
    this.scope,
    this.documents,
    this.targets,
  );
}

List<Object?> _localRemovalFingerprint(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.file) return [type.toString()];
  final stat = File(path).statSync();
  return [
    type.toString(),
    stat.size,
    stat.modified.microsecondsSinceEpoch,
    stat.changed.microsecondsSinceEpoch,
    stat.mode,
  ];
}

extension _OfflineLocalDirectoryRemoval on _OfflineWorker {
  bool _safeRemovalPath(String path) {
    final boundary = p.normalize(p.absolute(root));
    var cursor = p.normalize(p.absolute(path));
    if (!p.isWithin(boundary, cursor)) return false;
    while (cursor != boundary) {
      if (FileSystemEntity.typeSync(cursor, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      cursor = p.dirname(cursor);
    }
    return FileSystemEntity.typeSync(boundary, followLinks: false) !=
        FileSystemEntityType.link;
  }

  Map<String, dynamic> _removalDownloadIdentity(Map<String, dynamic> row) => {
    for (final key in [
      'mediaId',
      'sourceId',
      'remotePath',
      'bindingRevision',
      'localPath',
      'downloadRoot',
      'downloadRelativePath',
      'createdOrder',
      'status',
    ])
      key: row[key],
  };

  bool _downloadMatchesBinding(Map<String, dynamic> row, Map? binding) =>
      row['status'] == 'completed' &&
      row['isDirectory'] != true &&
      (binding == null ||
          (binding['source'] == row['sourceId'] &&
              binding['path'] == row['remotePath'] &&
              (binding['previewRevision'] ?? '') ==
                  (row['bindingRevision'] ?? '')));

  Future<LocalDirectoryRemovalPlan> _prepareLocalDirectoryRemoval(
    String path,
    String documents,
    CancelToken cancel,
  ) async {
    cancel.check();
    final scope = LocalDirectoryRemovalScope.parse(path);
    await _ensureDatabase();
    cancel.check();
    final library = store ??= AppStore(':memory:');
    final targets = <_LocalRemovalTarget>[];
    var downloaded = 0, managed = 0, linked = 0;
    String? after;
    while (true) {
      cancel.check();
      final batch = library.db.select(
        'SELECT id FROM records WHERE kind=? AND deleted=0 '
        '${after == null ? '' : 'AND id>? '}ORDER BY id LIMIT 128',
        ['media', ?after],
      );
      if (batch.isEmpty) break;
      for (final record in batch) {
        final id = record['id'] as String;
        final value = library.local('location:$id');
        final binding = value is Map ? Map<String, dynamic>.from(value) : null;
        final download = rows[id];
        if (download != null && _downloadMatchesBinding(download, binding)) {
          if (!scope.containsDownload(download)) continue;
          final file = download['localPath'] as String;
          if (!_safeRemovalPath(file) || !_safeRemovalPath('$file.part')) {
            throw const AppFailure('下载路径不可用，未删除文件。');
          }
          targets.add(
            _LocalRemovalTarget(
              id,
              binding,
              _removalDownloadIdentity(download),
              file,
              _localRemovalFingerprint(file),
            ),
          );
          downloaded++;
        } else if (path.isEmpty &&
            binding?['source'] == 'local' &&
            binding?['path'] is String) {
          final file = managedLocalVideoFile(
            documents,
            binding!['path'] as String,
          )?.path;
          targets.add(
            _LocalRemovalTarget(
              id,
              binding,
              null,
              file,
              file == null ? null : _localRemovalFingerprint(file),
            ),
          );
          if (file == null) {
            linked++;
          } else {
            managed++;
          }
        }
        if (targets.length > 20000) {
          throw const AppFailure('单次最多删除 20000 个本地视频，请选择更小的文件夹。');
        }
      }
      after = batch.last['id'] as String;
      await Future<void>.delayed(Duration.zero);
    }
    cancel.check();
    if (targets.isEmpty) throw const AppFailure('此文件夹已没有可删除的本地视频，请刷新后重试。');
    var name = scope.relative.isEmpty
        ? '本地视频'
        : p.posix.basename(scope.relative);
    if (scope.source.isNotEmpty && scope.relative.isEmpty) {
      final source = (library.local('sources') as List? ?? const [])
          .whereType<Map>()
          .where((value) => value['id'] == scope.source)
          .firstOrNull;
      name = '${source?['label'] ?? '下载视频'}';
    }
    final summary = LocalDirectoryRemovalPlan(
      token: 'remove:${++serial}',
      path: path,
      name: name,
      downloads: downloaded,
      managed: managed,
      linked: linked,
    );
    // Confirmation dialogs never retain an unbounded collection of snapshots.
    while (removalPlans.length >= 4) {
      removalPlans.remove(removalPlans.keys.first);
    }
    removalPlans[summary.token] = _LocalRemovalPlan(
      summary,
      scope,
      documents,
      targets,
    );
    return summary;
  }

  bool _removalTargetCurrent(
    _LocalRemovalPlan plan,
    _LocalRemovalTarget target,
  ) {
    final library = store!;
    if (library.get('media', target.id)?.deleted != false ||
        !sameLocalVideoBinding(
          target.binding,
          library.local('location:${target.id}'),
        )) {
      return false;
    }
    if (target.download case final expected?) {
      final current = rows[target.id];
      if (current == null ||
          !mapEquals(expected, _removalDownloadIdentity(current)) ||
          !plan.scope.containsDownload(current)) {
        return false;
      }
    } else {
      final current = library.local('location:${target.id}') as Map;
      final owned = managedLocalVideoFile(
        plan.documents,
        current['path'] as String,
      )?.path;
      if (owned != target.file) return false;
    }
    return target.file == null ||
        listEquals(target.fingerprint, _localRemovalFingerprint(target.file!));
  }

  Future<LocalDirectoryRemovalResult> _deleteLocalDirectory(
    String token,
    CancelToken cancel,
  ) async {
    final plan = removalPlans.remove(token);
    if (plan == null) throw const AppFailure('删除预览已失效，请重新选择文件夹。');
    var removed = 0, skipped = 0, failed = 0, localChanged = false;
    var error = '';
    final removedDownloads = <String>[];
    void publish() {
      if (!closing && (removedDownloads.isNotEmpty || localChanged)) {
        reply.send([
          'directoryRemoved',
          List<String>.of(removedDownloads),
          localChanged,
        ]);
      }
      removedDownloads.clear();
      localChanged = false;
    }

    try {
      for (var index = 0; index < plan.targets.length; index++) {
        if (cancel.cancelled || closing) break;
        final target = plan.targets[index];
        try {
          // Binding checks and filesystem mutations share the library write
          // transaction. No await or UI-side lock wait can interleave a rebind.
          await retryStoreBusy(() {
            cancel.check();
            store!.db.execute('PRAGMA busy_timeout=0');
            try {
              if (target.download != null) {
                store!.transaction(() {
                  if (!_removalTargetCurrent(plan, target)) {
                    throw const Cancelled();
                  }
                  final path = target.file!;
                  for (final file in [path, '$path.part']) {
                    if (!_safeRemovalPath(file)) {
                      throw const AppFailure('下载路径不可用，未删除文件。');
                    }
                  }
                  for (final file in [path, '$path.part']) {
                    if (FileSystemEntity.typeSync(file, followLinks: false) ==
                        FileSystemEntityType.file) {
                      File(file).deleteSync();
                    }
                  }
                  var parent = p.dirname(path);
                  while (p.isWithin(root, parent) && _safeRemovalPath(parent)) {
                    try {
                      Directory(parent).deleteSync();
                    } on FileSystemException {
                      break;
                    }
                    parent = p.dirname(parent);
                  }
                  db!.execute('DELETE FROM downloads WHERE id=?', [target.id]);
                  rows.remove(target.id);
                });
                removedDownloads.add(target.id);
              } else {
                final changed = removeLocalVideo(
                  store!,
                  plan.documents,
                  target.id,
                  target.binding!,
                  guard: () => _removalTargetCurrent(plan, target),
                );
                if (!changed) throw const Cancelled();
                localChanged = true;
              }
            } finally {
              store!.db.execute('PRAGMA busy_timeout=5000');
            }
          });
          removed++;
        } on Cancelled {
          if (cancel.cancelled || closing) break;
          skipped++;
        } catch (failure) {
          failed++;
          if (error.isEmpty) error = _downloadError(failure);
        }
        if ((index + 1) % 32 == 0) publish();
        // Already on the background worker; only yield for bounded cancellation
        // latency between files, never as a substitute for background execution.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      publish();
    }
    return LocalDirectoryRemovalResult(
      removed: removed,
      skipped: skipped,
      failed: failed,
      cancelled: cancel.cancelled || closing,
      error: error,
    );
  }
}
