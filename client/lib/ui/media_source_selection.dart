import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
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
