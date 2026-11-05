import 'dart:async';

import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../data/app_model.dart';
import '../data/offline_downloads.dart';
import 'artwork_lifecycle.dart';
import 'glass.dart';
import 'offline_download_controls.dart';
import 'theme/library_styles.dart';

Future<void> showDownloadTasks(BuildContext context, AppModel model) =>
    showGlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DownloadTasksSheet(model: model),
    );

/// A stable shell action: byte progress never rebuilds the surrounding page.
class DownloadTasksButton extends StatelessWidget {
  final AppModel model;
  final EdgeInsetsGeometry padding;
  const DownloadTasksButton({
    super.key,
    required this.model,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) => _DownloadValue<(int, bool)>(
    downloads: model.downloads,
    select: (downloads) {
      final unfinished =
          downloads.activeCount + downloads.pausedCount + downloads.failedCount;
      return (unfinished, unfinished + downloads.completedCount > 0);
    },
    builder: (context, state) => !state.$2
        ? const SizedBox.shrink()
        : Padding(
            padding: padding,
            child: FloatingActionButton.small(
              key: const ValueKey('download-tasks-button'),
              // Shell shortcuts can overlap their outgoing Scaffold animation
              // during rapid route changes and do not need Hero flights.
              heroTag: null,
              tooltip: '下载任务',
              onPressed: () => showDownloadTasks(context, model),
              child: Badge(
                isLabelVisible: state.$1 > 0,
                label: Text(state.$1 > 99 ? '99+' : '${state.$1}'),
                child: const Icon(Icons.download_rounded),
              ),
            ),
          ),
  );
}

class DownloadTasksSheet extends StatefulWidget {
  final AppModel model;
  const DownloadTasksSheet({super.key, required this.model});

  @override
  State<DownloadTasksSheet> createState() => _DownloadTasksSheetState();
}

class _DownloadTasksSheetState extends State<DownloadTasksSheet> {
  bool _loading = false;
  bool _visible = true, _loadDirty = false;
  String _error = '';
  int _loadRevision = 0;
  OfflineDownloadSelection? _selection;
  final _selected = <String>{};
  bool _allSelected = false, _batchBusy = false;
  int get _selectedCount => _selection == null
      ? 0
      : _allSelected
      ? _selection!.ids.length - _selected.length
      : _selected.length;
  OfflineDownloads get downloads => widget.model.downloads;
  bool get _active => _visible && ArtworkLifecycle.instance.value;

  @override
  void initState() {
    super.initState();
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active) _loadDirty = false;
  }

  void _lifecycleChanged() {
    if (_active && _loadDirty) setState(() => _loadDirty = false);
  }

  void _loaded(VoidCallback update) {
    if (_active) {
      setState(update);
    } else {
      update();
      _loadDirty = true;
    }
  }

  @override
  void didUpdateWidget(DownloadTasksSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      _releaseSelection(oldWidget.model.downloads);
      _load();
    }
  }

  void _releaseSelection(OfflineDownloads owner) {
    final selection = _selection;
    _selection = null;
    _selected.clear();
    _allSelected = false;
    if (selection != null) {
      unawaited(owner.releaseSelection(selection).catchError((Object _) {}));
    }
  }

  Future<void> _startSelection() async {
    final owner = downloads;
    final selection = await owner.captureSelection();
    if (!mounted || owner != downloads || !_active) {
      await owner.releaseSelection(selection);
      return;
    }
    setState(() {
      _selection = selection;
      _selected.clear();
      _allSelected = false;
    });
  }

  Future<void> _batch(OfflineDownloadBatchAction action) async {
    final selection = _selection;
    if (_batchBusy || selection == null || _selectedCount == 0) return;
    final owner = downloads;
    setState(() => _batchBusy = true);
    try {
      if (action == OfflineDownloadBatchAction.delete) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除 $_selectedCount 个下载任务？'),
            content: const Text(
              '将删除已下载的本机文件，取消未完成的下载并清理其临时文件。'
              '原始来源和媒体资料会保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      if (!mounted ||
          owner != downloads ||
          _selection != selection ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          !ArtworkLifecycle.instance.value) {
        return;
      }
      await owner.applyBatch(
        selection,
        action,
        all: _allSelected,
        ids: _selected,
      );
      if (mounted &&
          _selection == selection &&
          action == OfflineDownloadBatchAction.delete) {
        _releaseSelection(owner);
      }
    } finally {
      if (mounted) _loaded(() => _batchBusy = false);
    }
  }

  void _load() {
    final revision = ++_loadRevision;
    _error = '';
    _loading = widget.model.store.path != ':memory:' && !downloads.initialized;
    if (!_loading) return;
    unawaited(
      downloads.initialize().then<void>(
        (_) {
          if (!mounted || revision != _loadRevision) return;
          _loaded(() => _loading = false);
        },
        onError: (Object error) {
          if (!mounted || revision != _loadRevision) return;
          _loaded(() {
            _loading = false;
            _error = safeFailure(error).message;
          });
        },
      ),
    );
  }

  @override
  void dispose() {
    _releaseSelection(downloads);
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: GlassSheetBody(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selection == null ? '下载任务' : '已选 $_selectedCount',
                    style: LibraryStyles.of(context).taskTitle,
                  ),
                ),
                if (_selection != null) ...[
                  TextButton(
                    onPressed: _batchBusy
                        ? null
                        : () => setState(() {
                            _allSelected =
                                !_allSelected || _selected.isNotEmpty;
                            _selected.clear();
                          }),
                    child: Text(
                      _allSelected && _selected.isEmpty ? '取消全选' : '全选',
                    ),
                  ),
                  TextButton(
                    onPressed: _batchBusy
                        ? null
                        : () => setState(() => _releaseSelection(downloads)),
                    child: const Text('完成'),
                  ),
                ] else ...[
                  _DownloadValue<(int, int)>(
                    downloads: downloads,
                    select: (value) => (value.activeCount, value.pausedCount),
                    builder: (context, counts) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionIcon(
                          key: ValueKey((downloads, 'pause-all')),
                          tooltip: '全部暂停',
                          icon: Icons.pause_rounded,
                          action: counts.$1 > 0 ? downloads.pauseAll : null,
                        ),
                        _ActionIcon(
                          key: ValueKey((downloads, 'resume-all')),
                          tooltip: '全部继续',
                          icon: Icons.play_arrow_rounded,
                          action: counts.$2 > 0 ? downloads.resumeAll : null,
                        ),
                      ],
                    ),
                  ),
                  _ActionIcon(
                    tooltip: '多选',
                    icon: Icons.checklist_rounded,
                    action: _loading ? null : _startSelection,
                  ),
                ],
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('正在加载…'),
                  )
                : _error.isNotEmpty
                ? Align(
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error),
                    ),
                  )
                : _DownloadValue<int>(
                    downloads: downloads,
                    select: (value) => value.tasksRevision,
                    builder: (context, _) {
                      // The manager exposes a live read-only view. Freeze only
                      // on membership refresh so retained/covered lists cannot
                      // index a task removed before their next visible frame.
                      final ids =
                          _selection?.ids ??
                          List<String>.unmodifiable(downloads.taskIds);
                      if (ids.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无下载任务'),
                        );
                      }
                      return ListView.builder(
                        shrinkWrap: true,
                        key: const PageStorageKey('download-task-list'),
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: ids.length,
                        itemBuilder: (_, index) => _DownloadTaskRow(
                          key: ValueKey((
                            downloads,
                            ids[ids.length - 1 - index],
                          )),
                          model: widget.model,
                          id: ids[ids.length - 1 - index],
                          selected: _selection == null
                              ? null
                              : _allSelected !=
                                    _selected.contains(
                                      ids[ids.length - 1 - index],
                                    ),
                          onSelect: _batchBusy
                              ? null
                              : () => setState(() {
                                  final id = ids[ids.length - 1 - index];
                                  if (!_selected.add(id)) _selected.remove(id);
                                }),
                        ),
                      );
                    },
                  ),
          ),
          if (_selection != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final action in OfflineDownloadBatchAction.values)
                    _ActionIcon(
                      tooltip: switch (action) {
                        OfflineDownloadBatchAction.pause => '暂停所选',
                        OfflineDownloadBatchAction.resume => '继续所选',
                        OfflineDownloadBatchAction.delete => '删除所选',
                      },
                      icon: switch (action) {
                        OfflineDownloadBatchAction.pause => Icons.pause_rounded,
                        OfflineDownloadBatchAction.resume =>
                          Icons.play_arrow_rounded,
                        OfflineDownloadBatchAction.delete =>
                          Icons.delete_outline_rounded,
                      },
                      action: _batchBusy || _selectedCount == 0
                          ? null
                          : () => _batch(action),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

typedef _TaskView = ({
  String name,
  String error,
  String localPath,
  OfflineDownloadStatus status,
  int received,
  int total,
  bool userPaused,
  bool isDirectory,
  int discoveredFiles,
});

class _DownloadTaskRow extends StatelessWidget {
  final AppModel model;
  final String id;
  final bool? selected;
  final VoidCallback? onSelect;
  const _DownloadTaskRow({
    super.key,
    required this.model,
    required this.id,
    this.selected,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) => _DownloadValue<_TaskView?>(
    downloads: model.downloads,
    select: (downloads) {
      final entry = downloads.entryFor(id);
      return entry == null
          ? null
          : (
              name: entry.name,
              error: entry.error,
              localPath: entry.localPath,
              status: entry.status,
              received: entry.received,
              total: entry.total,
              userPaused: entry.userPaused,
              isDirectory: entry.isDirectory,
              discoveredFiles: entry.discoveredFiles,
            );
    },
    builder: (context, entry) {
      if (entry == null) return const SizedBox.shrink();
      final manager = model.downloads;
      final completed = entry.status == OfflineDownloadStatus.completed;
      final paused = entry.status == OfflineDownloadStatus.paused;
      final failed = entry.status == OfflineDownloadStatus.failed;
      final progress = entry.total > 0
          ? (entry.received / entry.total).clamp(0.0, 1.0)
          : 0.0;
      final status = switch (entry.status) {
        OfflineDownloadStatus.queued => entry.isDirectory ? '等待读取文件夹' : '等待下载',
        OfflineDownloadStatus.downloading =>
          entry.isDirectory ? '读取文件夹' : '下载中',
        OfflineDownloadStatus.paused => '已暂停',
        OfflineDownloadStatus.failed => entry.isDirectory ? '读取失败' : '下载失败',
        OfflineDownloadStatus.completed => '已下载',
      };
      final size = completed
          ? _bytes(entry.total)
          : '${_bytes(entry.received)} / ${entry.total > 0 ? _bytes(entry.total) : '—'}';
      return Padding(
        key: ValueKey('download-task:$id'),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selected != null)
              Checkbox(
                key: ValueKey('download-task-select:$id'),
                value: selected,
                onChanged: onSelect == null ? null : (_) => onSelect!(),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(
                entry.isDirectory
                    ? Icons.folder_outlined
                    : completed
                    ? Icons.download_done_rounded
                    : paused
                    ? Icons.pause_circle_outline_rounded
                    : failed
                    ? Icons.error_outline_rounded
                    : Icons.downloading_rounded,
                size: 20,
                color: completed ? GlassPalette.of(context).accent : null,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppStyles.of(context).title14,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.isDirectory
                        ? '$status · ${entry.discoveredFiles} 个文件'
                        : '$status · $size${!completed && entry.total > 0 ? ' · ${(progress * 100).floor()}%' : ''}',
                    style: AppStyles.of(context).micro,
                  ),
                  if (!completed && !entry.isDirectory)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: LibraryStyles.progressHeight,
                        borderRadius: LibraryStyles.progressRadius,
                      ),
                    ),
                  if (failed && entry.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        entry.error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppStyles.of(context).errorCaption,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (selected != null)
              const SizedBox(width: 4)
            else if (!completed) ...[
              _ActionIcon(
                tooltip: paused
                    ? '继续下载'
                    : failed
                    ? '重试下载'
                    : '暂停下载',
                icon: paused
                    ? Icons.play_arrow_rounded
                    : failed
                    ? Icons.refresh_rounded
                    : Icons.pause_rounded,
                action: paused
                    ? () => manager.resume(id)
                    : failed
                    ? () => manager.retry(id)
                    : () => manager.pause(id),
              ),
              _ActionIcon(
                tooltip: '取消下载',
                icon: Icons.close_rounded,
                action: () => manager.cancel(id),
              ),
            ] else ...[
              _ActionIcon(
                tooltip: '保存位置',
                icon: Icons.folder_open_outlined,
                action: () =>
                    showDownloadedFileLocation(context, entry.localPath),
              ),
              _ActionIcon(
                tooltip: '删除下载文件',
                icon: Icons.delete_outline_rounded,
                action: () => _deleteDownloadedFile(context, model, id),
              ),
            ],
          ],
        ),
      );
    },
  );
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

Future<void> _deleteDownloadedFile(
  BuildContext context,
  AppModel model,
  String id,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除下载文件？'),
      content: const Text('将删除本机下载的文件，保留原始来源和影视资料。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) await model.deleteDownload(id);
}

class _ActionIcon extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final Future<void> Function()? action;
  const _ActionIcon({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.action,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _busy = false, _visible = true, _dirty = false;
  bool get _active => _visible && ArtworkLifecycle.instance.value;

  @override
  void initState() {
    super.initState();
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
  }

  void _lifecycleChanged() {
    if (_active && _dirty) setState(() => _dirty = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active) _dirty = false;
  }

  Future<void> _run() async {
    final action = widget.action;
    if (_busy || action == null) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted && _active) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
      }
    } finally {
      if (mounted) {
        _busy = false;
        if (_active) {
          setState(() {});
        } else {
          _dirty = true;
        }
      }
    }
  }

  @override
  void dispose() {
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: IconButton(
      tooltip: widget.tooltip,
      icon: Icon(widget.icon, size: 20),
      onPressed: _busy || widget.action == null ? null : _run,
    ),
  );
}

/// Select immutable, small values. Offscreen notifications only mark dirty;
/// lifecycle resume refreshes once, even if Android delivered no paused frame.
class _DownloadValue<T> extends StatefulWidget {
  final OfflineDownloads downloads;
  final T Function(OfflineDownloads) select;
  final Widget Function(BuildContext, T) builder;
  const _DownloadValue({
    required this.downloads,
    required this.select,
    required this.builder,
  });

  @override
  State<_DownloadValue<T>> createState() => _DownloadValueState<T>();
}

class _DownloadValueState<T> extends State<_DownloadValue<T>> {
  late T _value;
  Widget? _built;
  bool _visible = true, _dirty = false;
  bool get _active => _visible && ArtworkLifecycle.instance.value;

  @override
  void initState() {
    super.initState();
    _value = widget.select(widget.downloads);
    widget.downloads.addListener(_changed);
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active && _dirty) {
      _dirty = false;
      _value = widget.select(widget.downloads);
      _built = null;
    }
  }

  @override
  void didUpdateWidget(_DownloadValue<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloads != widget.downloads) {
      oldWidget.downloads.removeListener(_changed);
      widget.downloads.addListener(_changed);
      _value = widget.select(widget.downloads);
      _built = null;
    } else if (_active) {
      _value = widget.select(widget.downloads);
      _built = null;
    } else {
      _dirty = true;
    }
  }

  void _changed() {
    if (!_active) {
      _dirty = true;
      return;
    }
    final next = widget.select(widget.downloads);
    if (next == _value) return;
    setState(() {
      _value = next;
      _built = null;
    });
  }

  void _lifecycleChanged() {
    if (_active) {
      setState(() {
        _value = widget.select(widget.downloads);
        _dirty = false;
        _built = null;
      });
    } else {
      _dirty = true;
    }
  }

  @override
  void dispose() {
    widget.downloads.removeListener(_changed);
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active && _built != null) return _built!;
    return _built = widget.builder(context, _value);
  }
}
