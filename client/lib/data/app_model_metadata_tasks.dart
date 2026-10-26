part of 'app_model.dart';

/// A model-owned task: dismissing its view does not cancel its work.
class MetadataTask extends ChangeNotifier {
  final String id, label;
  final bool ai, manual;
  final List<SyncRecord> _records;
  late final Map<String, int> _recordPositions = {
    for (var i = 0; i < _records.length; i++) _records[i].id: i,
  };
  final Map<String, dynamic>? _selection;
  final String _selectionSeason;
  final AiMediaIdentity? _identity;
  final MetadataTask? _parentTask;
  MetadataTask? _selectionTask;
  final _cancel = CancelToken();
  CancelToken? _attemptCancel;
  CancelToken get _workCancel => _attemptCancel ?? _cancel;
  final _done = Completer<void>();
  Timer? _progressTimer;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, AiMetadataMatch> results = {};
  final Set<String> _completedIds = {};
  final Set<String> _matchedIds = {};
  final Map<String, (SyncRecord, Map<String, dynamic>)> _pendingEpisodeNames =
      {};
  int matched = 0, failed = 0;
  bool running = true, cancelled = false, _started = false;
  bool _external = false, _removed = false;
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
    MetadataTask? parentTask,
  }) : _selection = selection,
       _selectionSeason = selectionSeason,
       _identity = identity,
       _parentTask = parentTask;
  late final List<SyncRecord> records = UnmodifiableListView(_records);
  bool get removed => _removed;
  bool isMatched(String id) => _matchedIds.contains(id);
  bool containsMedia(String id) => _recordPositions.containsKey(id);
  MetadataTask? get selectionTask => _selectionTask;
  void _appendRecords(List<SyncRecord> records) {
    for (final record in records) {
      final index = _recordPositions[record.id];
      if (index == null) {
        _recordPositions[record.id] = _records.length;
        _records.add(record);
      } else {
        _records[index] = record;
      }
    }
  }

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
  List<MetadataTask> get metadataTasks => List.unmodifiable(
    _metadataTasks.reversed.where((t) => t._parentTask == null),
  );

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
    MetadataTask? parentTask,
  }) => _enqueueMetadataTask(
    records,
    ai: identity != null,
    manual: true,
    label: label,
    selection: candidate,
    selectionSeason: season,
    identity: identity,
    parentTask: parentTask,
  );

  MetadataTask _enqueueMetadataTask(
    List<SyncRecord> records, {
    required bool ai,
    required bool manual,
    String? label,
    Map<String, dynamic>? selection,
    String selectionSeason = '',
    AiMediaIdentity? identity,
    MetadataTask? parentTask,
  }) {
    _restoreMetadataTasks();
    if (parentTask != null &&
        (parentTask.removed ||
            parentTask.running ||
            parentTask.selectionTask?.running == true)) {
      throw const AppFailure('请等待当前识别完成后再匹配。');
    }
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
              identical(task._parentTask, parentTask) &&
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
      parentTask: parentTask,
    );
    _metadataTasks.add(task);
    if (parentTask != null) {
      // A new explicit choice supersedes the previous automatic attempt's
      // error. Its own result remains on the child, scoped to the chosen file.
      parentTask.error = '';
      _setMetadataTaskStatus(parentTask);
      parentTask._selectionTask = task;
      parentTask._changed();
    }
    _persistMetadataTasks();
    if (!_disposed) changed();
    scheduleMicrotask(_drainMetadataTasks);
    return task;
  }

  void cancelMetadataTask(MetadataTask task) {
    final selection = task.selectionTask;
    if (selection?.running == true) cancelMetadataTask(selection!);
    if (!task.running) return;
    task.cancelled = true;
    task.running = false;
    task.status = '已取消';
    task._cancel.cancel();
    task._attemptCancel?.cancel();
    if (!task._external) _persistMetadataTasks();
    unawaited(_completeMetadataTask(task));
    _taskChanged(task);
  }

  /// Removes only task history. Applied media information remains in the library.
  void removeMetadataTask(MetadataTask task) {
    if (task.removed || !_metadataTasks.contains(task)) return;
    final removed = _metadataTasks
        .where(
          (item) => identical(item, task) || identical(item._parentTask, task),
        )
        .toList();
    for (final item in removed) {
      item._removed = true;
      item._progressTimer?.cancel();
      if (item.running) {
        item.cancelled = true;
        item.running = false;
        item._cancel.cancel();
        item._attemptCancel?.cancel();
      }
      _metadataTasks.remove(item);
      item._changed();
    }
    if (removed.any((item) => !item._external)) _persistMetadataTasks();
    for (final item in removed) {
      unawaited(_completeMetadataTask(item));
    }
    if (!_disposed) changed();
  }

  void removeMetadataTaskRecord(MetadataTask task, String id) {
    if (task.removed || task.running || task.selectionTask?.running == true) {
      return;
    }
    final index = task._records.indexWhere((record) => record.id == id);
    if (index < 0) return;
    task._records.removeAt(index);
    task._recordPositions.remove(id);
    for (var i = index; i < task._records.length; i++) {
      task._recordPositions[task._records[i].id] = i;
    }
    task.results.remove(id);
    task._pendingEpisodeNames.remove(id);
    if (task._completedIds.remove(id)) {
      if (task._matchedIds.remove(id)) {
        task.matched--;
      } else if (task.failed > 0) {
        task.failed--;
      }
    }
    if (task.total == 0) {
      removeMetadataTask(task);
      return;
    }
    _setMetadataTaskStatus(task);
    _taskChanged(task);
  }

  void _setMetadataTaskStatus(MetadataTask task) {
    if (task.cancelled || task.running) return;
    if (task.matched == task.total) task.error = '';
    task.status = task.matched == task.total
        ? '已匹配 ${task.matched} 个视频'
        : '已匹配 ${task.matched}/${task.total}，其余可手动选择';
  }

  void _persistMetadataTasks() {
    if (_disposed) return;
    final snapshot = <Map<String, dynamic>>[
      for (final task in _metadataTasks.where(
        (t) => t.running && !t.cancelled && !t._external,
      ))
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
    ];
    if (store.path == ':memory:') {
      store.setLocal('metadata:pending-tasks', snapshot);
      return;
    }
    // Keep only the latest checkpoint while a worker owns the writer lock.
    // Status/progress notifications do not rewrite the task list.
    _pendingMetadataCheckpoint = snapshot;
    _metadataCheckpointWrite ??= _writeMetadataCheckpoints();
  }

  Future<void> _writeMetadataCheckpoints() async {
    try {
      while (_pendingMetadataCheckpoint != null) {
        final snapshot = _pendingMetadataCheckpoint!;
        _pendingMetadataCheckpoint = null;
        try {
          await (_localStateWorker ??= LocalStateWorker(
            store.path,
          )).saveMetadataTasks(snapshot);
          _metadataCheckpointError = null;
        } catch (error, stack) {
          _metadataCheckpointError = (error, stack);
          AppLog.instance.warning('识别任务保存', safeFailure(error).message);
        }
      }
    } finally {
      _metadataCheckpointWrite = null;
    }
  }

  /// Await durable task state before restarting the model or closing its store.
  Future<void> flushMetadataTasks() async {
    while (_metadataCheckpointWrite != null) {
      final pending = _metadataCheckpointWrite!;
      await pending;
    }
    await _localStateShutdown;
    if (_metadataCheckpointError case final error?) {
      Error.throwWithStackTrace(error.$1, error.$2);
    }
  }

  Future<void> _completeMetadataTask(MetadataTask task) async {
    try {
      await flushMetadataTasks();
    } catch (error) {
      if (!_disposed && !task.removed) {
        task.error = safeFailure(error).message;
        task.status = '识别任务保存失败';
        task._changed();
      }
    } finally {
      if (!task._done.isCompleted) task._done.complete();
    }
  }

  void _restoreMetadataTasks() {
    if (_metadataTasksRestored) return;
    _metadataTasksRestored = true;
    final saved = store.local('metadata:pending-tasks');
    if (saved is! List || saved.isEmpty || _metadataTasks.isNotEmpty) return;
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
          .._matchedIds.addAll(pendingNames.keys)
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
    if (_disposed || task.removed) return;
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
    task._changed();
    if (task._parentTask case final parent?) {
      if (!parent.removed) parent._changed();
    }
    changed();
  }

  void _taskCompleteRecord(MetadataTask task, SyncRecord record, bool matched) {
    if (_disposed ||
        task.removed ||
        task.cancelled ||
        !task._completedIds.add(record.id)) {
      return;
    }
    if (matched) {
      task._matchedIds.add(record.id);
      task.matched++;
    } else {
      task.failed++;
    }
    task.status = '已处理 ${task.completed}/${task.total} · 已匹配 ${task.matched}';
    if (matched && task._parentTask != null) {
      final parent = task._parentTask;
      if (!parent.removed) {
        final index = parent._recordPositions[record.id];
        if (index != null) {
          parent._records[index] =
              task._records[task._recordPositions[record.id]!];
          final wasCompleted = parent._completedIds.add(record.id) == false;
          if (parent._matchedIds.add(record.id)) {
            parent.matched++;
            if (wasCompleted && parent.failed > 0) parent.failed--;
          }
          if (task.results[record.id] case final result?) {
            parent.results[record.id] = result;
          }
          _setMetadataTaskStatus(parent);
        }
      }
    }
    _taskChanged(task);
  }

  bool _taskMayApply(MetadataTask task, SyncRecord record) {
    if (_disposed || task.removed || task._parentTask?.removed == true) {
      return false;
    }
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
                  !t._external &&
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
          await _refreshMatchedMetadataRecords(task);
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
          if (!_disposed) _persistMetadataTasks();
          if (!paused) await _completeMetadataTask(task);
          if (!paused && task._parentTask != null) {
            // The parent retains the latest selection result; hidden child
            // jobs need no separate, ever-growing history in the queue.
            _metadataTasks.remove(task);
          }
        }
      }
    } finally {
      _metadataWorkerRunning = false;
    }
  }

  Future<void> _refreshMatchedMetadataRecords(MetadataTask task) async {
    if (task._matchedIds.isEmpty) return;
    _checkTaskReady(task);
    final records = store.path == ':memory:'
        ? [
            for (final id in task._matchedIds)
              if (store.get('media', id) case final record?)
                if (!record.deleted) record,
          ]
        : await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
            store.path,
          )).readRecords(task._matchedIds, cancel: task._workCancel);
    _checkTaskReady(task);
    // Optional episode enrichment can write a newer media revision. Keep the
    // review snapshots current so revisiting a completed item can match again.
    for (final record in records) {
      if (task._recordPositions[record.id] case final index?) {
        task._records[index] = record;
      }
      final parent = task._parentTask;
      if (parent != null && !parent.removed) {
        if (parent._recordPositions[record.id] case final index?) {
          parent._records[index] = record;
        }
      }
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
                _persistMetadataTasks();
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
      wholeFolder: task.manual && task.ai,
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
    _persistMetadataTasks();
    await _fillTaskEpisodeNames(task);
  }

  Future<void> _runMetadataSelection(MetadataTask task) async {
    final token = task._workCancel;
    task.status = '正在读取作品资料…';
    _taskChanged(task);
    var detailsAvailable = true;
    final full = await catalog.selectionDetails(
      task._selection!,
      season: task._selectionSeason,
      cancel: token,
      onFallback: () => detailsAvailable = false,
    );
    final identities = <String, AiMediaIdentity>{};
    if (task._identity != null) {
      final unresolved = <String>[];
      for (final record in task._records) {
        final filename = MediaAiRecognition.filenameOnly(
          metadataFileName(record),
        );
        final known =
            task._parentTask?.results[record.id]?.identity ??
            (task.total == 1 ? task._identity : null);
        if (known != null && known.fileName == filename) {
          identities[filename] = known;
        } else {
          unresolved.add(filename);
        }
      }
      if (unresolved.isNotEmpty) {
        task.status = '正在批量解析各集文件名…';
        _taskChanged(task);
        final config = await _metadataAiConfig();
        token.check();
        identities.addAll(
          await mediaAi.analyzeFilenames(
            unresolved,
            config: config,
            cancel: token,
          ),
        );
      }
    }
    token.check();
    task.status = '正在保存匹配资料…';
    _taskChanged(task);
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
    // A failed optional detail request has already consumed its timeout.
    // Keep the explicit identity and let normal catalogue enrichment retry
    // later instead of blocking this selection on the same service again.
    if (!detailsAvailable || task.matched == 0) return;
    task.status = '资料已匹配，正在补充分集名称…';
    _taskChanged(task);
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
    if (grouped.isNotEmpty) _persistMetadataTasks();
  }
}
