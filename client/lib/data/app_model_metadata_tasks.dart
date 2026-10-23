part of 'app_model.dart';

/// A model-owned task: dismissing its view does not cancel its work.
class MetadataTask extends ChangeNotifier {
  final String id, label;
  final bool ai, manual;
  final List<SyncRecord> _records;
  final Map<String, dynamic>? _selection;
  final String _selectionSeason;
  final AiMediaIdentity? _identity;
  final _cancel = CancelToken();
  CancelToken? _attemptCancel;
  CancelToken get _workCancel => _attemptCancel ?? _cancel;
  final _done = Completer<void>();
  Timer? _progressTimer;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, AiMetadataMatch> results = {};
  final Set<String> _completedIds = {};
  final Map<String, (SyncRecord, Map<String, dynamic>)> _pendingEpisodeNames =
      {};
  int matched = 0, failed = 0;
  bool running = true, cancelled = false, _started = false;
  String status = '等待识别', error = '';
  MetadataTask._(
    this.id,
    this.label,
    this._records, {
    required this.ai,
    required this.manual,
    Map<String, dynamic>? selection,
    String selectionSeason = '',
    AiMediaIdentity? identity,
  }) : _selection = selection,
       _selectionSeason = selectionSeason,
       _identity = identity;
  Set<String> get mediaIds => _records.map((r) => r.id).toSet();
  int get total => _records.length;
  int get completed => _completedIds.length;
  Future<void> get done => _done.future;
  List<Map<String, dynamic>> get _savedEpisodeNames {
    final grouped = <String, Map<String, dynamic>>{};
    for (final pending in _pendingEpisodeNames.values) {
      final record = pending.$1, subject = pending.$2;
      final key = _taskEpisodeNamesKey(subject, record);
      final group = grouped.putIfAbsent(
        key,
        () => {'subject': subject, 'records': <Map<String, Object>>[]},
      );
      (group['records'] as List).add({
        'id': record.id,
        'revision': record.revision,
      });
    }
    return grouped.values.toList();
  }

  void _changed() => notifyListeners();
}

String _taskEpisodeNamesKey(Map<String, dynamic> subject, SyncRecord record) =>
    '${subject['provider']}:${subject['mediaType']}:${subject['id']}:${record.data['season']}';

Map<String, dynamic> _taskEpisodeNamesSubject(Map<String, dynamic> subject) => {
  for (final key in const [
    'provider',
    'id',
    'mediaType',
    'season',
    'season_episodes',
    'episodeNames',
  ])
    if (subject.containsKey(key)) key: subject[key],
};

class _MetadataPaused implements Exception {
  const _MetadataPaused();
}

class _MetadataLimiter {
  final int limit;
  int active = 0;
  final List<Completer<void>> waiting = [];
  _MetadataLimiter(this.limit);
  Future<T> run<T>(CancelToken cancel, Future<T> Function() work) async {
    cancel.check();
    if (active >= limit) {
      final slot = Completer<void>();
      waiting.add(slot);
      await slot.future;
    } else {
      active++;
    }
    try {
      cancel.check();
      return await work();
    } finally {
      if (waiting.isNotEmpty) {
        waiting.removeAt(0).complete();
      } else {
        active--;
      }
    }
  }
}

extension MetadataBackgroundTasks on AppModel {
  List<MetadataTask> get metadataTasks =>
      List.unmodifiable(_metadataTasks.reversed);

  MetadataTask? metadataTaskFor(Set<String> mediaIds) => metadataTasks
      .where((task) => setEquals(task.mediaIds, mediaIds))
      .firstOrNull;

  MetadataTask startMetadataTask(
    List<SyncRecord> records, {
    bool ai = false,
    bool manual = true,
    String? label,
  }) => _enqueueMetadataTask(records, ai: ai, manual: manual, label: label);

  MetadataTask startMetadataSelectionTask(
    List<SyncRecord> records,
    Map<String, dynamic> candidate, {
    required String season,
    AiMediaIdentity? identity,
    String? label,
  }) => _enqueueMetadataTask(
    records,
    ai: identity != null,
    manual: true,
    label: label,
    selection: candidate,
    selectionSeason: season,
    identity: identity,
  );

  MetadataTask _enqueueMetadataTask(
    List<SyncRecord> records, {
    required bool ai,
    required bool manual,
    String? label,
    Map<String, dynamic>? selection,
    String selectionSeason = '',
    AiMediaIdentity? identity,
  }) {
    _restoreMetadataTasks();
    final unique = {
      for (final r in records)
        if (!r.deleted) r.id: r,
    }.values.toList();
    final ids = unique.map((r) => r.id).toSet();
    final existing = _metadataTasks
        .where(
          (task) =>
              task.running &&
              !task.cancelled &&
              task.ai == ai &&
              task.manual == manual &&
              _equalMetadata(task._selection, selection) &&
              task._selectionSeason == selectionSeason &&
              setEquals(task.mediaIds, ids),
        )
        .firstOrNull;
    if (existing != null) return existing;
    final task = MetadataTask._(
      const Uuid().v4(),
      label ??
          (unique.length == 1
              ? seriesTitle(unique.first)
              : '${unique.length} 个视频'),
      unique,
      ai: ai,
      manual: manual,
      selection: selection,
      selectionSeason: selectionSeason,
      identity: identity,
    );
    _metadataTasks.add(task);
    _persistMetadataTasks();
    if (!_disposed) changed();
    scheduleMicrotask(_drainMetadataTasks);
    return task;
  }

  void cancelMetadataTask(MetadataTask task) {
    if (!task.running) return;
    task.cancelled = true;
    task.running = false;
    task.status = '已取消';
    task._cancel.cancel();
    task._attemptCancel?.cancel();
    if (!task._done.isCompleted) task._done.complete();
    _taskChanged(task);
  }

  void _persistMetadataTasks() {
    if (_disposed) return;
    store.setLocal('metadata:pending-tasks', [
      for (final task in _metadataTasks.where((t) => t.running && !t.cancelled))
        {
          'id': task.id,
          'label': task.label,
          'ai': task.ai,
          'manual': task.manual,
          'records': [
            for (final r in task._records)
              if (!task._completedIds.contains(r.id))
                {'id': r.id, 'revision': r.revision},
          ],
          if (task._pendingEpisodeNames.isNotEmpty)
            'episodeNames': task._savedEpisodeNames,
          if (task._selection != null) 'selection': task._selection,
          'season': task._selectionSeason,
          // The parsed identity is already cached by basename. Its presence
          // indicates selected candidates should preserve per-file AI episodes.
          'analyzeSelection': task._identity != null,
        },
    ]);
  }

  void _restoreMetadataTasks() {
    if (_metadataTasksRestored) return;
    _metadataTasksRestored = true;
    final saved = store.local('metadata:pending-tasks');
    if (saved is! List || _metadataTasks.isNotEmpty) return;
    for (final row in saved.whereType<Map>()) {
      final records = <SyncRecord>[];
      final recordIds = <String>{};
      final pendingNames = <String, (SyncRecord, Map<String, dynamic>)>{};
      for (final item
          in (row['records'] as List? ?? const []).whereType<Map>()) {
        final record = store.get('media', '${item['id']}');
        if (record != null &&
            !record.deleted &&
            record.revision == item['revision']) {
          records.add(record);
          recordIds.add(record.id);
        }
      }
      for (final group
          in (row['episodeNames'] as List? ?? const []).whereType<Map>()) {
        if (group['subject'] is! Map) continue;
        final subject = Map<String, dynamic>.from(group['subject']);
        for (final item
            in (group['records'] as List? ?? const []).whereType<Map>()) {
          final record = store.get('media', '${item['id']}');
          if (record != null &&
              !record.deleted &&
              record.revision == item['revision']) {
            pendingNames[record.id] = (record, subject);
            if (recordIds.add(record.id)) records.add(record);
          }
        }
      }
      if (records.isEmpty ||
          (row['manual'] != true && preferences.metadataStrategy == 'off')) {
        continue;
      }
      _metadataTasks.add(
        MetadataTask._(
            '${row['id']}',
            '${row['label']}',
            records,
            ai: row['ai'] == true,
            manual: row['manual'] == true,
            selection: row['selection'] is Map
                ? Map<String, dynamic>.from(row['selection'])
                : null,
            selectionSeason: '${row['season'] ?? ''}',
            identity: row['analyzeSelection'] == true
                ? const AiMediaIdentity(name: '')
                : null,
          )
          .._pendingEpisodeNames.addAll(pendingNames)
          .._completedIds.addAll(pendingNames.keys)
          ..matched = pendingNames.length,
      );
    }
    _persistMetadataTasks();
    if (_metadataTasks.isNotEmpty) {
      changed();
      unawaited(_drainMetadataTasks());
    }
  }

  void _taskChanged(MetadataTask task) {
    if (_disposed) return;
    task._progressTimer?.cancel();
    final elapsed = DateTime.now().difference(task._lastProgress);
    if (task.running && elapsed < const Duration(milliseconds: 120)) {
      task._progressTimer = Timer(
        const Duration(milliseconds: 120) - elapsed,
        () => _taskChanged(task),
      );
      return;
    }
    task._lastProgress = DateTime.now();
    _persistMetadataTasks();
    task._changed();
    changed();
  }

  void _taskCompleteRecord(MetadataTask task, SyncRecord record, bool matched) {
    if (_disposed || task.cancelled || !task._completedIds.add(record.id)) {
      return;
    }
    if (matched) {
      task.matched++;
    } else {
      task.failed++;
    }
    task.status = '已处理 ${task.completed}/${task.total} · 已匹配 ${task.matched}';
    _taskChanged(task);
  }

  bool _taskMayApply(MetadataTask task, SyncRecord record) {
    if (_disposed) return false;
    final current = store.get('media', record.id);
    if (_disposed ||
        task._cancel.cancelled ||
        task._workCancel.cancelled ||
        current == null ||
        current.deleted ||
        current.revision != record.revision) {
      return false;
    }
    return task.manual ||
        (preferences.metadataStrategy != 'off' &&
            store.local('manualMetadata:${record.id}') != true &&
            current.data['bangumiId'] == null &&
            current.data['tmdbId'] == null);
  }

  void _checkTaskReady(MetadataTask task) {
    if (_disposed) throw const Cancelled();
    task._cancel.check();
    if (_clearingCaches ||
        (!task.manual && (!_foreground || activePlaybackMediaId != null))) {
      throw const _MetadataPaused();
    }
    task._workCancel.check();
  }

  void _pauseAutomaticMetadataTasks() {
    // A batch parser owns its own bounded request queue. Cancel the current
    // attempt so that it also stops admitting queued HTTP work while hidden.
    // The permanent task token remains live for foreground resumption.
    var paused = false;
    for (final task in _metadataTasks) {
      final attempt = task._attemptCancel;
      if (!task.manual && task.running && attempt?.cancelled == false) {
        attempt!.cancel();
        paused = true;
      }
    }
    if (paused) _persistMetadataTasks();
  }

  Future<void> _drainMetadataTasks() async {
    if (_disposed || _clearingCaches || _metadataWorkerRunning) return;
    _metadataWorkerRunning = true;
    try {
      while (!_disposed && !_clearingCaches) {
        final task = _metadataTasks
            .where(
              (t) =>
                  t.running &&
                  !t._started &&
                  (t.manual || (_foreground && activePlaybackMediaId == null)),
            )
            .firstOrNull;
        if (task == null) break;
        task._started = true;
        final attempt = task.manual ? null : CancelToken();
        task._attemptCancel = attempt;
        var paused = false;
        try {
          await _runMetadataTask(task);
        } on _MetadataPaused {
          paused = true;
          task._started = false;
          task.status = '等待空闲';
          _taskChanged(task);
        } on Cancelled {
          if (!_disposed &&
              !task._cancel.cancelled &&
              attempt?.cancelled == true) {
            paused = true;
            task._started = false;
            task.status = '等待空闲';
            _taskChanged(task);
          } else if (!_disposed) {
            task.cancelled = true;
            task.status = '已取消';
          }
        } catch (error) {
          if (!_disposed) {
            task.error = safeFailure(error).message;
            task.status = '识别未完成';
          }
        } finally {
          task._attemptCancel = null;
          if (!paused && !_disposed) {
            task.running = false;
            if (task.matched == task.total) task.error = '';
            if (!task.cancelled && task.error.isEmpty) {
              task.status = task.matched == task.total
                  ? '已匹配 ${task.matched} 个视频'
                  : '已匹配 ${task.matched}/${task.total}，其余可手动选择';
            }
            _taskChanged(task);
          }
          if (!paused && !task._done.isCompleted) task._done.complete();
        }
      }
    } finally {
      _metadataWorkerRunning = false;
    }
  }

  Future<void> _runMetadataTask(MetadataTask task) async {
    final token = task._workCancel;
    _checkTaskReady(task);
    await _fillPendingTaskEpisodeNames(task);
    if (task.completed == task.total) {
      await _fillTaskEpisodeNames(task);
      return;
    }
    if (task._selection != null) {
      await _runMetadataSelection(task);
      return;
    }
    final remaining = <SyncRecord>[];
    if (!task.ai) {
      task.status = '正在识别作品…';
      _taskChanged(task);
      final groups = <String, List<SyncRecord>>{};
      for (final record in task._records.where(
        (r) => !task._completedIds.contains(r.id),
      )) {
        (groups[_identityKey(record)] ??= []).add(record);
      }
      await Future.wait(
        groups.values.map(
          (records) => _metadataLookups.run(token, () async {
            _checkTaskReady(task);
            if (_disposed) throw const Cancelled();
            final first = records.first;
            Map<String, dynamic>? subject;
            try {
              subject = await catalog.resolve(
                '${first.data['series']}',
                '${first.data['season'] ?? ''}',
                force: task.manual,
                cancel: token,
              );
            } on Cancelled {
              rethrow;
            } catch (error) {
              task.error = safeFailure(error).message;
            }
            token.check();
            // A lookup may have started in the foreground and returned after
            // the app was hidden. Resume from the cached result when visible,
            // without starting episode requests or writes while suspended.
            _checkTaskReady(task);
            if (subject == null) {
              remaining.addAll(records);
              return;
            }
            final allowed = records
                .where((record) => _taskMayApply(task, record))
                .toList();
            if (allowed.isNotEmpty) {
              applyBangumi(
                '${first.data['series']}',
                subject,
                manual: task.manual,
                mediaIds: allowed.map((r) => r.id).toSet(),
              );
              if (!task.manual) {
                // Identity is committed before optional episode lookup. A
                // background pause must not retry its now-obsolete revision
                // and count an already matched record as a failed attempt.
                final namesSubject = _taskEpisodeNamesSubject(subject);
                for (final record in allowed) {
                  task._pendingEpisodeNames[record.id] = (
                    store.get('media', record.id)!,
                    namesSubject,
                  );
                }
                for (final record in records) {
                  _taskCompleteRecord(task, record, allowed.contains(record));
                }
              }
              try {
                if (task.manual) {
                  await fillEpisodeNames(
                    '${first.data['series']}',
                    subject,
                    mediaIds: allowed.map((r) => r.id).toSet(),
                    cancel: token,
                  );
                } else {
                  await _fillPendingTaskEpisodeNames(
                    task,
                    mediaIds: allowed.map((r) => r.id).toSet(),
                  );
                }
              } on Cancelled {
                rethrow;
              } catch (_) {
                /* identity is already saved */
              }
            }
            for (final r in records) {
              _taskCompleteRecord(task, r, allowed.contains(r));
            }
          }),
        ),
      );
    } else {
      remaining.addAll(
        task._records.where((r) => !task._completedIds.contains(r.id)),
      );
    }
    token.check();
    if (_disposed) throw const Cancelled();
    final useAi =
        task.ai ||
        (preferences.aiMetadataEnabled &&
            (task.manual || preferences.metadataStrategy != 'off'));
    if (!useAi) {
      for (final record in remaining) {
        _taskCompleteRecord(task, record, false);
      }
      return;
    }
    _checkTaskReady(task);
    final context = _metadataAiContext;
    final eligible = remaining.where((r) => _taskMayApply(task, r)).toList();
    task.status = '正在批量解析 ${eligible.length} 个文件名…';
    _taskChanged(task);
    final matches = await searchMetadataBatchWithAi(
      eligible.map(metadataFileName).toList(),
      cancel: token,
      checkReady: () => _checkTaskReady(task),
      onProgress: (message) {
        task.status = message;
        _taskChanged(task);
      },
    );
    _checkTaskReady(task);
    for (final record in remaining) {
      _checkTaskReady(task);
      final match =
          matches[MediaAiRecognition.filenameOnly(metadataFileName(record))];
      if (match != null) task.results[record.id] = match;
      var applied = false;
      if (match?.subject != null &&
          _taskMayApply(task, record) &&
          (task.manual || context == _metadataAiContext)) {
        applied = await identifyMediaWithAi(
          record,
          cancel: token,
          manual: task.manual,
          match: match,
          fillNames: false,
          notify: false,
        );
        if (applied && !task.manual) {
          task._pendingEpisodeNames[record.id] = (
            store.get('media', record.id)!,
            _taskEpisodeNamesSubject(match!.subject!),
          );
        }
      }
      _taskCompleteRecord(task, record, applied);
    }
    await _fillTaskEpisodeNames(task);
  }

  Future<void> _runMetadataSelection(MetadataTask task) async {
    final token = task._workCancel;
    task.status = '正在读取作品资料…';
    _taskChanged(task);
    final full = await catalog.details(
      task._selection!,
      season: task._selectionSeason,
      cancel: token,
    );
    Map<String, AiMediaIdentity> identities = {};
    if (task._identity != null) {
      task.status = '正在批量解析各集文件名…';
      _taskChanged(task);
      final config = await _metadataAiConfig();
      identities = await mediaAi.analyzeFilenames(
        task._records.map(metadataFileName).toList(),
        config: config,
        cancel: token,
      );
    }
    token.check();
    for (final record in task._records) {
      if (_disposed) throw const Cancelled();
      var applied = false;
      if (_taskMayApply(task, record)) {
        if (task._identity != null) {
          final identity =
              identities[MediaAiRecognition.filenameOnly(
                metadataFileName(record),
              )];
          if (identity != null) {
            final selected = AiMediaIdentity(
              fileName: identity.fileName,
              name: identity.name,
              titles: identity.titles,
              aliases: identity.aliases,
              kind: identity.kind,
              season: task._selectionSeason,
              episode: identity.episode,
              year: identity.year,
              confidence: identity.confidence,
            );
            final match = AiMetadataMatch(selected, [full], full);
            task.results[record.id] = match;
            applied = await identifyMediaWithAi(
              record,
              cancel: token,
              match: match,
              fillNames: false,
              notify: false,
            );
          }
        } else {
          applyBangumi(
            '${record.data['series']}',
            full,
            mediaIds: {record.id},
            targetSeason: task._selectionSeason,
          );
          applied = true;
        }
      }
      _taskCompleteRecord(task, record, applied);
    }
    try {
      await fillEpisodeNames('', full, mediaIds: task.mediaIds, cancel: token);
    } on Cancelled {
      rethrow;
    } catch (_) {
      /* optional names */
    }
  }

  Future<void> _fillTaskEpisodeNames(MetadataTask task) async {
    if (!task.manual) {
      await _fillPendingTaskEpisodeNames(task);
      return;
    }
    final grouped = <String, (Map<String, dynamic>, Set<String>)>{};
    for (final entry in task.results.entries) {
      final subject = entry.value.subject;
      if (subject == null) continue;
      final key =
          '${subject['provider']}:${subject['mediaType']}:${subject['id']}:${entry.value.identity.season}';
      final group = grouped.putIfAbsent(key, () => (subject, <String>{}));
      group.$2.add(entry.key);
    }
    for (final group in grouped.values) {
      _checkTaskReady(task);
      try {
        await fillEpisodeNames(
          '',
          group.$1,
          mediaIds: group.$2,
          cancel: task._workCancel,
        );
      } on Cancelled {
        rethrow;
      } catch (_) {
        /* optional names */
      }
    }
  }

  Future<void> _fillPendingTaskEpisodeNames(
    MetadataTask task, {
    Set<String>? mediaIds,
  }) async {
    final grouped = <String, (Map<String, dynamic>, Set<String>)>{};
    for (final pending in task._pendingEpisodeNames.values.toList()) {
      final record = pending.$1;
      if (mediaIds != null && !mediaIds.contains(record.id)) continue;
      final current = store.get('media', record.id);
      if (current == null ||
          current.deleted ||
          current.revision != record.revision) {
        task._pendingEpisodeNames.remove(record.id);
        continue;
      }
      final subject = pending.$2;
      final key = _taskEpisodeNamesKey(subject, record);
      final group = grouped.putIfAbsent(key, () => (subject, <String>{}));
      group.$2.add(record.id);
    }
    for (final group in grouped.values) {
      _checkTaskReady(task);
      try {
        await fillEpisodeNames(
          '',
          group.$1,
          mediaIds: group.$2,
          cancel: task._workCancel,
        );
      } on Cancelled {
        rethrow;
      } catch (_) {
        /* optional names */
      }
      for (final id in group.$2) {
        task._pendingEpisodeNames.remove(id);
      }
    }
  }
}
