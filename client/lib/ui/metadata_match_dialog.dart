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
  bool autoAi = false,
}) => showGlassBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _MetadataMatchSheet(
    model: model,
    title: title,
    season: season,
    mediaIds: mediaIds,
    autoAi: autoAi,
  ),
);

class _MetadataMatchSheet extends StatefulWidget {
  final AppModel model;
  final String title, season;
  final Set<String>? mediaIds;
  final bool autoAi;
  const _MetadataMatchSheet({
    required this.model,
    required this.title,
    required this.season,
    this.mediaIds,
    this.autoAi = false,
  });
  @override
  State<_MetadataMatchSheet> createState() => _MetadataMatchSheetState();
}

class _MetadataMatchSheetState extends State<_MetadataMatchSheet> {
  late final _input = TextEditingController(text: widget.title);
  late final _season = TextEditingController(
    text: widget.season.isEmpty ? '1' : widget.season,
  );
  MetadataTask? _task;
  CancelToken? _searchCancel;
  AiMediaIdentity? _identity;
  String? _resultRecordId;
  AiMetadataMatch? _shownMatch;
  List<Map<String, dynamic>> _results = [];
  String _error = '';
  bool _searching = false, _searched = false;
  bool get _busy => _searching || (_task?.running ?? false);

  List<SyncRecord> get _records => widget.model.media
      .where(
        (record) => widget.mediaIds != null
            ? widget.mediaIds!.contains(record.id)
            : '${record.data['series']}' == widget.title &&
                  '${record.data['season'] ?? ''}' == widget.season,
      )
      .toList();

  @override
  void initState() {
    super.initState();
    final existing = widget.model.metadataTaskFor(
      _records.map((record) => record.id).toSet(),
    );
    if (existing != null) _attachTask(existing);
    if (widget.autoAi && existing?.running != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recognize();
      });
    }
  }

  @override
  void dispose() {
    // The model owns recognition and application jobs. Leaving this sheet only
    // stops a transient search and detaches its progress listener.
    _searchCancel?.cancel();
    _task?.removeListener(_taskChanged);
    _input.dispose();
    _season.dispose();
    super.dispose();
  }

  void _attachTask(MetadataTask task) {
    _task?.removeListener(_taskChanged);
    _task = task;
    _shownMatch = null;
    _resultRecordId = null;
    task.addListener(_taskChanged);
    _readTask();
  }

  void _readTask() {
    final task = _task;
    if (task == null || task.results.isEmpty) return;
    if (!task.results.containsKey(_resultRecordId)) {
      _resultRecordId =
          task.results.entries
              .where((entry) => entry.value.subject == null)
              .firstOrNull
              ?.key ??
          task.results.keys.first;
    }
    final match = task.results[_resultRecordId];
    if (match == null || identical(match, _shownMatch)) return;
    _shownMatch = match;
    _identity = match.identity;
    _input.text = match.identity.name;
    _season.text = match.identity.season.isEmpty ? '1' : match.identity.season;
    _results = match.candidates;
    _searched = true;
  }

  void _taskChanged() {
    if (mounted) setState(_readTask);
  }

  String _resultName(String id) {
    final record = widget.model.store.get('media', id);
    return record == null ? '视频已移除' : widget.model.metadataFileName(record);
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
      _identity = null;
      _resultRecordId = null;
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
    final records = _records
        .where(
          (record) => _resultRecordId == null || record.id == _resultRecordId,
        )
        .toList();
    if (records.isEmpty) {
      setState(() => _error = '没有可匹配的视频，请重新打开作品详情。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _error = '';
      _attachTask(
        widget.model.startMetadataSelectionTask(
          records,
          candidate,
          season: useSeason ? '$number' : '',
          identity: _identity,
        ),
      );
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
    final error = _error.isNotEmpty ? _error : task?.error ?? '';
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
                  const SizedBox(height: 10),
                  Container(
                    width: 34,
                    height: 4,
                    decoration: LibraryStyles.of(context).dragHandle,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
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
                    child: ListView(
                      key: const ValueKey('metadata-match-content'),
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      children: [
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
                            const SizedBox(width: 10),
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
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
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
                          const SizedBox(height: 14),
                          Container(
                            key: const ValueKey('metadata-task-status'),
                            padding: const EdgeInsets.all(12),
                            decoration: LibraryStyles.of(context).taskStatus,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(task.status),
                                const SizedBox(height: 4),
                                Text(
                                  '已处理 ${task.completed}/${task.total} · 已匹配 ${task.matched} · 失败 ${task.failed}',
                                  style: AppStyles.of(context).caption,
                                ),
                                if (task.running) ...[
                                  const SizedBox(height: 10),
                                  LinearProgressIndicator(
                                    value: task.total > 0
                                        ? task.completed / task.total
                                        : null,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                        if (_searching)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(),
                          ),
                        if (error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              error,
                              style: AppStyles.of(context).error,
                            ),
                          ),
                        if ((task?.results.length ?? 0) > 1)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(
                                'metadata-result:${task!.id}:$_resultRecordId',
                              ),
                              initialValue: _resultRecordId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '查看视频识别结果',
                              ),
                              items: task.results.keys
                                  .map(
                                    (id) => DropdownMenuItem(
                                      value: id,
                                      child: Text(
                                        _resultName(id),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (id) => setState(() {
                                _resultRecordId = id;
                                _shownMatch = null;
                                _readTask();
                              }),
                            ),
                          ),
                        if (_identity != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
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
                            padding: EdgeInsets.only(top: 12),
                            child: Text('未找到作品，可尝试其他译名或 AI 自动识别。'),
                          ),
                        ..._results.map(_candidate),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                        if (task?.running == true) ...[
                          TextButton(
                            onPressed: () =>
                                widget.model.cancelMetadataTask(task!),
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
