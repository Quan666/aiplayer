import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../data/media_presentation.dart';
import '../data/media_episodes.dart';
import '../data/media_technical_info.dart';
import '../data/poster_cache.dart';
import '../sources/source.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'sources_page.dart';
import 'glass.dart';
import 'theme/library_styles.dart';
import 'media_artwork.dart';
import 'metadata_match_dialog.dart';
import 'metadata_tasks_sheet.dart';
import 'media_details_header.dart';
import 'search_header.dart';
import 'navigation_reveal.dart';
import 'device_icon.dart';

void showFailure(BuildContext context, Object error) {
  final failure = safeFailure(error);
  AppLog.instance.error('操作', failure.message);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(failure.message)));
  }
}

class LibraryPage extends StatefulWidget {
  final AppModel model;
  const LibraryPage({super.key, required this.model});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  AppModel get model => widget.model;
  int page = 0;
  final _pages = PageController();
  final _sources = SourcesController();
  bool _sourcePointerTap = false;
  late bool _navigationCollapsed;
  String query = '';
  bool importing = false;
  bool _openingPlayer = false;
  final _navigationHidden = ValueNotifier(false);
  late bool _hideNavigationOnScroll;
  double _scrollTravel = 0;
  final _pendingPreviewRequests = <String>{};
  List<SyncRecord> _recent = const [];
  List<SyncRecord> _media = const [];
  int? _mediaRevision, _recentProgressRevision, _recentLocationRevision;
  String? _groupQuery;
  List<MapEntry<String, List<SyncRecord>>> _posters = const [],
      _filesByGroup = const [];
  Widget? _libraryContent;
  bool? _libraryDesktop;
  bool _detailsVisible = false, _libraryNeedsRefresh = false;
  int _coveringRoutes = 0;
  @override
  void initState() {
    super.initState();
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
    _navigationCollapsed =
        model.store.local('desktopNavigationCollapsed') == true;
    model.addListener(_changed);
  }

  void _changed() {
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
    if (!_hideNavigationOnScroll) _navigationHidden.value = false;
    if (_detailsVisible || _coveringRoutes > 0) {
      _libraryNeedsRefresh = true;
      return;
    }
    if (page == 0) {
      _libraryContent = null;
    } else {
      _libraryNeedsRefresh = true;
    }
    if (mounted) setState(() {});
  }

  void _refreshUncoveredLibrary() {
    if (!mounted ||
        _detailsVisible ||
        _coveringRoutes > 0 ||
        !_libraryNeedsRefresh) {
      return;
    }
    _libraryNeedsRefresh = false;
    _libraryContent = null;
    setState(() {});
  }

  Future<T?> _pushCoveringRoute<T>(TransitionRoute<T> route) async {
    _coveringRoutes++;
    try {
      final result = await Navigator.of(context).push(route);
      await route.completed;
      return result;
    } finally {
      _coveringRoutes--;
      _refreshUncoveredLibrary();
    }
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == model) return;
    oldWidget.model.removeListener(_changed);
    model.addListener(_changed);
    _mediaRevision = null;
    _libraryContent = null;
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _pages.dispose();
    _sources.dispose();
    _navigationHidden.dispose();
    super.dispose();
  }

  Future<void> _files() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        'mkv',
        'mp4',
        'webm',
        'avi',
        'mov',
        'm4v',
        'ts',
        'm2ts',
        'flv',
        'wmv',
      ],
    );
    if (result != null) {
      await _import(result.paths.whereType<String>().toList());
    }
  }

  Future<void> _import(List<String> paths) async {
    setState(() {
      importing = true;
      _libraryContent = null;
    });
    try {
      for (final path in paths) {
        if (isVideo(path)) await model.importFile(path);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) {
        setState(() {
          importing = false;
          _libraryContent = null;
        });
      }
    }
  }

  Future<void> _play(SyncRecord record) async {
    if (_openingPlayer) return;
    _openingPlayer = true;
    try {
      if (model.store.local('location:${record.id}') == null) {
        await _associate(record);
        return;
      }
      await PlayerPage.waitForDisposals();
      if (!mounted) return;
      await _pushCoveringRoute(
        PageRouteBuilder(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => PlayerPage(model: model, media: record),
        ),
      );
      if (mounted) model.changed();
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      _openingPlayer = false;
    }
  }

  Future<void> _associate(SyncRecord record) async {
    await showGlassBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('关联此设备上的视频位置'),
              subtitle:
                  record.deviceName.isNotEmpty &&
                      record.deviceId != model.store.deviceId
                  ? Text(record.deviceName)
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('选择本地视频'),
              onTap: () async {
                Navigator.pop(sheet);
                try {
                  final result = await FilePicker.platform.pickFiles();
                  final path = result?.files.single.path;
                  if (path != null) {
                    await model.importFile(path, associateId: record.id);
                  }
                } catch (e) {
                  if (mounted) showFailure(context, e);
                }
              },
            ),
            for (final source in model.sources)
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: Text(source['label']),
                onTap: () {
                  Navigator.pop(sheet);
                  _pushCoveringRoute(
                    MaterialPageRoute(
                      builder: (_) => SourceBrowser(
                        model: model,
                        source: source,
                        associateId: record.id,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _details(String series, List<SyncRecord> episodes) async {
    if (episodes.isEmpty || _detailsVisible) return;
    _detailsVisible = true;
    ModalRoute<dynamic>? detailsRoute;
    final ids = episodes.map((item) => item.id).toSet();
    final latest = _recent.where((item) => ids.contains(item.id)).firstOrNull;
    try {
      await showGlassBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (sheet) {
          detailsRoute = ModalRoute.of(sheet);
          return _SeriesDetailsSheet(
            model: model,
            episodes: episodes,
            latest: latest,
            onPlay: (item) {
              Navigator.pop(sheet);
              _play(item);
            },
            onMatch: (items) {
              Navigator.pop(sheet);
              showMetadataMatchDialog(
                context,
                model,
                '${items.first.data['series'] ?? series}',
                season: '${items.first.data['season'] ?? ''}',
                mediaIds: items.map((item) => item.id).toSet(),
              );
            },
            onAction: (action, item) {
              Navigator.pop(sheet);
              if (action == 'edit') _edit(item);
              if (action == 'link') _associate(item);
              if (action == 'watched') {
                final key = model.watchedKey(item);
                model.store.save('watched', key, {
                  'watched':
                      model.store.get('watched', key)?.data['watched'] != true,
                });
                model.changed();
              }
              if (action == 'delete') _remove(item);
            },
          );
        },
      );
      // A route's pop result arrives before its closing animation finishes.
      // Coalesce background import/thumbnail notifications through that frame.
      await detailsRoute?.completed;
    } finally {
      _detailsVisible = false;
      _refreshUncoveredLibrary();
    }
  }

  Future<void> _remove(SyncRecord item) => _removeItems([item]);

  Future<void> _removeItems(List<SyncRecord> items) async {
    try {
      final managedCount = (await Future.wait(
        items.map(model.isManagedImport),
      )).where((managed) => managed).length;
      final single = items.length == 1;
      final managed = managedCount > 0;
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(
            single
                ? (managed ? '删除导入的视频？' : '从影视库移除？')
                : '移除这 ${items.length} 个视频？',
          ),
          content: Text(
            !managed
                ? '仅移除影视库记录，原位置的视频文件会保留。'
                : single
                ? '将删除应用中导入的视频文件及其库记录，无法撤销。原始位置的文件不受影响。'
                : '将移除所选视频的库记录，并删除其中 $managedCount 个应用导入副本，无法撤销。原始位置的文件不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(managed ? '删除视频' : '移除'),
            ),
          ],
        ),
      );
      if (yes == true) {
        for (final item in items) {
          await model.removeMedia(item);
        }
      }
    } catch (error) {
      if (mounted) showFailure(context, error);
    }
  }

  Future<void> _edit(SyncRecord item) async {
    final name = TextEditingController(text: item.data['series']),
        season = TextEditingController(text: '${item.data['season'] ?? ''}'),
        episode = TextEditingController(text: '${item.data['episode'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('更正影视资料'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '作品名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: season,
              decoration: const InputDecoration(labelText: '季度'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: episode,
              decoration: const InputDecoration(labelText: '集数 / S1 / O1'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      final data = {...item.data};
      if (name.text.trim() != item.data['series'] ||
          season.text.trim() != '${item.data['season'] ?? ''}') {
        for (final key in [
          'bangumiId',
          'tmdbId',
          'poster',
          'summary',
          'metadataTitle',
          'rating',
          'ratingCount',
          'airDate',
          'totalEpisodes',
          'totalSeasons',
          'genres',
        ]) {
          data.remove(key);
        }
        model.store.removeLocal('episodeTitle:${item.id}');
      }
      model.store.save('media', item.id, {
        ...data,
        'series': name.text.trim(),
        'season': season.text.trim(),
        'episode': episode.text.trim(),
      });
      model.store.setLocal('manualMetadata:${item.id}', true);
      model.changed();
    }
    name.dispose();
    season.dispose();
    episode.dispose();
  }

  Widget _library(BuildContext context, bool desktop) {
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final mediaRevision = model.store.recordsRevision('media');
    if (_mediaRevision != mediaRevision) {
      _media = model.media;
      _mediaRevision = mediaRevision;
      _groupQuery = null;
      _recentProgressRevision = null;
    }
    final media = _media;
    final search = query.toLowerCase();
    if (_groupQuery != search) {
      final groups = <String, List<SyncRecord>>{};
      for (final item in media) {
        final series = '${item.data['series']}';
        if (search.isEmpty ||
            series.toLowerCase().contains(search) ||
            '${item.data['title']}'.toLowerCase().contains(search)) {
          final identifiable =
              (item.data['episode'] as String? ?? '').isNotEmpty ||
              item.data['bangumiId'] != null ||
              item.data['tmdbId'] != null;
          final key = identifiable && series != '未分类' && series.isNotEmpty
              ? mediaSeriesKey(item)
              : 'file:${item.id}';
          (groups[key] ??= []).add(item);
        }
      }
      _posters = [];
      _filesByGroup = [];
      for (final entry in groups.entries) {
        (_hasPoster(entry.value) ? _posters : _filesByGroup).add(entry);
      }
      _groupQuery = search;
    }
    final posters = _posters, files = _filesByGroup;
    final groupCount = posters.length + files.length;
    final progressRevision = model.store.recordsRevision('progress');
    final locationRevision = model.store.locationRevision;
    if (_recentProgressRevision != progressRevision ||
        _recentLocationRevision != locationRevision) {
      _recent = model.recentMedia(items: media);
      _recentProgressRevision = progressRevision;
      _recentLocationRevision = locationRevision;
    }
    final recent = _recent;
    final inset = desktop ? 20.0 : 12.0;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return CustomScrollView(
      key: const PageStorageKey('library-scroll'),
      slivers: [
        SliverPadding(
          // Keep the initial header below the status bar, but let this inset
          // scroll away with the content instead of clipping the viewport.
          padding: EdgeInsets.fromLTRB(
            inset,
            GlassMetrics.pageTopPadding(context) +
                MediaQuery.paddingOf(context).top,
            inset,
            0,
          ),
          sliver: SliverList.list(
            children: [
              SearchHeader(
                title: '我的影视库',
                hint: '搜索作品或文件名',
                onChanged: (v) => setState(() {
                  query = v;
                  _libraryContent = null;
                }),
                subtitle: mobile ? null : '${media.length} 个视频',
                trailing: FilledButton.icon(
                  onPressed: importing ? null : _files,
                  icon: const Icon(
                    Icons.add_rounded,
                    size: LibraryStyles.iconHeading,
                  ),
                  label: const Text('导入视频'),
                ),
              ),
              const SizedBox(height: 14),
              if (!mobile && (importing || model.scanning)) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
              ],
              if (!mobile && model.status.isNotEmpty) ...[
                Text(model.status, style: AppStyles.of(context).caption),
                const SizedBox(height: 12),
              ],
              if (recent.isNotEmpty && query.isEmpty) ...[
                const SizedBox(height: 18),
                _ContinueWatchingCarousel(
                  onOpenHistory: _history,
                  itemCount: recent.length.clamp(0, 10),
                  cardWidth: desktop ? 340 : 306,
                  cardHeight: 164 + (scale - 1).clamp(0, 2) * 60,
                  itemBuilder: (_, index) => _continueCard(recent[index]),
                ),
              ],
              const SizedBox(height: 18),
              _sectionHeading(query.isEmpty ? '全部视频' : '搜索结果', '$groupCount'),
              const SizedBox(height: 10),
            ],
          ),
        ),
        if (groupCount == 0)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 32),
            sliver: SliverToBoxAdapter(
              child: GlassSurface(
                blur: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      query.isEmpty ? '暂无视频' : '没有找到匹配的作品',
                      textAlign: TextAlign.center,
                      style: AppStyles.of(context).panelTitle,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      query.isEmpty ? '导入视频或添加网络来源' : '试试其他作品名称或文件名',
                      textAlign: TextAlign.center,
                      style: LibraryStyles.of(context).emptyHint,
                    ),
                    if (query.isEmpty) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () => _selectPage(1),
                        icon: const Icon(
                          Icons.storage_rounded,
                          size: LibraryStyles.iconButton,
                        ),
                        label: const Text('连接来源'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          )
        else ...[
          for (final group in [posters, files])
            if (group.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: identical(group, posters)
                        ? (scale > 1.3 ? 260 : 190)
                        : (desktop ? 310 : 240),
                    childAspectRatio: identical(group, posters)
                        ? .65
                        : (scale > 1.3 ? 1.05 : 1.27),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: group.length,
                  itemBuilder: (_, i) =>
                      _posterCard(group[i].key, group[i].value),
                ),
              ),
        ],
        SliverToBoxAdapter(
          // Keep scroll metrics stable while the floating navigation slides.
          child: SizedBox(height: desktop ? 16 : 92),
        ),
      ],
    );
  }

  Widget _sectionHeading(String title, String caption) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 16,
    runSpacing: 4,
    children: [
      Text(title, style: LibraryStyles.of(context).sectionTitle),
      if (caption.isNotEmpty)
        Text(caption, style: AppStyles.of(context).caption),
    ],
  );

  bool _hasPoster(List<SyncRecord> items) =>
      items.any((m) => '${m.data['poster'] ?? ''}'.isNotEmpty);

  void _requestPreview(SyncRecord media) {
    // The history carousel and grid can show the same media in one frame.
    // MediaArtwork has already deferred this callback until scrolling settles.
    if (!_pendingPreviewRequests.add(media.id)) return;
    scheduleMicrotask(() => _pendingPreviewRequests.remove(media.id));
    model.ensureMediaPreview(media.id);
  }

  Future<void> _history() async {
    await _pushCoveringRoute(
      MaterialPageRoute(
        builder: (_) => GlassBackground(
          child: Scaffold(
            appBar: AppBar(title: const Text('观看历史')),
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) {
                final items = model.recentMedia();
                if (items.isEmpty) {
                  return const Center(child: Text('暂无观看历史'));
                }
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final scale = MediaQuery.textScalerOf(context).scale(1);
                        final inset = constraints.maxWidth >= 700 ? 24.0 : 12.0;
                        const gap = 16.0;
                        final width = constraints.maxWidth - inset * 2;
                        final minCardWidth = scale > 1.3 ? 360.0 : 300.0;
                        final columns = ((width + gap) / (minCardWidth + gap))
                            .floor()
                            .clamp(1, 5);
                        final cardWidth =
                            (width - (columns - 1) * gap) / columns;
                        return GridView.builder(
                          key: const PageStorageKey('library-history-grid'),
                          padding: EdgeInsets.all(inset),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent:
                                    (cardWidth * 9 / 16).clamp(176.0, 250.0) +
                                    (scale - 1).clamp(0, 2) * 60,
                                crossAxisSpacing: gap,
                                mainAxisSpacing: gap,
                              ),
                          itemCount: items.length,
                          itemBuilder: (_, index) =>
                              _continueCard(items[index]),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _historyActions(SyncRecord media) async {
    final remove = await showGlassBottomSheet<bool>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.history_toggle_off_rounded),
              title: const Text('移除这条观看记录'),
              subtitle: Text(model.displayTitle(media)),
              onTap: () => Navigator.pop(sheet, true),
            ),
          ],
        ),
      ),
    );
    if (remove == true && mounted) {
      try {
        model.removePlaybackHistory(media);
      } catch (error) {
        showFailure(context, error);
      }
    }
  }

  Widget _continueCard(SyncRecord media) {
    final progress = model.progressFor(media);
    final position = (progress?['position'] as num?)?.toDouble() ?? 0;
    final duration =
        (progress?['duration'] as num?)?.toDouble() ??
        model.mediaDuration(media);
    final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final episode = model.episodeLabel(media);
    final title = model.seriesTitle(media);
    final progressRecord = model.store.get(
      'progress',
      model.progressKey(media),
    );
    final origin =
        progressRecord != null && progressRecord.deviceName.isNotEmpty
        ? progressRecord
        : media;
    final otherDevice = origin.deviceId != model.store.deviceId
        ? origin.deviceName
        : '';
    return ClipRRect(
      key: ValueKey('history:${media.id}'),
      borderRadius: LibraryStyles.historyRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaArtwork(
            thumbnail: model.thumbnailPath(media.id),
            onRequestPreview: () => _requestPreview(media),
          ),
          DecoratedBox(decoration: LibraryStyles.of(context).historyOverlay),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _play(media),
              onLongPress: () => _historyActions(media),
              onSecondaryTap: () => _historyActions(media),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: LibraryStyles.of(context).continueTitle,
                    ),
                    if (episode.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          episode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LibraryStyles.of(context).mediaCaption,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${mediaTime(position)} / ${duration > 0 ? mediaTime(duration) : '--:--'} · ${duration > 0 ? '${(fraction * 100).round()}%' : '--%'}',
                      style: LibraryStyles.of(context).mediaCaption,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: fraction,
                      minHeight: LibraryStyles.progressHeight,
                      color: GlassPalette.of(context).onMedia,
                      backgroundColor: LibraryStyles.of(
                        context,
                      ).mediaProgressTrack,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (otherDevice.isNotEmpty)
            Positioned(
              top: 10,
              left: 12,
              right: 12,
              child: IgnorePointer(
                child: Row(
                  children: [
                    Icon(
                      playbackDeviceIcon(
                        platform:
                            '${progressRecord?.data['devicePlatform'] ?? ''}',
                        name: otherDevice,
                      ),
                      size: 14,
                      color: GlassPalette.of(context).onMedia,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        otherDevice,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LibraryStyles.of(context).mediaCaption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _posterCard(String key, List<SyncRecord> items) {
    final media = items.first;
    final poster =
        items
            .map((m) => '${m.data['poster'] ?? ''}')
            .where((v) => v.isNotEmpty)
            .firstOrNull ??
        '';
    final title = items.length == 1
        ? model.displayTitle(media)
        : model.seriesTitle(media);
    return Semantics(
      key: ValueKey(key),
      button: true,
      label: '$title，${items.length} 个视频',
      child: _PosterTile(
        cache: model.posterCache,
        title: title,
        poster: poster,
        thumbnail: model.thumbnailPath(media.id),
        count: items.length,
        duration: model.mediaDuration(media),
        mediaId: media.id,
        onTap: () => items.length == 1 ? _play(media) : _details(title, items),
        onDetails: () => _details(title, items),
        onRemove: () => _removeItems(items),
        onRequestPreview: () => _requestPreview(media),
      ),
    );
  }

  void _revealNavigation() {
    _scrollTravel = 0;
    if (mounted) _navigationHidden.value = false;
  }

  void _selectPage(int value) {
    _revealNavigation();
    if (page == value) return;
    // Button selection is immediate on every platform; horizontal swipes still
    // use PageView's gesture-driven animation and retained tab state.
    _pages.jumpToPage(value);
  }

  bool _onScroll(ScrollNotification notification) {
    if (!_hideNavigationOnScroll ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0;
      if (_scrollTravel.sign != delta.sign) _scrollTravel = 0;
      _scrollTravel += delta;
      final hide = _scrollTravel > 24 && notification.metrics.pixels > 24;
      final show = _scrollTravel < -12 || notification.metrics.pixels <= 0;
      if (hide) _navigationHidden.value = true;
      if (show) _navigationHidden.value = false;
    }
    return false;
  }

  Widget _navigation(bool desktop) {
    final c = GlassPalette.of(context);
    final styles = LibraryStyles.of(context);
    final itemDuration = MotionScope.duration(context, 180);
    const icons = [
      Icons.video_library_outlined,
      Icons.folder_open_rounded,
      Icons.settings_outlined,
    ];
    final labels = ['影视库', desktop ? '视频来源' : '来源', '设置'];
    final radius = desktop
        ? GlassMetrics.control
        : GlassMetrics.navigationItemRadius;
    Widget item(int i) => Semantics(
      selected: page == i,
      button: true,
      child: Tooltip(
        message: labels[i],
        child: Listener(
          onPointerDown: i == 1
              ? (_) {
                  _sourcePointerTap = true;
                  _selectPage(1);
                }
              : null,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: () {
                // The pointer already selected Sources immediately. Its delayed
                // single-tap callback must not undo a subsequent tab selection.
                if (i == 1 && _sourcePointerTap) {
                  _sourcePointerTap = false;
                  return;
                }
                _selectPage(i);
              },
              onDoubleTap: i == 1
                  ? () {
                      _sourcePointerTap = false;
                      _selectPage(1);
                      _sources.showRoot();
                    }
                  : null,
              child: AnimatedContainer(
                key: ValueKey('nav-item-$i'),
                duration: itemDuration,
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(minHeight: 48),
                padding: EdgeInsets.symmetric(
                  horizontal: desktop ? 12 : 8,
                  vertical: desktop ? 12 : 7,
                ),
                decoration: styles.navigationDecoration(radius: radius),
                child: desktop
                    ? TweenAnimationBuilder<TextStyle>(
                        tween: TextStyleTween(
                          end: styles.navigationLabel(
                            desktop: true,
                            selected: page == i,
                          ),
                        ),
                        duration: itemDuration,
                        curve: Curves.easeOutCubic,
                        builder: (context, style, child) => Row(
                          children: [
                            Icon(
                              icons[i],
                              size: LibraryStyles.iconNavigationDesktop,
                              color: style.color,
                            ),
                            if (!_navigationCollapsed)
                              const SizedBox(width: 10),
                            if (!_navigationCollapsed)
                              Flexible(
                                child: Text(
                                  labels[i],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: style,
                                ),
                              ),
                          ],
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icons[i],
                            size: LibraryStyles.iconNavigation,
                            color: page == i ? c.accent : c.muted,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            labels[i],
                            maxLines: 1,
                            style: LibraryStyles.of(context).navigationLabel(
                              desktop: false,
                              selected: page == i,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!desktop) {
      return LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            AnimatedPositioned(
              duration: MotionScope.duration(context, 300),
              curve: Curves.easeInOutCubic,
              left: constraints.maxWidth * page / 3,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth / 3,
              child: GlassSurface(
                borderRadius: radius,
                blur: 0,
                tint: LibraryStyles.of(context).navigationSelection,
                child: const SizedBox.expand(),
              ),
            ),
            Row(
              children: [for (var i = 0; i < 3; i++) Expanded(child: item(i))],
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 20),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: LibraryStyles.compactRadius,
                child: Image.asset(
                  'assets/branding/app_icon.png',
                  width: 28,
                  height: 28,
                  excludeFromSemantics: true,
                ),
              ),
              if (!_navigationCollapsed) const SizedBox(width: 10),
              if (!_navigationCollapsed)
                Text('映库', style: AppStyles.of(context).panelTitle),
            ],
          ),
        ),
        Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedAlign(
                  alignment: Alignment(0, page - 1.0),
                  duration: itemDuration,
                  curve: Curves.easeOutCubic,
                  child: FractionallySizedBox(
                    widthFactor: 1,
                    heightFactor: 1 / 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: DecoratedBox(
                        key: const ValueKey('desktop-navigation-indicator'),
                        decoration: styles.desktopNavigationSelection,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: item(i),
                  ),
              ],
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          key: const ValueKey('toggle-desktop-navigation'),
          tooltip: _navigationCollapsed ? '展开导航栏' : '折叠导航栏',
          icon: Icon(
            _navigationCollapsed
                ? Icons.keyboard_double_arrow_right_rounded
                : Icons.keyboard_double_arrow_left_rounded,
          ),
          onPressed: () {
            setState(() => _navigationCollapsed = !_navigationCollapsed);
            model.store.setLocal(
              'desktopNavigationCollapsed',
              _navigationCollapsed,
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 1000;
    if (_libraryDesktop != desktop) {
      _libraryDesktop = desktop;
      _libraryContent = null;
    }
    return GlassBackground(
      child: Scaffold(
        extendBody: true,
        floatingActionButton: model.metadataTasks.isEmpty
            ? null
            : FloatingActionButton.small(
                heroTag: 'metadata-tasks',
                tooltip: '识别任务',
                onPressed: () => showMetadataTasks(context, model),
                child: Badge(
                  isLabelVisible: model.metadataTasks.any(
                    (task) => task.running,
                  ),
                  label: Text(
                    '${model.metadataTasks.where((task) => task.running).length}',
                  ),
                  child: const Icon(Icons.manage_search_rounded),
                ),
              ),
        body: SafeArea(
          top: desktop,
          bottom: false,
          child: DropTarget(
            onDragDone: (details) =>
                _import(details.files.map((f) => f.path).toList()),
            child: Row(
              children: [
                if (desktop)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                    child: SizedBox(
                      width: _navigationCollapsed ? 68 : 172,
                      child: GlassSurface(
                        borderRadius: GlassMetrics.sheet,
                        blur: 0,
                        padding: const EdgeInsets.all(8),
                        child: _navigation(true),
                      ),
                    ),
                  ),
                Expanded(
                  child: NavigationRevealRegion(
                    onReveal: _revealNavigation,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _onScroll,
                      child: PageView(
                        controller: _pages,
                        onPageChanged: (value) => setState(() {
                          page = value;
                          if (value == 0 && _libraryNeedsRefresh) {
                            _libraryContent = null;
                            _libraryNeedsRefresh = false;
                          }
                          _navigationHidden.value = false;
                          _scrollTravel = 0;
                        }),
                        children: [
                          _RetainedTab(
                            child: _libraryContent ??= Builder(
                              builder: (context) => _library(context, desktop),
                            ),
                          ),
                          _RetainedTab(
                            child: SourcesPage(
                              controller: _sources,
                              model: model,
                              onImport: _files,
                              onPlay: _play,
                            ),
                          ),
                          _RetainedTab(
                            child: SafeArea(
                              left: false,
                              right: false,
                              bottom: false,
                              child: SettingsPage(model: model),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: desktop
            ? null
            : ValueListenableBuilder<bool>(
                valueListenable: _navigationHidden,
                builder: (context, hidden, child) => IgnorePointer(
                  ignoring: hidden && _hideNavigationOnScroll,
                  child: AnimatedSlide(
                    key: const ValueKey('navigation-slide'),
                    offset: hidden && _hideNavigationOnScroll
                        ? const Offset(0, 1.3)
                        : Offset.zero,
                    duration: MotionScope.duration(context, 220),
                    curve: Curves.easeOutCubic,
                    child: child,
                  ),
                ),
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: GlassSurface(
                        key: const ValueKey('bottom-navigation'),
                        elevated: true,
                        borderRadius: GlassMetrics.navigationRadius,
                        blur: 12,
                        tint: GlassPalette.of(context).navigationSurface,
                        padding: const EdgeInsets.all(
                          GlassMetrics.navigationInset,
                        ),
                        child: _navigation(false),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _ContinueWatchingCarousel extends StatefulWidget {
  final VoidCallback onOpenHistory;
  final int itemCount;
  final double cardWidth, cardHeight;
  final IndexedWidgetBuilder itemBuilder;

  const _ContinueWatchingCarousel({
    required this.onOpenHistory,
    required this.itemCount,
    required this.cardWidth,
    required this.cardHeight,
    required this.itemBuilder,
  });

  @override
  State<_ContinueWatchingCarousel> createState() =>
      _ContinueWatchingCarouselState();
}

class _ContinueWatchingCarouselState extends State<_ContinueWatchingCarousel> {
  final _scroll = ScrollController();

  void _scrollPage(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target =
        (position.pixels + position.viewportDimension * .85 * direction).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _scroll.animateTo(
      target,
      duration: MotionScope.duration(context, 240),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _carouselScrollbars({required bool enabled, required Widget child}) =>
      enabled
      ? Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          interactive: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          notificationPredicate: (notification) =>
              notification.depth == 0 &&
              notification.metrics.axis == Axis.horizontal,
          child: child,
        )
      : child;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !_scroll.hasClients ||
        event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) {
      return;
    }
    final position = _scroll.position;
    final target = (position.pixels + event.scrollDelta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    // Resolve against the enclosing vertical library scroll, so a mouse wheel
    // moves the carousel without also moving the whole page.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_scroll.hasClients) {
        _scroll.position.pointerScroll(event.scrollDelta.dy);
        event.respond(allowPlatformDefault: false);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop =
        MediaQuery.sizeOf(context).width >= 1000 ||
        switch (Theme.of(context).platform) {
          TargetPlatform.macOS ||
          TargetPlatform.windows ||
          TargetPlatform.linux => true,
          _ => false,
        };
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = widget.cardWidth.clamp(0.0, constraints.maxWidth);
        final overflow =
            widget.itemCount * (cardWidth + 10) - 10 > constraints.maxWidth;
        final scrollbarInset = desktop && overflow ? 14.0 : 0.0;
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: widget.onOpenHistory,
                    borderRadius: LibraryStyles.compactRadius,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            '继续观看',
                            style: LibraryStyles.of(context).sectionTitle,
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.chevron_right_rounded,
                            size: LibraryStyles.iconHeading,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (desktop && overflow)
                  AnimatedBuilder(
                    animation: _scroll,
                    builder: (context, _) => Row(
                      children: [
                        IconButton(
                          tooltip: '向左滚动',
                          onPressed:
                              _scroll.hasClients &&
                                  _scroll.offset >
                                      _scroll.position.minScrollExtent
                              ? () => _scrollPage(-1)
                              : null,
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        IconButton(
                          tooltip: '向右滚动',
                          onPressed:
                              !_scroll.hasClients ||
                                  _scroll.offset <
                                      _scroll.position.maxScrollExtent
                              ? () => _scrollPage(1)
                              : null,
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: widget.cardHeight + scrollbarInset,
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  // A resize or changed history can alter the scroll range
                  // without a scroll event. Refresh the arrow availability.
                  if (mounted) setState(() {});
                  return false;
                },
                child: _carouselScrollbars(
                  enabled: desktop && overflow,
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        scrollbars: false,
                        dragDevices: {
                          ...ScrollConfiguration.of(context).dragDevices,
                          PointerDeviceKind.mouse,
                        },
                      ),
                      child: ListView.separated(
                        key: const PageStorageKey('library-continue-scroll'),
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.only(bottom: scrollbarInset),
                        itemCount: widget.itemCount,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) => SizedBox(
                          width: cardWidth,
                          child: widget.itemBuilder(context, index),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PosterTile extends StatefulWidget {
  final PosterCache cache;
  final String title, poster, mediaId;
  final String? thumbnail;
  final int count;
  final double duration;
  final VoidCallback onTap, onDetails, onRequestPreview;
  final VoidCallback? onRemove;
  const _PosterTile({
    required this.cache,
    required this.title,
    required this.poster,
    required this.thumbnail,
    required this.count,
    required this.duration,
    required this.mediaId,
    required this.onTap,
    required this.onDetails,
    this.onRemove,
    required this.onRequestPreview,
  });
  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  bool hovered = false, pressed = false;
  @override
  Widget build(BuildContext context) {
    final c = GlassPalette.of(context);
    return AnimatedScale(
      scale: pressed
          ? .985
          : hovered
          ? 1.012
          : 1,
      duration: MotionScope.duration(context, 140),
      curve: Curves.easeOutCubic,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('play:${widget.mediaId}'),
            onTap: widget.onTap,
            onLongPress: widget.onRemove,
            onSecondaryTap: widget.onRemove,
            onTapDown: (_) => setState(() => pressed = true),
            onTapUp: (_) => setState(() => pressed = false),
            onTapCancel: () => setState(() => pressed = false),
            borderRadius: LibraryStyles.posterRadius,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: LibraryStyles.posterRadius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        MediaArtwork(
                          cache: widget.cache,
                          poster: widget.poster,
                          thumbnail: widget.thumbnail,
                          onRequestPreview: widget.onRequestPreview,
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                key: ValueKey('details:${widget.mediaId}'),
                                tooltip: '查看详情',
                                onPressed: widget.onDetails,
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  Icons.info_outline_rounded,
                                  color: c.onMedia,
                                  shadows: LibraryStyles.of(
                                    context,
                                  ).posterIconShadows,
                                  size: LibraryStyles.iconButton,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.onRemove != null)
                          Positioned(
                            top: 4,
                            left: 4,
                            child: PopupMenuButton<String>(
                              key: ValueKey('media-actions:${widget.mediaId}'),
                              tooltip: '视频操作',
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                color: c.onMedia,
                                shadows: LibraryStyles.of(
                                  context,
                                ).posterIconShadows,
                              ),
                              onSelected: (_) => widget.onRemove!(),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text('从影视库移除'),
                                ),
                              ],
                            ),
                          ),
                        if (widget.count > 1)
                          Positioned(
                            bottom: 7,
                            right: 8,
                            child: Text(
                              '${widget.count} 集',
                              style: LibraryStyles.of(context).posterCount,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LibraryStyles.of(context).posterTitle,
                ),
                if (widget.duration > 0 && widget.count == 1)
                  Text(
                    mediaTime(widget.duration),
                    style: AppStyles.of(context).micro,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesDetailsSheet extends StatefulWidget {
  final AppModel model;
  final List<SyncRecord> episodes;
  final SyncRecord? latest;
  final ValueChanged<SyncRecord> onPlay;
  final ValueChanged<List<SyncRecord>> onMatch;
  final void Function(String, SyncRecord) onAction;
  const _SeriesDetailsSheet({
    required this.model,
    required this.episodes,
    required this.latest,
    required this.onPlay,
    required this.onMatch,
    required this.onAction,
  });
  @override
  State<_SeriesDetailsSheet> createState() => _SeriesDetailsSheetState();
}

class _SeriesDetailsSheetState extends State<_SeriesDetailsSheet> {
  late List<SyncRecord> _allEpisodes;
  Map<String, List<SyncRecord>> _versions = {};
  late List<SyncRecord> _episodes;
  late Widget _header;
  final _loading = ValueNotifier(false);
  final _cancel = CancelToken();
  Animation<double>? _entrance;
  bool _scheduled = false;
  bool _metadataNotified = false;
  late int _titleRevision;
  late String _sortFingerprint;
  String get _sortKey =>
      'directorySort:series:${mediaSeriesKey(_episodes.first)}';
  String get _currentSort =>
      model.directorySorting(_sortKey).toJson().toString();
  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _setEpisodes(widget.episodes);
    _sortEpisodes();
    _sortFingerprint = _currentSort;
    _titleRevision = model.titleTranslations.revision;
    _updateHeader();
    model.addListener(_metadataChanged);
  }

  void _setEpisodes(List<SyncRecord> records) {
    _allEpisodes = records;
    final locations = model.store.localEntries('location:');
    _versions = groupMediaEpisodes(records);
    _episodes = uniqueMediaEpisodes(
      records,
      playable: (item) => locations.containsKey('location:${item.id}'),
    )..sort(compareMediaEpisodes);
  }

  Future<void> _chooseVersion(SyncRecord item) async {
    final versions = _versions[mediaEpisodeKey(item)] ?? [item];
    final selected = await showModalBottomSheet<SyncRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: versions.length,
          itemBuilder: (context, index) {
            final version = versions[index];
            final location = model.store.local('location:${version.id}');
            return ListTile(
              title: Text(
                '${version.data['fileName'] ?? version.data['title'] ?? model.displayTitle(version)}',
              ),
              subtitle: Text(
                [
                  MediaTechnicalInfo.forRecord(model.store, version).label,
                  if (location is Map) '${location['path']}',
                  playbackProgressLabel(model.progressFor(version)),
                ].where((text) => text.isNotEmpty).join('\n'),
              ),
              onTap: () => Navigator.pop(context, version),
            );
          },
        ),
      ),
    );
    if (selected != null && mounted) widget.onPlay(selected);
  }

  void _metadataChanged() {
    _metadataNotified = true;
    final sortingChanged = _sortFingerprint != _currentSort;
    if (sortingChanged) {
      _sortEpisodes();
      _sortFingerprint = _currentSort;
    }
    if (sortingChanged || _titleRevision != model.titleTranslations.revision) {
      _titleRevision = model.titleTranslations.revision;
      if (mounted) setState(() {});
    }
  }

  void _sortEpisodes() {
    if (model.store.local(_sortKey) == null &&
        model.store.local('directorySort:default') == null) {
      _episodes.sort(compareMediaEpisodes);
      return;
    }
    final records = {for (final episode in _episodes) episode.id: episode};
    _episodes = model
        .directorySorting(_sortKey)
        .apply([
          for (final episode in _episodes)
            SourceEntry(
              name: '${episode.data['title'] ?? mediaDisplayTitle(episode)}',
              path: episode.id,
              size: (episode.data['size'] as num?)?.toInt() ?? 0,
              modified: (episode.data['modified'] as num?)?.toInt() ?? 0,
            ),
        ], hideHiddenFiles: false)
        .map((entry) => records[entry.path]!)
        .toList();
  }

  Future<void> _sortMenu() => showDirectoryOptions(
    context,
    model.directorySorting(_sortKey),
    (value) => model.setDirectorySorting(_sortKey, value),
    showSubtitleOption: false,
    onApplyAll: (value) {
      model.applyDirectorySortingToAll(value);
      showGlassSuccess(context, '已应用到所有文件夹');
    },
  );

  void _updateHeader() {
    _header = MediaDetailsHeader(
      model: model,
      details: MediaCollectionDetails.fromRecords(_allEpisodes),
      records: _allEpisodes,
      onMatch: () => widget.onMatch(_allEpisodes),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _scheduleLoad();
    } else if (_entrance != animation) {
      _entrance?.removeStatusListener(_onAnimationStatus);
      _entrance = animation..addStatusListener(_onAnimationStatus);
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _scheduleLoad();
  }

  void _scheduleLoad() {
    if (_scheduled) return;
    _scheduled = true;
    _entrance?.removeStatusListener(_onAnimationStatus);
    // Even the synchronous prefix of loading can scan the library and import
    // records. Let the final entrance frame paint before beginning that work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    _loading.value = true;
    try {
      final episodes = await model.loadSeriesEpisodes(
        _episodes.first,
        cancel: _cancel,
      );
      if (!mounted || episodes.isEmpty) return;
      if (!_metadataNotified && episodes.length == _episodes.length) {
        var unchanged = true;
        for (var index = 0; index < episodes.length; index++) {
          final before = _episodes[index], after = episodes[index];
          if (before.id != after.id ||
              before.revision != after.revision ||
              before.version != after.version) {
            unchanged = false;
            break;
          }
        }
        if (unchanged) return;
      }
      setState(() {
        _setEpisodes(episodes);
        _sortEpisodes();
        _updateHeader();
      });
    } catch (_) {
      // Existing metadata and episodes stay usable while a source is offline.
    } finally {
      if (mounted) _loading.value = false;
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    model.removeListener(_metadataChanged);
    _entrance?.removeStatusListener(_onAnimationStatus);
    _loading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .8,
    builder: (_, scroll) => ListView.builder(
      key: const ValueKey('series-details-list'),
      controller: scroll,
      padding: const EdgeInsets.all(16),
      itemCount: _episodes.length + 3,
      itemBuilder: (_, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 14,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _loading,
                    builder: (_, loading, _) => loading
                        ? const LinearProgressIndicator(
                            minHeight: LibraryStyles.progressHeight,
                          )
                        : const SizedBox(height: 2),
                  ),
                ),
              ),
              _header,
            ],
          );
        }
        if (index == 1) {
          final latest = widget.latest;
          if (latest == null) return const SizedBox.shrink();
          final label = model.episodeLabel(latest);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.icon(
              key: const ValueKey('series-continue'),
              onPressed: () => widget.onPlay(latest),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(
                '继续观看 · ${label.isEmpty ? playbackTime((model.progressFor(latest)?['position'] as num?)?.toDouble() ?? 0) : label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        }
        if (index == 2) {
          return Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('播放列表', style: AppStyles.of(context).strong),
                ),
                IconButton(
                  tooltip: '排序与显示',
                  onPressed: _sortMenu,
                  icon: const Icon(Icons.sort_rounded),
                ),
              ],
            ),
          );
        }
        final item = _episodes[index - 3];
        final label = model.episodeLabel(item);
        return ListTile(
          key: ValueKey('series-episode:${item.id}'),
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            model.store
                        .get('watched', model.watchedKey(item))
                        ?.data['watched'] ==
                    true
                ? Icons.check_circle
                : Icons.play_circle_outline,
          ),
          title: Text(
            label.isEmpty ? model.displayTitle(item) : label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _episodeProgress(item),
          onTap: () => widget.onPlay(item),
          trailing: PopupMenuButton<String>(
            onSelected: (action) => action == 'versions'
                ? _chooseVersion(item)
                : widget.onAction(action, item),
            itemBuilder: (_) => [
              if ((_versions[mediaEpisodeKey(item)]?.length ?? 0) > 1)
                const PopupMenuItem(value: 'versions', child: Text('选择视频版本')),
              const PopupMenuItem(value: 'edit', child: Text('更正作品与集数')),
              const PopupMenuItem(value: 'link', child: Text('重新关联视频位置')),
              const PopupMenuItem(value: 'watched', child: Text('切换已看状态')),
              const PopupMenuItem(value: 'delete', child: Text('从影视库移除')),
            ],
          ),
        );
      },
    ),
  );

  Widget? _episodeProgress(SyncRecord item) {
    final progress = model.progressFor(item);
    final duration =
        (progress?['duration'] as num?)?.toDouble() ??
        model.mediaDuration(item);
    final label = playbackProgressLabel(progress, duration: duration);
    final technical = _allEpisodes.length == 1
        ? ''
        : MediaTechnicalInfo.forRecord(
            model.store,
            item,
            dimensions: model.mediaDimensions(item),
            duration: duration,
          ).label;
    if (label.isEmpty && technical.isEmpty) return null;
    final position = (progress?['position'] as num?)?.toDouble() ?? 0;
    final updated = DateTime.tryParse(
      '${progress?['updatedAt'] ?? ''}',
    )?.toLocal();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (technical.isNotEmpty)
            Text(technical, style: AppStyles.of(context).micro),
          if (label.isNotEmpty)
            Text(
              '$label${updated == null ? '' : ' · ${updated.month}/${updated.day} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}'}',
              style: LibraryStyles.of(context).episodeProgress,
            ),
          if (label.isNotEmpty && duration > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: (position / duration).clamp(0, 1),
                minHeight: LibraryStyles.progressHeight,
                borderRadius: LibraryStyles.progressRadius,
              ),
            ),
        ],
      ),
    );
  }
}

class _RetainedTab extends StatefulWidget {
  final Widget child;
  const _RetainedTab({required this.child});
  @override
  State<_RetainedTab> createState() => _RetainedTabState();
}

class _RetainedTabState extends State<_RetainedTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RepaintBoundary(child: widget.child);
  }
}
