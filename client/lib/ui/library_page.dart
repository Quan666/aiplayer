import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/continue_watching_presentation.dart';
import '../data/store.dart';
import '../data/media_presentation.dart';
import '../data/media_technical_info.dart';
import '../data/poster_cache.dart';
import '../data/library_snapshot.dart';
import '../sources/source.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'sources_page.dart';
import 'glass.dart';
import 'theme/library_styles.dart';
import 'media_artwork.dart';
import 'metadata_match_dialog.dart';
import 'metadata_tasks_sheet.dart';
import 'media_details_content.dart';
import 'media_file_details.dart';
import 'search_header.dart';
import 'navigation_reveal.dart';
import 'device_icon.dart';
import 'continue_watching_content.dart';
import 'artwork_scroll_scope.dart';

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

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  AppModel get model => widget.model;
  int page = 0;
  final _pages = PageController();
  final _sources = SourcesController();
  bool _sourcePointerTap = false;
  late bool _navigationCollapsed;
  String query = '';
  bool importing = false;
  bool _selecting = false, _removingSelection = false;
  final _selectedMedia = <String>{};

  void _updateSelection(VoidCallback update) {
    setState(() {
      update();
      _libraryContent = null;
    });
  }

  Future<void> _removeSelected() async {
    if (_removingSelection) return;
    final items = model.media
        .where((item) => _selectedMedia.contains(item.id))
        .toList();
    if (items.isEmpty) return;
    _updateSelection(() => _removingSelection = true);
    try {
      await _removeItems(items);
    } finally {
      if (mounted) {
        _updateSelection(() {
          _removingSelection = false;
          _selectedMedia.retainAll(model.media.map((item) => item.id));
          if (_selectedMedia.isEmpty) _selecting = false;
        });
      }
    }
  }

  bool _openingPlayer = false;
  final _navigationHidden = ValueNotifier(false);
  late bool _hideNavigationOnScroll;
  double _scrollTravel = 0;
  final _pendingPreviewRequests = <String>{};
  List<SyncRecord> _recent = const [];
  List<SyncRecord> _media = const [];
  LibrarySnapshot? _snapshot;
  Object? _snapshotVersion, _requestedSnapshotVersion;
  CancelToken? _snapshotCancel;
  List<MapEntry<String, List<SyncRecord>>> _posters = const [],
      _filesByGroup = const [];
  Widget? _libraryContent;
  Widget? _sourcesContent, _settingsContent;
  Object? _sourcesContentKey, _settingsContentKey;
  Object? _libraryDataKey, _chromeKey;
  bool? _libraryDesktop;
  bool _detailsVisible = false, _libraryNeedsRefresh = false;
  int _coveringRoutes = 0;
  bool _libraryScrolling = false;
  bool _foreground = true, _routeCurrent = true;

  void _onLibraryActivityChanged(bool active) {
    _libraryScrolling = active;
    if (!active) _refreshUncoveredLibrary();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
    _navigationCollapsed =
        model.store.local('desktopNavigationCollapsed') == true;
    model.addListener(_changed);
    _loadLibrarySnapshot();
  }

  void _changed() {
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
    if (!_hideNavigationOnScroll) _navigationHidden.value = false;
    _libraryNeedsRefresh |=
        _libraryDataKey != _libraryVersion ||
        _snapshotVersion != _snapshotReadVersion;
    if (!_foreground ||
        !_routeCurrent ||
        _detailsVisible ||
        _coveringRoutes > 0 ||
        (page == 0 && _libraryScrolling)) {
      return;
    }
    final refreshLibrary = page == 0 && _libraryNeedsRefresh;
    if (refreshLibrary) _refreshUncoveredLibrary();
    if (mounted && _chromeKey != _chromeVersion) {
      setState(() {});
    }
  }

  Object get _snapshotReadVersion => (
    model.store.recordsRevision('media'),
    model.store.recordsRevision('progress'),
    model.store.locationRevision,
    query.toLowerCase(),
  );

  bool get _canRefreshLibrary =>
      mounted &&
      _foreground &&
      _routeCurrent &&
      page == 0 &&
      !_libraryScrolling &&
      !_detailsVisible &&
      _coveringRoutes == 0;

  Future<void> _loadLibrarySnapshot() async {
    if (!_canRefreshLibrary) return;
    final version = _snapshotReadVersion;
    if (_requestedSnapshotVersion == version) return;
    _snapshotCancel?.cancel();
    final cancel = _snapshotCancel = CancelToken();
    _requestedSnapshotVersion = version;
    try {
      final snapshot = await model.loadLibrarySnapshot(
        query: query,
        cancel: cancel,
      );
      if (!mounted || cancel.cancelled || _snapshotCancel != cancel) return;
      _requestedSnapshotVersion = null;
      _snapshotCancel = null;
      if (!_canRefreshLibrary || version != _snapshotReadVersion) {
        _libraryNeedsRefresh = true;
        _refreshUncoveredLibrary();
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _snapshotVersion = version;
        _media = snapshot.media;
        _recent = snapshot.recent;
        _posters = snapshot.posters;
        _filesByGroup = snapshot.files;
        _selectedMedia.removeWhere((id) => !snapshot.byId.containsKey(id));
        _libraryNeedsRefresh = false;
        _libraryContent = null;
      });
    } on Cancelled {
      // Another search, a model change or disposal superseded this request.
    } catch (error) {
      if (mounted && _snapshotCancel == cancel) {
        _requestedSnapshotVersion = null;
        _snapshotCancel = null;
        showFailure(context, error);
      }
    }
  }

  Object get _libraryVersion => (
    model.store.recordsRevision('media'),
    model.store.recordsRevision('progress'),
    model.store.locationRevision,
    model.store.localPrefixRevision('preview:'),
    model.store.localPrefixRevision('mediaMetadata:'),
    model.store.localPrefixRevision('episodeTitle:'),
    model.store.localPrefixRevision('media-title-display:'),
    model.store.localKeyRevision('settings'),
    model.scanning,
  );

  Object get _chromeVersion => (
    model.metadataTasks.length,
    model.metadataTasks.where((task) => task.running).length,
    _hideNavigationOnScroll,
  );

  void _refreshUncoveredLibrary() {
    if (!mounted) return;
    // A details loader can persist new episodes without a separate global
    // notification. Recheck revisions when the covering route settles.
    _libraryNeedsRefresh |=
        _libraryDataKey != _libraryVersion ||
        _snapshotVersion != _snapshotReadVersion;
    if (!_foreground ||
        !_routeCurrent ||
        page != 0 ||
        _libraryScrolling ||
        _detailsVisible ||
        _coveringRoutes > 0 ||
        !_libraryNeedsRefresh) {
      return;
    }
    if (_snapshotVersion != _snapshotReadVersion) {
      _loadLibrarySnapshot();
      return;
    }
    _libraryNeedsRefresh = false;
    _libraryContent = null;
    setState(() {});
  }

  void _suspendLibrary() {
    _snapshotCancel?.cancel();
    _snapshotCancel = null;
    _requestedSnapshotVersion = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == current) return;
    _routeCurrent = current;
    if (!current) {
      _suspendLibrary();
    } else {
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _suspendLibrary();
    } else {
      _changed();
    }
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
    _selectedMedia.clear();
    _selecting = false;
    _snapshotCancel?.cancel();
    _snapshot = null;
    _snapshotVersion = _requestedSnapshotVersion = null;
    _libraryNeedsRefresh = true;
    _media = _recent = const [];
    _posters = _filesByGroup = const [];
    _libraryDataKey = _chromeKey = null;
    _libraryContent = null;
    _sourcesContent = _settingsContent = null;
    _sourcesContentKey = _settingsContentKey = null;
    _hideNavigationOnScroll = model.preferences.hideNavigationOnScroll;
    _loadLibrarySnapshot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_changed);
    _snapshotCancel?.cancel();
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
    final snapshot = _snapshot;
    if (episodes.isEmpty || _detailsVisible || snapshot == null) return;
    final complete = snapshot.seriesFor(episodes.first);
    if (complete.isNotEmpty) episodes = complete;
    _detailsVisible = true;
    ModalRoute<dynamic>? detailsRoute;
    try {
      await showGlassBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (sheet) {
          detailsRoute = ModalRoute.of(sheet);
          return _SeriesDetailsSheet(
            model: model,
            snapshot: snapshot,
            anchor: episodes.first,
            onPlay: _play,
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
    _libraryDataKey = _libraryVersion;
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final media = _media;
    final posters = _posters, files = _filesByGroup;
    final groupCount = posters.length + files.length;
    final recent = _recent;
    final inset = desktop ? 20.0 : 12.0;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return CustomScrollView(
      key: const PageStorageKey('library-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.viewport(.75),
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
                onChanged: (v) {
                  setState(() {
                    query = v;
                    _libraryContent = null;
                  });
                  _loadLibrarySnapshot();
                },
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
              const SizedBox(height: 8),
              if (!mobile && (importing || model.scanning)) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
              ],
              if (recent.isNotEmpty && query.isEmpty) ...[
                ContinueWatchingContent(
                  key: const ValueKey('library-continue-content'),
                  model: model,
                  items: recent,
                  limit: 10,
                  retainWhenOffscreen: true,
                  builder: (_, views) => _ContinueWatchingCarousel(
                    onOpenHistory: _history,
                    itemCount: recent.length.clamp(0, 10),
                    cardWidth: desktop ? 340 : 306,
                    cardHeight: 164 + (scale - 1).clamp(0, 2) * 60,
                    itemBuilder: (_, index) =>
                        _continueCard(recent[index], views[recent[index].id]),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _sectionHeading(
                      query.isEmpty ? '全部视频' : '搜索结果',
                      '$groupCount',
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed:
                        _removingSelection || (!_selecting && groupCount == 0)
                        ? null
                        : () => _updateSelection(() {
                            _selecting = !_selecting;
                            _selectedMedia.clear();
                          }),
                    icon: Icon(
                      _selecting ? Icons.done_rounded : Icons.checklist_rounded,
                    ),
                    label: Text(_selecting ? '完成' : '多选'),
                  ),
                ],
              ),
              if (_selecting)
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('已选 ${_selectedMedia.length} 个视频'),
                    TextButton(
                      onPressed: _removingSelection || groupCount == 0
                          ? null
                          : () => _updateSelection(() {
                              final ids = [...posters, ...files]
                                  .expand((group) => group.value)
                                  .map((item) => item.id)
                                  .toSet();
                              if (_selectedMedia.containsAll(ids)) {
                                _selectedMedia.removeAll(ids);
                              } else {
                                _selectedMedia.addAll(ids);
                              }
                            }),
                      child: Text(
                        groupCount > 0 &&
                                [...posters, ...files]
                                    .expand((group) => group.value)
                                    .every(
                                      (item) =>
                                          _selectedMedia.contains(item.id),
                                    )
                            ? '取消全选'
                            : '全选',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _removingSelection || _selectedMedia.isEmpty
                          ? null
                          : _removeSelected,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: Text(_removingSelection ? '处理中…' : '删除所选'),
                    ),
                  ],
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
        if (_snapshot == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (groupCount == 0)
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
            body: _HistorySnapshotContent(
              model: model,
              initialSnapshot: _snapshot,
              builder: (context, snapshot) {
                final items = snapshot?.recent;
                if (items == null) {
                  return const Center(child: CircularProgressIndicator());
                }
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
                        return ContinueWatchingContent(
                          model: model,
                          items: items,
                          builder: (_, views) => GridView.builder(
                            key: const PageStorageKey('library-history-grid'),
                            scrollCacheExtent: const ScrollCacheExtent.viewport(
                              .75,
                            ),
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
                            itemBuilder: (_, index) => _continueCard(
                              items[index],
                              views[items[index].id],
                            ),
                          ),
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

  Widget _continueCard(SyncRecord media, ContinueWatchingPresentation? view) {
    final position = view?.position ?? 0;
    final duration = view?.duration ?? 0;
    final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final episode = view?.episode ?? '';
    final title =
        view?.title ??
        '${media.data['metadataTitle'] ?? media.data['series'] ?? media.data['title'] ?? ''}';
    final otherDevice = view?.remoteDeviceName ?? '';
    return ClipRRect(
      key: ValueKey('history:${media.id}'),
      borderRadius: LibraryStyles.historyRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaArtwork(
            thumbnail: view?.thumbnail,
            loadWhileScrolling: true,
            onRequestPreview: view == null
                ? null
                : () => _requestPreview(media),
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
                        platform: view?.originDevicePlatform ?? '',
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
    final isSeries = !key.startsWith('file:');
    final representative = _snapshot?.representativeFor(media) ?? media;
    final poster = _snapshot?.detailsFor(media).poster ?? '';
    final title = isSeries
        ? model.seriesTitle(representative)
        : model.displayTitle(media);
    final selected =
        _selecting && items.every((item) => _selectedMedia.contains(item.id));
    void toggle() => _updateSelection(() {
      final ids = items.map((item) => item.id);
      if (selected) {
        _selectedMedia.removeAll(ids);
      } else {
        _selectedMedia.addAll(ids);
      }
    });
    return Semantics(
      key: ValueKey(key),
      button: true,
      label: '$title，${items.length} 个视频',
      checked: _selecting ? selected : null,
      child: _PosterTile(
        cache: model.posterCache,
        title: title,
        poster: poster,
        thumbnail: model.thumbnailPath(media.id),
        count: items.length,
        duration: model.mediaDuration(media),
        mediaId: media.id,
        selecting: _selecting,
        selected: selected,
        enabled: !_removingSelection,
        onTap: _selecting
            ? toggle
            : () => isSeries ? _details(title, items) : _play(media),
        onSelect: () => _updateSelection(() {
          _selecting = true;
          _selectedMedia.addAll(items.map((item) => item.id));
        }),
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
    _chromeKey = _chromeVersion;
    final desktop = MediaQuery.sizeOf(context).width >= 1000;
    if (_libraryDesktop != desktop) {
      _libraryDesktop = desktop;
      _libraryContent = null;
    }
    // Retaining a tab's State does not stop its parent from rebuilding it.
    // Reuse the actual widgets between tab/activity changes; each page listens
    // to its own relevant model revisions and preserves unsaved form fields.
    final sourcesKey = (model, page == 1);
    if (_sourcesContentKey != sourcesKey) {
      _sourcesContentKey = sourcesKey;
      _sourcesContent = SourcesPage(
        controller: _sources,
        model: model,
        active: page == 1,
        onImport: _files,
        onPlay: _play,
      );
    }
    final settingsKey = (model, page == 2);
    if (_settingsContentKey != settingsKey) {
      _settingsContentKey = settingsKey;
      _settingsContent = SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: SettingsPage(model: model, active: page == 2),
      );
    }
    return GlassBackground(
      onScrollActivityChanged: _onLibraryActivityChanged,
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
                        onPageChanged: (value) {
                          setState(() {
                            page = value;
                            _navigationHidden.value = false;
                            _scrollTravel = 0;
                          });
                          if (value == 0) _refreshUncoveredLibrary();
                        },
                        children: [
                          _RetainedTab(
                            active: page == 0,
                            child: _libraryContent ??= Builder(
                              builder: (context) => _library(context, desktop),
                            ),
                          ),
                          _RetainedTab(
                            active: page == 1,
                            child: _sourcesContent!,
                          ),
                          _RetainedTab(
                            active: page == 2,
                            child: _settingsContent!,
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
  final _arrows = ValueNotifier((left: false, right: false));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_refreshArrows);
  }

  void _refreshArrows() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final position = _scroll.position;
    // The buttons only change at either edge, not on every scroll pixel.
    _arrows.value = (
      left: position.pixels > position.minScrollExtent,
      right: position.pixels < position.maxScrollExtent,
    );
  }

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
    _arrows.dispose();
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
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
                  ValueListenableBuilder<({bool left, bool right})>(
                    valueListenable: _arrows,
                    builder: (context, arrows, _) => Row(
                      children: [
                        IconButton(
                          tooltip: '向左滚动',
                          onPressed: arrows.left ? () => _scrollPage(-1) : null,
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        IconButton(
                          tooltip: '向右滚动',
                          onPressed: arrows.right ? () => _scrollPage(1) : null,
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
                onNotification: (notification) {
                  // A resize or changed history can alter the scroll range
                  // without a scroll event. Refresh the arrow availability.
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.horizontal) {
                    _refreshArrows();
                  }
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
                        scrollCacheExtent: const ScrollCacheExtent.viewport(
                          .75,
                        ),
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

enum _PosterAction { select, remove }

const _posterActions = [
  PopupMenuItem(value: _PosterAction.select, child: Text('多选')),
  PopupMenuItem(value: _PosterAction.remove, child: Text('删除')),
];

class _PosterTile extends StatefulWidget {
  final PosterCache cache;
  final String title, poster, mediaId;
  final String? thumbnail;
  final int count;
  final double duration;
  final bool selecting, selected, enabled;
  final VoidCallback onTap, onDetails, onRequestPreview, onSelect;
  final VoidCallback? onRemove;
  const _PosterTile({
    required this.cache,
    required this.title,
    required this.poster,
    required this.thumbnail,
    required this.count,
    required this.duration,
    required this.mediaId,
    required this.selecting,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onSelect,
    required this.onDetails,
    this.onRemove,
    required this.onRequestPreview,
  });
  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  final _scale = ValueNotifier(1.0);

  void _runAction(_PosterAction action) {
    if (!widget.enabled) return;
    switch (action) {
      case _PosterAction.select:
        widget.onSelect();
      case _PosterAction.remove:
        widget.onRemove?.call();
    }
  }

  Future<void> _showActions([Offset? position]) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final box = context.findRenderObject()! as RenderBox;
    final anchor = overlay.globalToLocal(
      position ?? box.localToGlobal(box.size.center(Offset.zero)),
    );
    final action = await showMenu<_PosterAction>(
      context: context,
      position: RelativeRect.fromRect(
        anchor & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _posterActions,
    );
    if (mounted && action != null) _runAction(action);
  }

  // Scrolling under a stationary mouse must not start animations on every tile.
  void _press(bool pressed) => _scale.value = pressed ? .985 : 1;

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = GlassPalette.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: _scale,
      builder: (context, scale, child) => AnimatedScale(
        scale: scale,
        duration: MotionScope.duration(context, 140),
        curve: Curves.easeOutCubic,
        child: child,
      ),
      child: RepaintBoundary(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('play:${widget.mediaId}'),
              onTap: widget.enabled ? widget.onTap : null,
              onLongPress: widget.enabled ? _showActions : null,
              onSecondaryTapUp: widget.enabled
                  ? (details) => _showActions(details.globalPosition)
                  : null,
              onTapDown: (_) => _press(true),
              onTapUp: (_) => _press(false),
              onTapCancel: () => _press(false),
              borderRadius: LibraryStyles.posterRadius,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
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
                            loadWhileScrolling: true,
                            onRequestPreview: widget.onRequestPreview,
                          ),
                          if (widget.selecting && widget.selected)
                            ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .2),
                            ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: widget.selecting
                                ? Checkbox(
                                    key: ValueKey('select:${widget.mediaId}'),
                                    semanticLabel: widget.title,
                                    value: widget.selected,
                                    onChanged: widget.enabled
                                        ? (_) => widget.onTap()
                                        : null,
                                  )
                                : SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: IconButton(
                                        key: ValueKey(
                                          'details:${widget.mediaId}',
                                        ),
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
                              child: PopupMenuButton<_PosterAction>(
                                key: ValueKey(
                                  'media-actions:${widget.mediaId}',
                                ),
                                tooltip: '视频操作',
                                enabled: widget.enabled,
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  Icons.more_horiz_rounded,
                                  color: c.onMedia,
                                  shadows: LibraryStyles.of(
                                    context,
                                  ).posterIconShadows,
                                ),
                                onSelected: _runAction,
                                itemBuilder: (_) => _posterActions,
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
      ),
    );
  }
}

class _SeriesDetailsSheet extends StatefulWidget {
  final AppModel model;
  final LibrarySnapshot snapshot;
  final SyncRecord anchor;
  final ValueChanged<SyncRecord> onPlay;
  final ValueChanged<List<SyncRecord>> onMatch;
  final void Function(String, SyncRecord) onAction;
  const _SeriesDetailsSheet({
    required this.model,
    required this.snapshot,
    required this.anchor,
    required this.onPlay,
    required this.onMatch,
    required this.onAction,
  });
  @override
  State<_SeriesDetailsSheet> createState() => _SeriesDetailsSheetState();
}

class _SeriesDetailsSheetState extends State<_SeriesDetailsSheet>
    with WidgetsBindingObserver {
  late LibrarySnapshot _snapshot;
  late String _seriesKey;
  late List<SyncRecord> _allEpisodes;
  late List<SyncRecord> _episodes;
  late Widget _header;
  late MediaCollectionDetails _collectionDetails;
  SyncRecord? _latest;
  final _loading = ValueNotifier(false);
  final _cancel = CancelToken();
  Animation<double>? _entrance;
  bool _scheduled = false;
  bool _loadStarted = false, _refreshScheduled = false, _refreshing = false;
  bool _snapshotNeedsRefresh = true;
  bool _routeCurrent = true;
  bool _foreground = true, _sourceLoading = false;
  bool _sourceRefreshPending = false, _sourceRefreshScheduled = false;
  Timer? _sourceRefreshTimer;
  CancelToken? _sourceRefreshCancel;
  bool get _canRefreshSource => mounted && _routeCurrent && _foreground;
  late (int, int) _recordsVersion;
  late int _progressRevision;
  late int _episodeTitleRevision;
  late int _titleRevision;
  late String _sortFingerprint;
  String get _sortKey => 'directorySort:series:$_seriesKey';
  String get _currentSort =>
      model.directorySorting(_sortKey).toJson().toString();
  AppModel get model => widget.model;
  (int, int) get _currentRecordsVersion =>
      (model.store.recordsRevision('media'), model.store.locationRevision);
  bool get _needsMetadataRefresh =>
      _snapshotNeedsRefresh ||
      _recordsVersion != _currentRecordsVersion ||
      _progressRevision != model.store.recordsRevision('progress') ||
      _episodeTitleRevision !=
          model.store.localPrefixRevision('episodeTitle:') ||
      _titleRevision != model.titleTranslations.revision ||
      _sortFingerprint != _currentSort;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _setSnapshot(widget.snapshot, widget.anchor);
    _sortEpisodes();
    _sortFingerprint = _currentSort;
    _recordsVersion = _currentRecordsVersion;
    _progressRevision = model.store.recordsRevision('progress');
    _episodeTitleRevision = model.store.localPrefixRevision('episodeTitle:');
    _titleRevision = model.titleTranslations.revision;
    _updateHeader();
    model.addListener(_metadataChanged);
  }

  void _setSnapshot(LibrarySnapshot snapshot, SyncRecord anchor) {
    _snapshot = snapshot;
    _seriesKey = snapshot.seriesKeyFor(anchor);
    _allEpisodes = snapshot.seriesFor(anchor);
    _collectionDetails = snapshot.detailsFor(anchor);
    _episodes = snapshot.episodesFor(anchor);
    _latest = snapshot.latestFor(anchor);
  }

  Future<void> _chooseVersion(SyncRecord item) async {
    final versions = _snapshot.versionsFor(item);
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
    _scheduleMetadataRefresh();
  }

  void _scheduleMetadataRefresh() {
    if (!mounted ||
        !_routeCurrent ||
        !_foreground ||
        !_loadStarted ||
        _refreshScheduled ||
        _refreshing ||
        !_needsMetadataRefresh) {
      return;
    }
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (_canRefreshSource) unawaited(_refreshMetadata());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _sameEpisodes(List<SyncRecord> records) {
    if (records.length != _allEpisodes.length) return false;
    for (var index = 0; index < records.length; index++) {
      final before = _allEpisodes[index], after = records[index];
      if (before.id != after.id ||
          before.revision != after.revision ||
          before.version != after.version) {
        return false;
      }
    }
    return true;
  }

  Future<void> _refreshMetadata() async {
    if (!_canRefreshSource || _refreshing || !_needsMetadataRefresh) return;
    _refreshing = true;
    final version = _currentRecordsVersion;
    final progressRevision = model.store.recordsRevision('progress');
    final recordsInvalidated =
        _snapshotNeedsRefresh || version != _recordsVersion;
    final progressChanged = progressRevision != _progressRevision;
    var completed = false;
    try {
      LibrarySnapshot? snapshot;
      var records = _allEpisodes;
      if (recordsInvalidated || progressChanged) {
        snapshot = await model.loadLibrarySnapshot(cancel: _cancel);
        if (!mounted || !_routeCurrent || !_foreground) return;
        if (version != _currentRecordsVersion ||
            progressRevision != model.store.recordsRevision('progress')) {
          completed = true;
          return;
        }
        final anchor =
            snapshot.byId[_allEpisodes.first.id] ?? _allEpisodes.first;
        if (recordsInvalidated) records = snapshot.seriesFor(anchor);
        _latest = snapshot.latestFor(anchor);
      }
      final recordsChanged =
          recordsInvalidated &&
          records.isNotEmpty &&
          (!_sameEpisodes(records) || version.$2 != _recordsVersion.$2);
      final sortingChanged = _sortFingerprint != _currentSort;
      final namesRevision = model.store.localPrefixRevision('episodeTitle:');
      final titlesChanged =
          _episodeTitleRevision != namesRevision ||
          _titleRevision != model.titleTranslations.revision;
      _snapshotNeedsRefresh = false;
      _recordsVersion = version;
      _progressRevision = progressRevision;
      _episodeTitleRevision = namesRevision;
      _titleRevision = model.titleTranslations.revision;
      if (recordsChanged ||
          sortingChanged ||
          titlesChanged ||
          progressChanged) {
        setState(() {
          if (recordsChanged) {
            _setSnapshot(snapshot!, records.first);
          }
          if (recordsChanged || sortingChanged) _sortEpisodes();
          _sortFingerprint = _currentSort;
          _updateHeader();
        });
      }
      completed = true;
    } on Cancelled {
      // The details route was disposed while its shared snapshot was pending.
    } catch (_) {
      // Keep the current details usable; a later update may retry the snapshot.
    } finally {
      _refreshing = false;
      if (completed) _scheduleMetadataRefresh();
    }
  }

  void _sortEpisodes() {
    if (model.store.local(_sortKey) == null &&
        model.store.local('directorySort:default') == null) {
      _episodes = _snapshot.episodesFor(_allEpisodes.first);
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
    _header = MediaDetailsOverview(
      model: model,
      details: _collectionDetails,
      records: _allEpisodes,
      latest: _latest,
      onPlay: widget.onPlay,
      onSort: _sortMenu,
      loading: _loading,
      onMatch: () => widget.onMatch(_allEpisodes),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeCurrent;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!_routeCurrent) {
      _suspendSourceRefresh();
    } else if (!wasCurrent && _loadStarted) {
      _queueSourceRefresh();
    }
    if (_routeCurrent) _scheduleMetadataRefresh();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _suspendSourceRefresh();
    } else if (!wasForeground) {
      _queueSourceRefresh();
    }
  }

  void _suspendSourceRefresh() {
    _sourceRefreshTimer?.cancel();
    _sourceRefreshTimer = null;
    _sourceRefreshCancel?.cancel();
    if (_loadStarted) _sourceRefreshPending = true;
  }

  void _queueSourceRefresh() {
    _sourceRefreshPending = true;
    if (!_canRefreshSource || _sourceLoading || _sourceRefreshScheduled) return;
    _sourceRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sourceRefreshScheduled = false;
      if (_canRefreshSource && _sourceRefreshPending) unawaited(_load());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleLoad() {
    if (_scheduled) return;
    _scheduled = true;
    _entrance?.removeStatusListener(_onAnimationStatus);
    // Keep source loading separate from the sheet's entrance animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
        _scheduled = false;
        return;
      }
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (!_canRefreshSource || _sourceLoading) {
      _sourceRefreshPending = true;
      return;
    }
    _sourceRefreshTimer?.cancel();
    _sourceRefreshTimer = null;
    _sourceLoading = true;
    _sourceRefreshPending = false;
    final token = _sourceRefreshCancel = CancelToken();
    final initial = !_loadStarted;
    _loadStarted = true;
    if (initial) _loading.value = true;
    try {
      // The card snapshot can predate a commit made while this route opens.
      // Refresh once even when no further writes happen during source loading.
      await _refreshMetadata();
      if (!mounted || _cancel.cancelled) return;
      await model.loadSeriesEpisodes(widget.anchor, cancel: token);
      // The loader commits episodes through its worker. Refresh from the
      // prepared snapshot so the UI never computes collection aggregates.
    } catch (_) {
      // Existing metadata and episodes stay usable while a source is offline.
    } finally {
      _sourceLoading = false;
      _sourceRefreshCancel = null;
      if (mounted) {
        _loading.value = false;
        _scheduleMetadataRefresh();
        if (_canRefreshSource) {
          if (_sourceRefreshPending) {
            _queueSourceRefresh();
          } else {
            _sourceRefreshTimer = Timer(
              model.seriesRefreshDelay(widget.anchor),
              _queueSourceRefresh,
            );
          }
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sourceRefreshTimer?.cancel();
    _sourceRefreshCancel?.cancel();
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
      scrollCacheExtent: const ScrollCacheExtent.viewport(.75),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: _episodes.length + 1,
      itemBuilder: (_, index) {
        if (index == 0) return _header;
        final item = _episodes[index - 1];
        return MediaDetailsEpisodeTile(
          key: ValueKey('series-episode:${item.id}'),
          model: model,
          item: item,
          showTechnical: _allEpisodes.length != 1,
          onPlay: () => widget.onPlay(item),
          trailing: PopupMenuButton<String>(
            tooltip: '视频选项',
            onSelected: (action) {
              if (action == 'file-details') {
                showMediaFileDetails(context, model: model, item: item);
              } else if (action == 'versions') {
                _chooseVersion(item);
              } else {
                widget.onAction(action, item);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'file-details', child: Text('查看文件详情')),
              if (_snapshot.versionsFor(item).length > 1)
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
}

/// History keeps its prepared structure while covered or scrolling. Artwork
/// and playback labels have their own smaller presentation snapshot below it.
class _HistorySnapshotContent extends StatefulWidget {
  final AppModel model;
  final LibrarySnapshot? initialSnapshot;
  final Widget Function(BuildContext, LibrarySnapshot?) builder;

  const _HistorySnapshotContent({
    required this.model,
    required this.initialSnapshot,
    required this.builder,
  });

  @override
  State<_HistorySnapshotContent> createState() =>
      _HistorySnapshotContentState();
}

class _HistorySnapshotContentState extends State<_HistorySnapshotContent>
    with WidgetsBindingObserver {
  LibrarySnapshot? _snapshot;
  Object? _revision, _requestedRevision;
  CancelToken? _cancel;
  ValueListenable<bool>? _activity;
  bool _active = false, _foreground = true;

  Object get _currentRevision => (
    widget.model.store.recordsRevision('media'),
    widget.model.store.recordsRevision('progress'),
    widget.model.store.locationRevision,
  );

  bool get _canRead =>
      mounted && _active && _foreground && _activity?.value != true;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot;
    widget.model.addListener(_refresh);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final activity = ArtworkScrollScope.maybeOf(context);
    if (_activity != activity) {
      _activity?.removeListener(_refresh);
      _activity = activity;
      _activity?.addListener(_refresh);
    }
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _HistorySnapshotContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    oldWidget.model.removeListener(_refresh);
    widget.model.addListener(_refresh);
    _suspend();
    _snapshot = widget.initialSnapshot;
    _revision = null;
    _refresh();
  }

  void _suspend() {
    _cancel?.cancel();
    _cancel = null;
    _requestedRevision = null;
  }

  void _refresh() {
    if (!_canRead) {
      _suspend();
      return;
    }
    final revision = _currentRevision;
    if (_requestedRevision == revision || _revision == revision) return;
    _suspend();
    unawaited(_read(revision));
  }

  Future<void> _read(Object revision) async {
    final model = widget.model;
    final cancel = _cancel = CancelToken();
    _requestedRevision = revision;
    try {
      final snapshot = await model.loadLibrarySnapshot(cancel: cancel);
      if (!mounted || cancel.cancelled || _cancel != cancel) return;
      _cancel = null;
      _requestedRevision = null;
      if (!_canRead || revision != _currentRevision) {
        _refresh();
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _revision = revision;
      });
    } on Cancelled {
      // Retain the last snapshot and retry once the surface becomes idle.
    } catch (_) {
      // A failed read waits for new data or a replacement model, rather than
      // retrying on every scroll notification or widget build.
      if (mounted && !cancel.cancelled && _cancel == cancel) {
        _revision = revision;
      }
    } finally {
      if (_cancel == cancel) {
        _cancel = null;
        _requestedRevision = null;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _refresh();
  }

  @override
  void dispose() {
    _suspend();
    widget.model.removeListener(_refresh);
    _activity?.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _snapshot);
}

class _RetainedTab extends StatefulWidget {
  final Widget child;
  final bool active;
  const _RetainedTab({required this.child, required this.active});
  @override
  State<_RetainedTab> createState() => _RetainedTabState();
}

class _RetainedTabState extends State<_RetainedTab>
    with AutomaticKeepAliveClientMixin {
  final _scrolling = <ScrollableState>{};
  bool _stopScheduled = false;

  void _stopHiddenScrolls() {
    if (_stopScheduled) return;
    _stopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopScheduled = false;
      if (!mounted || widget.active) return;
      // Muting a scroll ticker alone leaves isScrollingNotifier true forever,
      // keeping shared artwork/background refresh scopes permanently busy.
      for (final scrollable in _scrolling.toList()) {
        if (!scrollable.mounted) continue;
        final position = scrollable.position;
        if (position.hasContentDimensions &&
            position.isScrollingNotifier.value) {
          position.jumpTo(
            position.pixels.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      }
      _scrolling.clear();
    });
  }

  bool _onScrollActivity(ScrollNotification notification) {
    if (notification is! ScrollStartNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final scrollable = notification.context
        ?.findAncestorStateOfType<ScrollableState>();
    if (scrollable == null) return false;
    if (notification is ScrollEndNotification) {
      _scrolling.remove(scrollable);
    } else {
      _scrolling.add(scrollable);
      if (!widget.active) _stopHiddenScrolls();
    }
    return false;
  }

  @override
  void didUpdateWidget(_RetainedTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) _stopHiddenScrolls();
  }

  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollActivity,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
