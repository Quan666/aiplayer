import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/offline_downloads.dart';
import '../data/playback_source.dart';
import '../data/store.dart';
import 'glass.dart';

typedef _SourceLabel = ({String text, IconData icon});

final _sourceLabels = Expando<_SourceLabels>();

class _SourceLabels {
  Object? revision;
  final labels = <String, _SourceLabel>{};

  _SourceLabel read(AppModel model, String id) {
    if (id == 'local') {
      return (text: '本地文件', icon: Icons.folder_outlined);
    }
    if (id.isEmpty) return (text: '未关联', icon: Icons.link_off_rounded);
    final next = (
      model.store.localKeyRevision('sources'),
      model.store.localPrefixRevision('externalSource:'),
    );
    if (revision != next) {
      revision = next;
      labels.clear();
      for (final source in model.sources) {
        if (source['id'] case final String sourceId) {
          labels[sourceId] = _label(source);
        }
      }
    }
    return labels.putIfAbsent(id, () {
      final source = model.store.local('externalSource:$id');
      return source is Map
          ? _label(source)
          : (text: '来源不可用', icon: Icons.cloud_off_outlined);
    });
  }

  _SourceLabel _label(Map source) {
    final protocol = switch (source['kind']) {
      'smb' => 'SMB',
      'webdav' => 'WebDAV',
      'http' => 'HTTP',
      _ => '网络来源',
    };
    final name = '${source['label'] ?? ''}'.trim();
    return (
      text: name.isEmpty || name.toLowerCase() == protocol.toLowerCase()
          ? protocol
          : '$protocol · $name',
      icon: Icons.dns_outlined,
    );
  }
}

_SourceLabel _label(AppModel model, String source) =>
    (_sourceLabels[model] ??= _SourceLabels()).read(model, source);

bool _matches(OfflineDownload? download, Map? location) =>
    download?.isComplete == true &&
    (location == null ||
        (download!.sourceId == location['source'] &&
            download.remotePath == location['path'] &&
            download.bindingRevision == (location['previewRevision'] ?? '')));

/// Snapshot preparation and completed membership suffice for this picker.
/// File validation happens on the download worker when playback is requested.
Future<MediaPlaybackChoice?> showMediaSourceSelection(
  BuildContext context, {
  required AppModel model,
  required SyncRecord item,
  CancelToken? cancel,
}) async {
  try {
    cancel?.check();
    if (model.store.path != ':memory:' && !model.downloads.initialized) {
      try {
        await model.downloads.initialize();
      } catch (error) {
        // The original file remains selectable when the download catalog fails.
        AppLog.instance.warning('离线下载', safeFailure(error).message);
      }
    }
    cancel?.check();
    final snapshot = await model.loadLibrarySnapshot(cancel: cancel);
    if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return null;
    }
    final current = snapshot.byId[item.id] ?? item;
    final options = snapshot.playbackOptionsFor(current);
    // The menu may have been opened just before a copy was removed.
    if (options.length < 2) return null;
    return await showGlassBottomSheet<MediaPlaybackChoice>(
      context: context,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                child: Row(
                  children: [
                    const Expanded(child: Text('版本与来源')),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheet),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: options.isEmpty
                    ? const Center(child: Text('没有可用的视频文件'))
                    : ListView.builder(
                        key: const ValueKey('media-source-selection'),
                        itemCount: options.length,
                        itemBuilder: (_, index) {
                          final option = options[index];
                          final source =
                              option.preference ==
                                  PlaybackSourcePreference.offline
                              ? (
                                  text: '本地 · 已下载',
                                  icon: Icons.download_done_rounded,
                                )
                              : _label(model, option.sourceId);
                          final name =
                              '${option.media.data['fileName'] ?? option.media.data['title'] ?? model.displayTitle(option.media)}';
                          final technical = option.technical.label;
                          return ListTile(
                            key: ValueKey(
                              'media-source:${option.media.id}:${option.preference.name}',
                            ),
                            leading: Icon(source.icon),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    technical.isEmpty ? name : technical,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (index == 0) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '默认',
                                    style: AppStyles.of(context).micro.copyWith(
                                      color: GlassPalette.of(context).accent,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  source.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (technical.isNotEmpty)
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (option.displayPath.isNotEmpty &&
                                    option.displayPath != name)
                                  Text(
                                    option.displayPath,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                            onTap: () => Navigator.pop(sheet, option.choice),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  } on Cancelled {
    return null;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
    }
    return null;
  }
}

/// A compact, event-driven indication of the default playback source.
class MediaSourceBadge extends StatefulWidget {
  final AppModel model;
  final SyncRecord item;
  final String? sourceId;
  const MediaSourceBadge({
    super.key,
    required this.model,
    required this.item,
    this.sourceId,
  });

  @override
  State<MediaSourceBadge> createState() => _MediaSourceBadgeState();
}

class _MediaSourceBadgeState extends State<MediaSourceBadge>
    with WidgetsBindingObserver {
  Object? _revision;
  late _SourceLabel _value;
  int _completed = -1;
  bool _visible = true, _foreground = true, _dirty = false;
  bool get _active => _visible && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _listen();
    _refresh();
  }

  void _listen() {
    widget.model.addListener(_changed);
    widget.model.downloads.addListener(_downloadsChanged);
  }

  void _downloadsChanged() {
    if (_completed == widget.model.downloads.completedRevision) return;
    _changed();
  }

  void _refresh() {
    final model = widget.model;
    _completed = model.downloads.completedRevision;
    _revision = (
      _completed,
      model.store.localKeyRevision('location:${widget.item.id}'),
      model.store.localKeyRevision('sources'),
      model.store.localPrefixRevision('externalSource:'),
    );
    final location = model.store.local('location:${widget.item.id}');
    _value =
        _matches(
          model.downloads.entryFor(widget.item.id),
          location is Map ? location : null,
        )
        ? (text: '本地 · 已下载', icon: Icons.download_done_rounded)
        : _label(
            model,
            '${(location is Map ? location['source'] : widget.sourceId) ?? ''}',
          );
    _dirty = false;
  }

  void _changed() {
    if (!_active) {
      _dirty = true;
      return;
    }
    final model = widget.model;
    final next = (
      model.downloads.completedRevision,
      model.store.localKeyRevision('location:${widget.item.id}'),
      model.store.localKeyRevision('sources'),
      model.store.localPrefixRevision('externalSource:'),
    );
    if (_revision == next && !_dirty) return;
    final previous = _value;
    _refresh();
    if (previous != _value) setState(() {});
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_active && _dirty) _changed();
  }

  @override
  void didUpdateWidget(MediaSourceBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_changed);
      oldWidget.model.downloads.removeListener(_downloadsChanged);
      _listen();
    }
    if (oldWidget.model != widget.model ||
        oldWidget.item.id != widget.item.id ||
        oldWidget.sourceId != widget.sourceId) {
      if (_active) {
        _refresh();
      } else {
        _dirty = true;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.model.removeListener(_changed);
    widget.model.downloads.removeListener(_downloadsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _value.text,
    child: Container(
      key: ValueKey('media-source-badge:${widget.item.id}'),
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: GlassPalette.of(context).field,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_value.icon, size: 12),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _value.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.of(context).micro,
            ),
          ),
        ],
      ),
    ),
  );
}
