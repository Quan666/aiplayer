part of 'offline_downloads.dart';

extension _OfflineBatchWork on _OfflineWorker {
  OfflineDownloadSelection _captureSelection() {
    // A retained sheet owns one capture. Bound abandoned/overlapping sheets
    // without polling or retaining an unbounded history of completed tasks.
    while (selections.length >= 4) {
      selections.remove(selections.keys.first);
    }
    final token = 'selection:${++serial}';
    final captured = <String, int>{
      for (final row in rows.values)
        row['mediaId'] as String: row['createdOrder'] as int,
    };
    selections[token] = captured;
    return OfflineDownloadSelection(token: token, ids: captured.keys.toList());
  }

  Future<void> _applyBatch(Map<String, dynamic> input) async {
    final captured = selections[input['token']];
    if (captured == null) {
      throw const AppFailure('任务选择已失效，请重新选择。');
    }
    final all = input['all'] == true;
    final ids = Set<String>.from(input['ids'] as Set);
    final selected = <Map<String, dynamic>>[];
    for (final entry in captured.entries) {
      if (all == ids.contains(entry.key)) continue;
      final row = rows[entry.key];
      if (row != null && row['createdOrder'] == entry.value) selected.add(row);
    }
    if (selected.isEmpty) return;
    final action = OfflineDownloadBatchAction.values.byName(
      input['action'] as String,
    );
    if (action == OfflineDownloadBatchAction.delete) {
      await _deleteBatch(selected);
      return;
    }
    final changed = <OfflineDownload>[];
    final pending = <Future<void>>[];
    final updates = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    db!.execute('BEGIN IMMEDIATE');
    try {
      for (final row in selected) {
        final next = Map<String, dynamic>.from(row);
        if (action == OfflineDownloadBatchAction.pause) {
          if (!const [
            'queued',
            'downloading',
            'paused',
          ].contains(row['status'])) {
            continue;
          }
          next['userPaused'] = true;
          next['status'] = 'paused';
        } else {
          if (!const ['paused', 'failed'].contains(row['status'])) continue;
          next['userPaused'] = false;
          next['status'] = _readyStatus(next);
          next['error'] = '';
        }
        _save(next, notify: false);
        updates.add((row, next));
      }
      db!.execute('COMMIT');
    } catch (_) {
      db!.execute('ROLLBACK');
      rethrow;
    }
    // Publish only committed state. No await occurs between committing every
    // selected pause and cancelling running transfers, so slots cannot refill.
    for (final (row, next) in updates) {
      row.addAll(next);
      changed.add(OfflineDownload._fromMap(next));
      if (action == OfflineDownloadBatchAction.pause) {
        final attempt = running[row['mediaId']];
        attempt?.stop();
        if (attempt?.done != null) pending.add(attempt!.done!);
      }
    }
    // Bounded messages keep UI parsing and listener fan-out bounded. Completed
    // membership does not change on pause/resume, so library caches stay valid.
    for (var start = 0; start < changed.length; start += 64) {
      if (!closing) {
        reply.send([
          'batchChanged',
          changed.sublist(start, (start + 64).clamp(0, changed.length)),
        ]);
      }
    }
    await Future.wait(pending);
    _pump();
  }

  Future<void> _deleteBatch(List<Map<String, dynamic>> selected) async {
    final selectedIds = <String>[
      for (final row in selected) row['mediaId'] as String,
    ];
    // Block every selected queued task before awaiting socket shutdown. A
    // completed cancellation must never free a slot for another selected task.
    deleting.addAll(selectedIds);
    for (final id in selectedIds) {
      running[id]?.stop();
    }
    final removed = <String>[];
    String? firstError;
    var failures = 0;
    try {
      for (final id in selectedIds) {
        if (closing) break;
        try {
          await _remove(id, notify: false);
          removed.add(id);
        } catch (error) {
          failures++;
          firstError ??= _downloadError(error);
          final row = rows[id];
          if (row != null) {
            row['status'] = 'failed';
            row['userPaused'] = true;
            row['error'] = _downloadError(error);
            _save(row);
          }
        }
      }
    } finally {
      deleting.removeAll(selectedIds);
      if (!closing && removed.isNotEmpty) {
        for (var start = 0; start < removed.length; start += 64) {
          reply.send([
            'batchRemoved',
            removed.sublist(start, (start + 64).clamp(0, removed.length)),
          ]);
        }
        // Prepare replacement membership once here, avoiding quadratic list
        // removals or repeated full-list copies on the UI isolate.
        reply.send(['taskIds', rows.keys.toList()]);
      }
      _pump();
    }
    if (failures > 0) {
      throw AppFailure('已删除 ${removed.length} 个，$failures 个未能删除。$firstError');
    }
  }
}
