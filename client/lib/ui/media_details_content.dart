import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../data/media_presentation.dart';
import '../data/media_technical_info.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'glass.dart';
import 'media_artwork.dart';
import 'media_details_header.dart';
import 'theme/library_styles.dart';

/// The complete details introduction used by library sheets and source folders.
/// Episodes remain outside this widget so both callers can build them lazily.
class MediaDetailsOverview extends StatelessWidget {
  final AppModel model;
  final MediaCollectionDetails details;
  final List<SyncRecord> records;
  final SyncRecord? latest;
  final ValueChanged<SyncRecord> onPlay;
  final VoidCallback? onMatch;
  final VoidCallback onSort;
  final ValueListenable<bool>? loading;

  const MediaDetailsOverview({
    super.key,
    required this.model,
    required this.details,
    required this.records,
    required this.latest,
    required this.onPlay,
    required this.onSort,
    this.onMatch,
    this.loading,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loading case final loading?)
        SizedBox(
          height: 6,
          child: Align(
            alignment: Alignment.topCenter,
            child: ValueListenableBuilder<bool>(
              valueListenable: loading,
              builder: (_, active, _) => active
                  ? const LinearProgressIndicator(
                      minHeight: LibraryStyles.progressHeight,
                    )
                  : const SizedBox(height: 2),
            ),
          ),
        ),
      MediaDetailsHeader(
        model: model,
        details: details,
        records: records,
        onMatch: onMatch,
      ),
      MediaDetailsContinue(model: model, latest: latest, onPlay: onPlay),
      MediaDetailsPlaylistHeader(onSort: onSort),
    ],
  );
}

class MediaDetailsContinue extends StatelessWidget {
  final AppModel model;
  final SyncRecord? latest;
  final ValueChanged<SyncRecord> onPlay;

  const MediaDetailsContinue({
    super.key,
    required this.model,
    required this.latest,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final item = latest;
    if (item == null) return const SizedBox.shrink();
    final label = model.episodeLabel(item);
    return FilledButton.icon(
      key: const ValueKey('series-continue'),
      onPressed: () => onPlay(item),
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(
        '继续观看 · ${label.isEmpty ? playbackTime((model.progressFor(item)?['position'] as num?)?.toDouble() ?? 0) : label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class MediaDetailsPlaylistHeader extends StatelessWidget {
  final VoidCallback onSort;

  const MediaDetailsPlaylistHeader({super.key, required this.onSort});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text('播放列表', style: AppStyles.of(context).strong)),
      IconButton(
        tooltip: '排序与显示',
        onPressed: onSort,
        icon: const Icon(Icons.sort_rounded),
      ),
    ],
  );
}

class MediaDetailsEpisodeTile extends StatefulWidget {
  final AppModel model;
  final SyncRecord item;
  final VoidCallback onPlay;
  final Widget? trailing;
  final VoidCallback? onLongPress;
  final bool showTechnical;
  final String? title;
  final String? sourceId;
  final SourceEntry? sourceEntry;

  const MediaDetailsEpisodeTile({
    super.key,
    required this.model,
    required this.item,
    required this.onPlay,
    this.trailing,
    this.onLongPress,
    this.showTechnical = true,
    this.title,
    this.sourceId,
    this.sourceEntry,
  });

  @override
  State<MediaDetailsEpisodeTile> createState() =>
      _MediaDetailsEpisodeTileState();
}

typedef _EpisodeView = ({
  String title,
  String technical,
  String progress,
  String? thumbnail,
  bool watched,
  double fraction,
});

class _MediaDetailsEpisodeTileState extends State<MediaDetailsEpisodeTile> {
  late _EpisodeView _view;
  Object? _revision;
  bool _active = true, _dirty = false;
  AppModel get model => widget.model;
  SyncRecord get item => widget.item;

  Object get _currentRevision => (
    model.store.localKeyRevision('preview:${item.id}'),
    model.store.localKeyRevision('technical:${item.id}'),
    model.store.localKeyRevision('mediaMetadata:${item.id}'),
    model.store.localKeyRevision('location:${item.id}'),
    model.store.localKeyRevision('episodeTitle:${item.id}'),
    model.store.recordsRevision('progress'),
    model.store.recordsRevision('watched'),
    model.titleTranslations.revision,
  );

  @override
  void initState() {
    super.initState();
    _refresh();
    model.addListener(_modelChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_active && _dirty) _refresh();
  }

  @override
  void didUpdateWidget(MediaDetailsEpisodeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_modelChanged);
      model.addListener(_modelChanged);
    }
    if (oldWidget.model != model ||
        oldWidget.item != item ||
        oldWidget.title != widget.title ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.sourceEntry != widget.sourceEntry ||
        oldWidget.showTechnical != widget.showTechnical ||
        _revision != _currentRevision) {
      if (_active) {
        _refresh();
      } else {
        _dirty = true;
      }
    }
  }

  void _modelChanged() {
    if (_revision == _currentRevision) return;
    if (!_active) {
      _dirty = true;
      return;
    }
    final previous = _view;
    _refresh();
    if (previous != _view) setState(() {});
  }

  void _refresh() {
    _revision = _currentRevision;
    _dirty = false;
    final label = widget.title ?? model.episodeLabel(item);
    final progress = model.progressFor(item);
    final duration =
        (progress?['duration'] as num?)?.toDouble() ??
        model.mediaDuration(item);
    final progressLabel = playbackProgressLabel(progress, duration: duration);
    final updated = DateTime.tryParse(
      '${progress?['updatedAt'] ?? ''}',
    )?.toLocal();
    final position = (progress?['position'] as num?)?.toDouble() ?? 0;
    _view = (
      title: label.isEmpty ? model.displayTitle(item) : label,
      technical: widget.showTechnical
          ? MediaTechnicalInfo.forRecord(
              model.store,
              item,
              dimensions: model.mediaDimensions(item),
              duration: duration,
              fileName: widget.sourceEntry?.name,
              fileSize: widget.sourceEntry?.size,
            ).label
          : '',
      progress: progressLabel.isEmpty
          ? ''
          : '$progressLabel${updated == null ? '' : ' · ${updated.month}/${updated.day} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}'}',
      thumbnail: model.thumbnailPath(item.id),
      watched:
          model.store.get('watched', model.watchedKey(item))?.data['watched'] ==
          true,
      fraction: duration > 0 ? (position / duration).clamp(0, 1) : 0,
    );
  }

  Future<void> _requestPreview() async {
    final source = widget.sourceId, entry = widget.sourceEntry;
    if (source != null && entry != null) {
      final currentModel = model;
      final id = item.id;
      final needed = await currentModel.needsMediaPreview(id);
      if (needed &&
          mounted &&
          _active &&
          currentModel == model &&
          id == item.id &&
          entry.path == widget.sourceEntry?.path) {
        currentModel.ensureSourceMediaPreview(source, entry);
      }
    } else {
      model.ensureMediaPreview(item.id);
    }
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -1),
        contentPadding: EdgeInsets.zero,
        horizontalTitleGap: 10,
        minLeadingWidth: 64,
        minVerticalPadding: 8,
        leading: SizedBox(
          key: const ValueKey('episode-thumbnail'),
          width: 64,
          height: 44,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaArtwork(
                  thumbnail: _view.thumbnail,
                  placeholder: ColoredBox(
                    color: GlassPalette.of(context).field,
                    child: Center(
                      child: Icon(
                        _view.watched
                            ? Icons.check_circle
                            : Icons.play_circle_outline,
                      ),
                    ),
                  ),
                  onRequestPreview: () => _requestPreview(),
                ),
                if (_view.watched && _view.thumbnail != null)
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: GlassPalette.of(context).field,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_circle,
                        size: 18,
                        color: GlassPalette.of(context).accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        title: Text(
          _view.title,
          key: const ValueKey('episode-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppStyles.of(context).title14,
        ),
        subtitle: _episodeProgress(context),
        onTap: widget.onPlay,
        onLongPress: widget.onLongPress,
        trailing: SizedBox(
          key: const ValueKey('episode-action'),
          width: 40,
          height: 48,
          child:
              widget.trailing ?? const Icon(Icons.play_arrow_rounded, size: 20),
        ),
      ),
    );
  }

  Widget? _episodeProgress(BuildContext context) {
    final label = _view.progress, technical = _view.technical;
    if (label.isEmpty && technical.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (technical.isNotEmpty)
            Text(
              technical,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.of(context).micro,
            ),
          if (label.isNotEmpty)
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: LibraryStyles.of(context).episodeProgress,
            ),
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: _view.fraction,
                minHeight: LibraryStyles.progressHeight,
                borderRadius: LibraryStyles.progressRadius,
              ),
            ),
        ],
      ),
    );
  }
}
