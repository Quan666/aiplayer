import 'dart:async';

import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../data/app_model.dart';
import '../data/offline_downloads.dart';
import 'artwork_lifecycle.dart';
import 'glass.dart';
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
    if (oldWidget.model != widget.model) _load();
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
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .68,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '下载任务',
                    style: LibraryStyles.of(context).taskTitle,
                  ),
                ),
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
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: Text('正在加载…'))
                : _error.isNotEmpty
                ? Center(
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
                      final ids = List<String>.unmodifiable(downloads.taskIds);
                      if (ids.isEmpty) {
                        return const Center(child: Text('暂无下载任务'));
                      }
                      return ListView.builder(
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
                        ),
                      );
                    },
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
  const _DownloadTaskRow({super.key, required this.model, required this.id});

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
                        ? '$status · ${entry.discoveredFiles} 个视频'
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
            if (!completed) ...[
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
            ] else
              _ActionIcon(
                tooltip: '删除离线视频',
                icon: Icons.delete_outline_rounded,
                action: () => _deleteDownloadedFile(context, model, id),
              ),
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
      title: const Text('删除离线视频？'),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
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
