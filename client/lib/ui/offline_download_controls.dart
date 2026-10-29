import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../data/app_model.dart';
import '../data/offline_downloads.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'artwork_lifecycle.dart';
import 'glass.dart';

void _downloadFailure(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
}

/// A small, independently updated action shared by source and library rows.
/// Progress never rebuilds the episode list or its metadata/artwork.
class OfflineDownloadButton extends StatefulWidget {
  final AppModel model;
  final SyncRecord item;
  final String? sourceId;
  final SourceEntry? sourceEntry;

  const OfflineDownloadButton({
    super.key,
    required this.model,
    required this.item,
    this.sourceId,
    this.sourceEntry,
  });

  @override
  State<OfflineDownloadButton> createState() => _OfflineDownloadButtonState();
}

class _OfflineDownloadButtonState extends State<OfflineDownloadButton> {
  OfflineDownload? _entry;
  String? _registeredId;
  Object? _revision, _bindingRevision;
  _DownloadBinding? _binding;
  bool _stale = false;
  bool _canDownload = false, _busy = false, _visible = true, _dirty = false;
  bool _bindingDirty = true;
  AppModel get model => widget.model;
  String get _id => _registeredId ?? widget.item.id;
  bool get _active => _visible && ArtworkLifecycle.instance.value;
  Object get _currentBindingRevision => widget.sourceEntry == null
      ? model.store.localKeyRevision('location:${widget.item.id}')
      : model.store.locationRevision;

  @override
  void initState() {
    super.initState();
    _refresh();
    model.downloads.addListener(_changed);
    model.addListener(_modelChanged);
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active && _dirty) _refresh();
  }

  @override
  void didUpdateWidget(OfflineDownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.downloads.removeListener(_changed);
      oldWidget.model.removeListener(_modelChanged);
      model.downloads.addListener(_changed);
      model.addListener(_modelChanged);
    }
    if (oldWidget.model != model ||
        oldWidget.item.id != widget.item.id ||
        oldWidget.sourceEntry?.path != widget.sourceEntry?.path ||
        oldWidget.sourceId != widget.sourceId) {
      _registeredId = null;
    }
    _bindingDirty = true;
    if (_active) {
      _refresh();
    } else {
      _dirty = true;
    }
  }

  void _modelChanged() {
    if (_bindingRevision == _currentBindingRevision) return;
    _bindingDirty = true;
    _changed();
  }

  void _lifecycleChanged() {
    if (_active && _dirty) _changed();
  }

  void _changed() {
    if (!_active) {
      _dirty = true;
      return;
    }
    final previous = _revision;
    final dirty = _dirty;
    _refresh();
    if (dirty || previous != _revision) setState(() {});
  }

  void _refresh() {
    if (_bindingDirty) {
      final sourceId = widget.sourceId, sourceEntry = widget.sourceEntry;
      if (sourceId != null && sourceEntry != null) {
        _registeredId = model.sourceMedia(sourceId, sourceEntry.path)?.id;
      }
      final location = model.store.local('location:$_id');
      _binding = sourceId != null && sourceEntry != null
          ? (
              sourceId,
              sourceEntry.path,
              location is Map ? '${location['previewRevision'] ?? ''}' : '',
            )
          : _downloadBinding(location);
      _canDownload = sourceId != null && sourceEntry != null
          ? sourceId != 'local' && !sourceEntry.directory
          : model.canDownload(widget.item);
      _bindingDirty = false;
      _bindingRevision = _currentBindingRevision;
    }
    _entry = model.downloads.entryFor(_id);
    _stale = _entry != null && !_matchesDownloadBinding(_entry!, _binding);
    _revision = (
      _id,
      _canDownload,
      _entry?.status,
      _entry?.received,
      _entry?.total,
      _entry?.error,
      _entry?.userPaused,
      _stale,
    );
    _dirty = false;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _downloadFailure(context, error);
    } finally {
      if (mounted) {
        _busy = false;
        if (_active) {
          setState(_refresh);
        } else {
          _dirty = true;
        }
      }
    }
  }

  Future<void> _download() => _run(() async {
    final sourceId = widget.sourceId, entry = widget.sourceEntry;
    if (sourceId != null && entry != null) {
      await model.downloadSourceEntries(sourceId, [entry]);
    } else {
      await model.downloadMedia([widget.item]);
    }
  });

  Future<void> _action(String action) async {
    if (action == 'pause') return _run(() => model.downloads.pause(_id));
    if (action == 'resume') return _run(() => model.downloads.resume(_id));
    if (action == 'retry') return _run(() => model.downloads.retry(_id));
    if (action == 'cancel') return _run(() => model.downloads.cancel(_id));
    if (action != 'delete') return;
    final id = _id;
    final currentModel = model;
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
    if (confirmed == true && mounted && model == currentModel && _id == id) {
      await _run(() => currentModel.deleteDownload(id));
    }
  }

  @override
  void dispose() {
    model.downloads.removeListener(_changed);
    model.removeListener(_modelChanged);
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    if (entry == null) {
      return SizedBox(
        width: 40,
        height: 40,
        child: !_canDownload
            ? null
            : IconButton(
                key: ValueKey('download:$_id'),
                tooltip: '下载视频',
                onPressed: _busy ? null : _download,
                icon: const Icon(Icons.download_outlined, size: 20),
              ),
      );
    }
    final label = _stale
        ? '旧位置的下载'
        : switch (entry.status) {
            OfflineDownloadStatus.completed => '已下载',
            OfflineDownloadStatus.failed => '下载失败',
            OfflineDownloadStatus.paused => '下载已暂停',
            OfflineDownloadStatus.queued => '等待下载',
            OfflineDownloadStatus.downloading => '正在下载',
          };
    final progress = entry.total > 0
        ? (entry.received / entry.total).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      width: 40,
      height: 40,
      child: PopupMenuButton<String>(
        key: ValueKey('download-status:$_id'),
        tooltip:
            !_stale &&
                entry.status == OfflineDownloadStatus.downloading &&
                entry.total > 0
            ? '$label ${(progress * 100).floor()}%'
            : label,
        enabled: !_busy,
        padding: EdgeInsets.zero,
        onSelected: _action,
        icon: _stale
            ? const Icon(Icons.error_outline_rounded, size: 20)
            : entry.isComplete
            ? Icon(
                Icons.download_done_rounded,
                size: 20,
                color: GlassPalette.of(context).accent,
              )
            : entry.status == OfflineDownloadStatus.downloading
            ? SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2,
                ),
              )
            : Icon(
                entry.status == OfflineDownloadStatus.failed
                    ? Icons.error_outline_rounded
                    : Icons.downloading_rounded,
                size: 20,
              ),
        itemBuilder: (_) => [
          if (_stale)
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('视频位置已更改，请删除旧下载后重新下载。'),
            ),
          if (!_stale && entry.status == OfflineDownloadStatus.failed) ...[
            if (entry.error.isNotEmpty)
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  entry.error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const PopupMenuItem(value: 'retry', child: Text('重试下载')),
          ],
          if (!_stale && entry.status == OfflineDownloadStatus.paused)
            const PopupMenuItem(value: 'resume', child: Text('继续下载')),
          if (!_stale &&
              (entry.status == OfflineDownloadStatus.downloading ||
                  entry.status == OfflineDownloadStatus.queued))
            const PopupMenuItem(value: 'pause', child: Text('暂停下载')),
          if (!_stale && !entry.isComplete)
            const PopupMenuItem(value: 'cancel', child: Text('取消下载')),
          if (_stale || entry.isComplete)
            const PopupMenuItem(value: 'delete', child: Text('删除离线视频')),
        ],
      ),
    );
  }
}

typedef _DownloadBinding = (String?, String?, String);

_DownloadBinding? _downloadBinding(dynamic location) => location is Map
    ? (
        location['source'] as String?,
        location['path'] as String?,
        '${location['previewRevision'] ?? ''}',
      )
    : null;

bool _matchesDownloadBinding(
  OfflineDownload entry,
  _DownloadBinding? binding,
) =>
    binding == null ||
    (binding.$1 == entry.sourceId &&
        binding.$2 == entry.remotePath &&
        binding.$3 == entry.bindingRevision);

Future<void> showDownloadSelection(
  BuildContext context,
  AppModel model,
  List<SyncRecord> records,
) async {
  try {
    if (model.store.path != ':memory:' && !model.downloads.initialized) {
      await model.downloads.initialize();
    }
    final snapshot = await model.loadLibrarySnapshot();
    if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    await _showDownloadSelection(
      context,
      downloads: model.downloads,
      count: records.length,
      nameAt: (index) =>
          '${records[index].data['fileName'] ?? records[index].data['title'] ?? model.displayTitle(records[index])}',
      availabilityAt: (index) {
        final record = records[index];
        final source = snapshot.locations[record.id]?['source'];
        return _downloadAvailability(
          model.downloads.entryFor(record.id),
          available: !record.deleted && source is String && source != 'local',
          binding: _downloadBinding(snapshot.locations[record.id]),
        );
      },
      submit: (indices) =>
          model.downloadMedia([for (final index in indices) records[index]]),
    );
  } catch (error) {
    if (context.mounted) _downloadFailure(context, error);
  }
}

Future<void> showSourceDownloadSelection(
  BuildContext context,
  AppModel model,
  String sourceId,
  List<SourceEntry> entries,
) async {
  try {
    if (model.store.path != ':memory:' && !model.downloads.initialized) {
      await model.downloads.initialize();
    }
    final snapshot = await model.loadLibrarySnapshot();
    if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final known = snapshot.recordsBySource[sourceId] ?? const {};
    await _showDownloadSelection(
      context,
      downloads: model.downloads,
      count: entries.length,
      nameAt: (index) => entries[index].name,
      directoryAt: (index) => entries[index].directory,
      hint: entries.any((entry) => entry.directory) ? '文件夹包含所有子目录中的视频。' : null,
      availabilityAt: (index) {
        final entry = entries[index];
        if (entry.directory) {
          return sourceId == 'local'
              ? _DownloadAvailability.unavailable
              : _DownloadAvailability.available;
        }
        final record = known[entry.path.replaceAll('\\', '/')];
        return _downloadAvailability(
          record == null ? null : model.downloads.entryFor(record.id),
          available: sourceId != 'local',
          binding: (
            sourceId,
            entry.path,
            record == null
                ? ''
                : '${snapshot.locations[record.id]?['previewRevision'] ?? ''}',
          ),
        );
      },
      submit: (indices) => model.downloadSourceEntries(sourceId, [
        for (final index in indices) entries[index],
      ]),
    );
  } catch (error) {
    if (context.mounted) _downloadFailure(context, error);
  }
}

enum _DownloadAvailability { available, completed, busy, unavailable, stale }

_DownloadAvailability _downloadAvailability(
  OfflineDownload? entry, {
  required bool available,
  required _DownloadBinding? binding,
}) {
  if (entry != null && !_matchesDownloadBinding(entry, binding)) {
    return _DownloadAvailability.stale;
  }
  if (entry?.isComplete == true) return _DownloadAvailability.completed;
  if (entry?.isBusy == true) return _DownloadAvailability.busy;
  return available
      ? _DownloadAvailability.available
      : _DownloadAvailability.unavailable;
}

Future<void> _showDownloadSelection(
  BuildContext context, {
  required OfflineDownloads downloads,
  required int count,
  required String Function(int) nameAt,
  bool Function(int)? directoryAt,
  String? hint,
  required _DownloadAvailability Function(int) availabilityAt,
  required Future<void> Function(Set<int>) submit,
}) async {
  await showGlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DownloadSelection(
      downloads: downloads,
      count: count,
      nameAt: nameAt,
      directoryAt: directoryAt,
      hint: hint,
      availabilityAt: availabilityAt,
      submit: submit,
    ),
  );
}

class _DownloadSelection extends StatefulWidget {
  final OfflineDownloads downloads;
  final int count;
  final String Function(int) nameAt;
  final bool Function(int)? directoryAt;
  final String? hint;
  final _DownloadAvailability Function(int) availabilityAt;
  final Future<void> Function(Set<int>) submit;
  const _DownloadSelection({
    required this.downloads,
    required this.count,
    required this.nameAt,
    this.directoryAt,
    this.hint,
    required this.availabilityAt,
    required this.submit,
  });

  @override
  State<_DownloadSelection> createState() => _DownloadSelectionState();
}

class _DownloadSelectionState extends State<_DownloadSelection> {
  final _selected = <int>{};
  late int _completedRevision;
  bool _busy = false, _allSelected = false;
  bool _visible = true, _dirty = false;
  String _error = '';
  bool get _active => _visible && ArtworkLifecycle.instance.value;

  @override
  void initState() {
    super.initState();
    _completedRevision = widget.downloads.completedRevision;
    widget.downloads.addListener(_downloadsChanged);
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active && _dirty) _refreshCompletedSelection();
  }

  @override
  void didUpdateWidget(_DownloadSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloads == widget.downloads) return;
    oldWidget.downloads.removeListener(_downloadsChanged);
    widget.downloads.addListener(_downloadsChanged);
    _dirty = true;
    if (_active) _refreshCompletedSelection();
  }

  void _lifecycleChanged() {
    if (_active && _dirty) _downloadsChanged();
  }

  void _refreshCompletedSelection() {
    _completedRevision = widget.downloads.completedRevision;
    _selected.removeWhere((index) => !_available(index));
    _allSelected = false;
    _dirty = false;
  }

  void _downloadsChanged() {
    final revision = widget.downloads.completedRevision;
    // Transfer progress cannot change selection availability. Refresh only
    // when completed-file membership changes, including while this sheet is open.
    if (_completedRevision == revision && !_dirty) return;
    if (!_active) {
      _dirty = true;
      return;
    }
    setState(_refreshCompletedSelection);
  }

  @override
  void dispose() {
    widget.downloads.removeListener(_downloadsChanged);
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final selected = _selected.where(_available).toSet();
      if (selected.isNotEmpty) await widget.submit(Set.unmodifiable(selected));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = safeFailure(error).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _available(int index) =>
      widget.availabilityAt(index) == _DownloadAvailability.available;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                const Expanded(child: Text('选择下载')),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          if (_allSelected) {
                            _selected.clear();
                          } else {
                            _selected.clear();
                            _selected.addAll(
                              Iterable<int>.generate(
                                widget.count.clamp(0, 2000),
                              ).where(_available),
                            );
                          }
                          _error = '';
                          _allSelected = !_allSelected;
                        }),
                  child: Text(
                    _allSelected
                        ? '取消全选'
                        : widget.count > 2000
                        ? '选择前2000项'
                        : '全选',
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.hint!, style: AppStyles.of(context).caption),
              ),
            ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('download-selection-list'),
              itemCount: widget.count,
              itemBuilder: (_, index) {
                final availability = widget.availabilityAt(index);
                final available =
                    availability == _DownloadAvailability.available;
                return CheckboxListTile(
                  key: ValueKey('download-select:$index'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value:
                      availability == _DownloadAvailability.completed ||
                      (available && _selected.contains(index)),
                  secondary: switch (availability) {
                    _DownloadAvailability.available =>
                      widget.directoryAt?.call(index) == true
                          ? const Icon(Icons.folder_outlined, size: 20)
                          : null,
                    _DownloadAvailability.completed => const Icon(
                      Icons.download_done_rounded,
                      size: 20,
                    ),
                    _DownloadAvailability.busy => const Icon(
                      Icons.downloading_rounded,
                      size: 20,
                    ),
                    _DownloadAvailability.unavailable => const Icon(
                      Icons.block_outlined,
                      size: 20,
                    ),
                    _DownloadAvailability.stale => const Tooltip(
                      message: '旧位置的下载',
                      child: Icon(Icons.error_outline_rounded, size: 20),
                    ),
                  },
                  title: Text(
                    widget.nameAt(index),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: _busy || !available
                      ? null
                      : (value) => setState(() {
                          _allSelected = false;
                          if (value == true) {
                            if (_selected.length >= 2000) {
                              _error = '单次最多选择 2000 项。';
                              return;
                            }
                            _selected.add(index);
                          } else {
                            _selected.remove(index);
                          }
                          _error = '';
                        }),
                );
              },
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_error),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy || _selected.isEmpty ? null : _submit,
                icon: const Icon(Icons.download_rounded),
                label: Text(_busy ? '正在加入…' : '下载 (${_selected.length})'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
