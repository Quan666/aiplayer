import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/media_ai_recognition.dart';
import '../data/store.dart';
import 'glass.dart';
import 'theme/library_styles.dart';

Future<void> showMetadataMatchDialog(
  BuildContext context,
  AppModel model,
  String title, {
  String season = '',
  Set<String>? mediaIds,
  List<SyncRecord>? records,
  MetadataTask? task,
  bool autoAi = false,
}) => showGlassBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _MetadataMatchSheet(
    model: model,
    title: title,
    season: season,
    mediaIds: mediaIds,
    records: records,
    task: task,
    autoAi: autoAi,
  ),
);

class _MetadataMatchSheet extends StatefulWidget {
  final AppModel model;
  final String title, season;
  final Set<String>? mediaIds;
  final List<SyncRecord>? records;
  final MetadataTask? task;
  final bool autoAi;
  const _MetadataMatchSheet({
    required this.model,
    required this.title,
    required this.season,
    this.mediaIds,
    this.records,
    this.task,
    this.autoAi = false,
  });
  @override
  State<_MetadataMatchSheet> createState() => _MetadataMatchSheetState();
}

class _MetadataRecordDraft {
  final String name, season, error;
  final AiMediaIdentity? identity;
  final AiMetadataMatch? match;
  final List<Map<String, dynamic>> results;
  final bool searched;
  const _MetadataRecordDraft({
    required this.name,
    required this.season,
    required this.error,
    required this.identity,
    required this.match,
    required this.results,
    required this.searched,
  });
}

class _MetadataMatchSheetState extends State<_MetadataMatchSheet> {
  late final _input = TextEditingController(text: widget.title);
  late final _season = TextEditingController(
    text: widget.season.isEmpty ? '1' : widget.season,
  );
  final _prepareCancel = CancelToken();
  final Map<String, _MetadataRecordDraft> _drafts = {};
  List<SyncRecord> _records = const [];
  Map<String, int> _recordIndexes = const {};
  MetadataTask? _task;
  CancelToken? _searchCancel;
  AiMediaIdentity? _identity;
  String? _resultRecordId, _advanceAfterId;
  AiMetadataMatch? _shownMatch;
  List<Map<String, dynamic>> _results = [];
  String _error = '';
  bool _loading = true, _searching = false, _searched = false;
  MetadataTask? get _workTask =>
      _task?.selectionTask?.running == true ? _task!.selectionTask : _task;
  bool get _busy => _loading || _searching || (_workTask?.running ?? false);

  @override
  void initState() {
    super.initState();
    final task =
        widget.task ??
        (widget.mediaIds == null
            ? null
            : widget.model.metadataTaskFor(widget.mediaIds!));
    if (task != null) {
      _loading = false;
      _attachTask(task);
      _startAutoRecognition();
    } else if (widget.records != null) {
      _loading = false;
      _setRecords(widget.records!);
      _startAutoRecognition();
    } else {
      _prepareRecords();
    }
  }

  Future<void> _prepareRecords() async {
    try {
      final snapshot = await widget.model.loadLibrarySnapshot(
        cancel: _prepareCancel,
      );
      if (!mounted || _prepareCancel.cancelled) return;
      final ids = widget.mediaIds;
      final records = ids != null
          ? [for (final id in ids) ?snapshot.byId[id]]
          : snapshot.media
                .where(
                  (record) =>
                      '${record.data['series']}' == widget.title &&
                      '${record.data['season'] ?? ''}' == widget.season,
                )
                .toList();
      setState(() {
        _loading = false;
        _setRecords(records);
      });
      _startAutoRecognition();
    } on Cancelled {
      // Closing the sheet stops only its snapshot read.
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = safeFailure(error).message;
        });
      }
    }
  }

  void _startAutoRecognition() {
    if (widget.autoAi && _workTask?.running != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recognize();
      });
    }
  }

  void _setRecords(List<SyncRecord> records) {
    _records = records;
    _recordIndexes = {
      for (var i = 0; i < records.length; i++) records[i].id: i,
    };
  }

  @override
  void dispose() {
    // Recognition and application jobs belong to the model, not this view.
    _prepareCancel.cancel();
    _searchCancel?.cancel();
    _task?.removeListener(_taskChanged);
    _input.dispose();
    _season.dispose();
    super.dispose();
  }

  void _attachTask(MetadataTask task) {
    _task?.removeListener(_taskChanged);
    _task = task;
    _drafts.clear();
    _shownMatch = null;
    _resultRecordId = null;
    _advanceAfterId = null;
    _setRecords(task.records);
    final selection = task.selectionTask;
    final activeId = selection?.running == true
        ? selection!.records.firstOrNull?.id
        : null;
    if (activeId != null && _recordIndexes.containsKey(activeId)) {
      _loadRecord(activeId);
      _advanceAfterId = activeId;
    }
    task.addListener(_taskChanged);
    _readTask();
  }

  void _saveDraft() {
    final id = _resultRecordId;
    if (id == null) return;
    _drafts[id] = _MetadataRecordDraft(
      name: _input.text,
      season: _season.text,
      error: _error,
      identity: _identity,
      match: _shownMatch,
      results: _results,
      searched: _searched,
    );
  }

  void _loadRecord(String id) {
    _resultRecordId = id;
    final record = _records[_recordIndexes[id]!];
    final draft = _drafts[id];
    _shownMatch = draft?.match;
    _identity = draft?.identity;
    _input.text = draft?.name ?? '${record.data['series'] ?? widget.title}';
    final season = '${record.data['season'] ?? ''}';
    _season.text = draft?.season ?? (season.isEmpty ? '1' : season);
    _results = draft?.results ?? [];
    _searched = draft?.searched ?? false;
    _error = draft?.error ?? '';
    _readSelectedMatch();
  }

  void _readSelectedMatch() {
    final match = _task?.results[_resultRecordId];
    if (match == null || identical(match, _shownMatch)) return;
    _shownMatch = match;
    _identity = match.identity;
    _input.text = match.identity.name;
    _season.text = match.identity.season.isEmpty ? '1' : match.identity.season;
    _results = match.candidates;
    _searched = true;
  }

  void _readTask() {
    final task = _task;
    if (task == null || task.removed) return;
    if (_recordIndexes.length != task.records.length) {
      _setRecords(task.records);
    }
    if (!_recordIndexes.containsKey(_resultRecordId)) {
      final id =
          _records.where((r) => !task.isMatched(r.id)).firstOrNull?.id ??
          _records.firstOrNull?.id;
      if (id != null) _loadRecord(id);
    } else {
      _readSelectedMatch();
    }
    final applied = _advanceAfterId;
    if (applied != null && task.selectionTask?.running != true) {
      _advanceAfterId = null;
      if (task.selectionTask?.isMatched(applied) == true &&
          task.selectionTask?.cancelled == false) {
        _saveDraft();
        final start = (_recordIndexes[applied] ?? -1) + 1;
        for (var offset = 0; offset < _records.length; offset++) {
          final next = _records[(start + offset) % _records.length];
          if (!task.isMatched(next.id)) {
            _loadRecord(next.id);
            break;
          }
        }
      }
    }
  }

  void _taskChanged() {
    if (!mounted) return;
    if (_task?.removed == true) {
      Navigator.pop(context);
      return;
    }
    setState(_readTask);
  }

  String _resultName(String id) {
    final index = _recordIndexes[id];
    return index == null
        ? '视频已移除'
        : widget.model.metadataFileName(_records[index]);
  }

  void _selectRecord(String id) {
    if (id == _resultRecordId) return;
    _searchCancel?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _saveDraft();
      _searching = false;
      _advanceAfterId = null;
      _loadRecord(id);
    });
  }

  Future<void> _chooseRecord() async {
    final selected = await showGlassBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .6,
          child: ListView.builder(
            key: const ValueKey('metadata-record-picker'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _records.length,
            itemBuilder: (context, index) {
              final id = _records[index].id;
              return ListTile(
                selected: id == _resultRecordId,
                leading: Icon(
                  _task!.isMatched(id)
                      ? Icons.check_circle_outline_rounded
                      : Icons.radio_button_unchecked_rounded,
                ),
                title: Text(
                  _resultName(id),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheet, id),
              );
            },
          ),
        ),
      ),
    );
    if (mounted && selected != null) _selectRecord(selected);
  }

  void _removeRecord() {
    final task = _task, id = _resultRecordId;
    if (task == null || id == null || _busy) return;
    _drafts.remove(id);
    widget.model.removeMetadataTaskRecord(task, id);
  }

  void _removeTask() {
    final task = _task;
    if (task != null) widget.model.removeMetadataTask(task);
  }

  Future<void> _search() async {
    _searchCancel?.cancel();
    final token = _searchCancel = CancelToken();
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = '';
      _results = [];
      _searched = false;
      // Keep the selected file and its episode identity while searching.
    });
    try {
      final results = await widget.model.searchBangumi(
        _input.text,
        cancel: token,
      );
      if (!mounted || token.cancelled) return;
      setState(() {
        _results = results;
        _searched = true;
      });
    } on Cancelled {
      // Search has no mutations and can stop when the sheet is closed.
    } catch (error) {
      if (mounted && !token.cancelled) {
        setState(() => _error = safeFailure(error).message);
      }
    } finally {
      if (mounted && !token.cancelled) setState(() => _searching = false);
    }
  }

  void _recognize() {
    final records = _records;
    if (records.isEmpty) {
      setState(() => _error = '没有可识别的视频，请从视频或作品详情打开。');
      return;
    }
    FocusScope.of(context).unfocus();
    _searchCancel?.cancel();
    setState(() {
      _searching = false;
      _error = '';
      _results = [];
      _searched = false;
      _attachTask(widget.model.startMetadataTask(records, ai: true));
    });
  }

  void _apply(Map<String, dynamic> candidate) {
    final useSeason = candidate['mediaType'] != 'movie';
    final number = int.tryParse(_season.text.trim());
    if (useSeason && (number == null || number < 0 || number > 999)) {
      setState(() => _error = '请输入有效季度，特别篇使用 0。');
      return;
    }
    final selectedIndex = _recordIndexes[_resultRecordId];
    final records = selectedIndex == null
        ? _records
        : [_records[selectedIndex]];
    if (records.isEmpty) {
      setState(() => _error = '没有可匹配的视频，请重新打开作品详情。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _error = '';
      final parent = _task;
      final selection = widget.model.startMetadataSelectionTask(
        records,
        candidate,
        season: useSeason ? '$number' : '',
        identity: _identity,
        parentTask: parent,
      );
      if (parent == null) {
        _attachTask(selection);
      } else {
        _advanceAfterId = _resultRecordId;
      }
    });
  }

  Widget _candidate(Map<String, dynamic> result) {
    final name = '${result['name_cn'] ?? ''}'.isNotEmpty
        ? '${result['name_cn']}'
        : '${result['name'] ?? ''}';
    final original = '${result['name'] ?? ''}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          result['provider'] == 'tmdb' ? 'TMDB' : 'Bangumi',
          if (original.isNotEmpty && original != name) original,
          if (result['provider'] == 'tmdb')
            result['mediaType'] == 'movie' ? '电影' : '剧集',
          if ('${result['date'] ?? ''}'.isNotEmpty) '${result['date']}',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: _busy ? null : () => _apply(result),
    );
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final work = _workTask;
    final selection = task?.selectionTask;
    final selectedId = _resultRecordId;
    final selectionApplies =
        selectedId != null && selection?.containsMedia(selectedId) == true;
    final error = _error.isNotEmpty
        ? _error
        : selectionApplies
        ? selection!.error
        : _searched ||
              _searching ||
              (selectedId != null && task?.isMatched(selectedId) == true)
        ? ''
        : task?.error ?? '';
    final selectedIndex = _recordIndexes[_resultRecordId] ?? 0;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(0.0, constraints.maxHeight - bottom);
        return AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: bottom),
          child: ConstrainedBox(
            key: const ValueKey('metadata-match-sheet'),
            constraints: BoxConstraints(
              maxHeight: math.min(680.0, available * .94),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 34,
                    height: 4,
                    decoration: LibraryStyles.of(context).dragHandle,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '匹配影视资料',
                            style: LibraryStyles.of(context).detailsTitle,
                          ),
                        ),
                        if (_records.length > 1)
                          Text(
                            '${_records.length} 个视频',
                            style: AppStyles.of(context).muted,
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      key: const ValueKey('metadata-match-content'),
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: _results.length + 1,
                      itemBuilder: (context, index) {
                        if (index > 0) return _candidate(_results[index - 1]);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (task != null && _records.isNotEmpty) ...[
                              Row(
                                children: [
                                  IconButton(
                                    tooltip: '上一个',
                                    onPressed: selectedIndex > 0
                                        ? () => _selectRecord(
                                            _records[selectedIndex - 1].id,
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_left_rounded,
                                    ),
                                  ),
                                  Expanded(
                                    child: TextButton(
                                      key: const ValueKey(
                                        'metadata-record-choice',
                                      ),
                                      onPressed: _records.length > 1
                                          ? _chooseRecord
                                          : null,
                                      child: Text(
                                        '${selectedIndex + 1}/${_records.length}  ${_resultName(_resultRecordId!)}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '下一个',
                                    onPressed:
                                        selectedIndex + 1 < _records.length
                                        ? () => _selectRecord(
                                            _records[selectedIndex + 1].id,
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                  ),
                                  if (task.isMatched(_resultRecordId!))
                                    IconButton(
                                      tooltip: '删除识别记录',
                                      onPressed: _busy ? null : _removeRecord,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_loading) const LinearProgressIndicator(),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _input,
                                    enabled: !_busy,
                                    decoration: const InputDecoration(
                                      labelText: '作品名称',
                                    ),
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: (_) {
                                      if (!_busy) _search();
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 72,
                                  child: TextField(
                                    controller: _season,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: '季度',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Tooltip(
                                  message: '搜索资料',
                                  child: FilledButton.icon(
                                    onPressed: _busy ? null : _search,
                                    icon: const Icon(
                                      Icons.search_rounded,
                                      size: LibraryStyles.iconButton,
                                    ),
                                    label: const Text('搜索'),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _busy ? null : _recognize,
                                  icon: const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: LibraryStyles.iconButton,
                                  ),
                                  label: const Text('AI 自动识别'),
                                ),
                              ],
                            ),
                            if (task != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                key: const ValueKey('metadata-task-status'),
                                padding: const EdgeInsets.all(8),
                                decoration: LibraryStyles.of(
                                  context,
                                ).taskStatus,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(work?.status ?? task.status),
                                    const SizedBox(height: 4),
                                    Text(
                                      '已处理 ${task.completed}/${task.total} · 已匹配 ${task.matched} · 失败 ${task.failed}',
                                      style: AppStyles.of(context).caption,
                                    ),
                                    if (work?.running == true) ...[
                                      const SizedBox(height: 8),
                                      LinearProgressIndicator(
                                        value: work!.total > 0
                                            ? work.completed / work.total
                                            : null,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            if (_searching)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: LinearProgressIndicator(),
                              ),
                            if (error.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  error,
                                  style: AppStyles.of(context).error,
                                ),
                              ),
                            if (_identity != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  [
                                    '识别：${_identity!.name}',
                                    if (_identity!.season.isNotEmpty &&
                                        _identity!.season != '1')
                                      _identity!.season == '0'
                                          ? '特别篇'
                                          : '第 ${_identity!.season} 季',
                                    if (_identity!.episode.isNotEmpty)
                                      '第 ${_identity!.episode} 集',
                                  ].join(' · '),
                                ),
                              ),
                            if (_searched && _results.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('未找到作品，可尝试其他译名或 AI 自动识别。'),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                        if (task != null)
                          TextButton(
                            onPressed: _removeTask,
                            child: const Text('删除任务'),
                          ),
                        if (work?.running == true) ...[
                          TextButton(
                            onPressed: () =>
                                widget.model.cancelMetadataTask(work!),
                            child: const Text('取消任务'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('后台识别'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
