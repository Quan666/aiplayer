import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../data/library_catalog.dart';
import '../data/library_snapshot.dart';
import '../data/media_presentation.dart';
import '../data/media_technical_info.dart';
import '../sources/configuration.dart';
import '../sources/discovery.dart';
import '../sources/directory_sort.dart';
import '../sources/directory_sort_worker.dart';
import '../sources/favorites.dart';
import '../sources/source.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';
import 'player_page.dart';
import 'navigation_reveal.dart';
import 'media_details_content.dart';
import 'media_file_details.dart';
import 'media_artwork.dart';
import 'metadata_match_dialog.dart';
import 'metadata_tasks_sheet.dart';

String _sourceLabel(String kind) => switch (kind) {
  'smb' => 'SMB',
  'webdav' => 'WebDAV',
  'http' => '视频直链',
  _ => '本地视频',
};

IconData _protocolIcon(String kind) => switch (kind) {
  'smb' => Icons.dns_outlined,
  'webdav' => Icons.cloud_outlined,
  'http' => Icons.link_rounded,
  _ => Icons.smartphone_outlined,
};

Future<void> showDirectoryOptions(
  BuildContext context,
  DirectorySort initial,
  ValueChanged<DirectorySort> onChanged, {
  ValueChanged<DirectorySort>? onApplyAll,
  bool showSubtitleOption = true,
}) async {
  var value = initial;
  await showGlassBottomSheet<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        void change(DirectorySort next) {
          update(() => value = next);
          onChanged(next);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassSelect<String>(
                  label: '排序',
                  value: value.field,
                  options: const [
                    GlassOption('name', '名称'),
                    GlassOption('modified', '修改时间'),
                    GlassOption('size', '大小'),
                    GlassOption('type', '类型'),
                  ],
                  onChanged: (field) => change(value.copyWith(field: field)),
                ),
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  title: const Text('降序'),
                  value: value.descending,
                  onChanged: (descending) =>
                      change(value.copyWith(descending: descending)),
                ),
                if (showSubtitleOption)
                  SwitchListTile.adaptive(
                    title: const Text('显示字幕文件'),
                    value: value.showSubtitles,
                    onChanged: (show) =>
                        change(value.copyWith(showSubtitles: show)),
                  ),
                if (onApplyAll != null) ...[
                  const Divider(height: 8),
                  ListTile(
                    leading: const Icon(Icons.folder_copy_outlined),
                    title: const Text('应用到所有文件夹'),
                    onTap: () {
                      onApplyAll(value);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _FolderIcon extends StatelessWidget {
  final bool video;
  final String? fileName;
  const _FolderIcon({this.video = false, this.fileName});
  @override
  Widget build(BuildContext context) => Icon(
    fileName != null
        ? sourceFileIcon(fileName!)
        : video
        ? Icons.movie_outlined
        : Icons.folder_rounded,
    size: video || fileName != null ? 28 : 34,
    color: SettingsStyles.of(context).folderIcon(video: video),
  );
}

IconData sourceFileIcon(String name) {
  if (isVideo(name)) return Icons.movie_outlined;
  if (isSubtitle(name)) return Icons.subtitles_outlined;
  if (RegExp(
    r'\.(mp3|flac|aac|m4a|ogg|wav|opus)$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return Icons.audio_file_outlined;
  }
  if (RegExp(
    r'\.(jpg|jpeg|png|webp|gif|bmp|avif)$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return Icons.image_outlined;
  }
  if (RegExp(r'\.(zip|rar|7z|tar|gz)$', caseSensitive: false).hasMatch(name)) {
    return Icons.folder_zip_outlined;
  }
  if (RegExp(
    r'\.(txt|nfo|xml|json|md|pdf)$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

Future<void> _sourceFailure(BuildContext context, Object error, String action) {
  final failure = safeFailure(error, action: action);
  AppLog.instance.error('来源', failure.message);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      titlePadding: GlassMetrics.dialogTitlePadding,
      contentPadding: GlassMetrics.dialogContentPadding,
      actionsPadding: GlassMetrics.dialogActionsPadding,
      title: Text(action),
      content: SelectableText(failure.message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('好'),
        ),
      ],
    ),
  );
}

Future<void> _matchSourceRecords(
  BuildContext context,
  AppModel model,
  List<SyncRecord> records, {
  required bool automatic,
}) async {
  if (records.isEmpty || !context.mounted) return;
  if (automatic) {
    model.startMetadataTask(records);
    showGlassSuccess(context, '已开始后台识别');
    return;
  }
  if (!context.mounted) return;
  await showMetadataMatchDialog(
    context,
    model,
    '${records.first.data['series'] ?? records.first.data['title']}',
    season: '${records.first.data['season'] ?? ''}',
    mediaIds: records.map((item) => item.id).toSet(),
  );
}

Future<void> _closeSource(SourceAdapter? adapter) async {
  try {
    await adapter?.close();
  } catch (error) {
    AppLog.instance.warning('来源', safeFailure(error, action: '关闭连接失败').message);
  }
}

class SourcesController extends ChangeNotifier {
  void showRoot() => notifyListeners();
}

String _folderKey(String sourceId, String path) =>
    '$sourceId\u0000${p.posix.normalize(path.replaceAll('\\', '/'))}';

typedef _KnownFolder = LibraryFolderSnapshot;

class _KnownFolderIndex {
  Object? _key;
  int _request = 0;
  Map<String, _KnownFolder> _folders = {};
  LibrarySnapshot? snapshot;

  Future<Map<String, _KnownFolder>> load(AppModel model) async {
    final request = ++_request;
    final loaded = await model.loadLibrarySnapshot();
    if (request == _request) {
      accept(model, loaded);
    }
    return loaded.folders;
  }

  void accept(AppModel model, LibrarySnapshot loaded) {
    snapshot = loaded;
    _key = (
      model.store,
      model.store.recordsRevision('media'),
      model.store.locationRevision,
    );
    _folders = loaded.folders;
  }

  Map<String, _KnownFolder> read() => _folders;

  void clear() {
    _request++;
    snapshot = null;
    _key = null;
    _folders = const {};
  }
}

DirectoryCollection? _knownCollection(
  AppModel model,
  String sourceId,
  String path,
  Map<String, _KnownFolder> folders, {
  DirectoryCollection? preview,
}) {
  final folder = folders[_folderKey(sourceId, path)];
  // Large directory recognition and donor reconciliation are prepared by the
  // metadata worker. Lazy folder rows can reuse its preview without scanning
  // the complete folder again on the UI isolate.
  if ((folder?.entries.length ?? 0) >= 256 ||
      (preview?.videos.length ?? 0) >= 256) {
    return preview;
  }
  final value =
      preview ??
      (folder == null
          ? null
          : model.collectionFromEntries(sourceId, path, folder.entries));
  if (value == null || folder == null) return value;
  final paths = value.videos.map((entry) => entry.path).toSet();
  final records = [
    for (var index = 0; index < folder.entries.length; index++)
      if (paths.contains(folder.entries[index].path)) folder.records[index],
  ];
  final verified = records
      .where(
        (record) =>
            record.data['tmdbId'] != null || record.data['bangumiId'] != null,
      )
      .toList();
  final manual = verified
      .where(
        (record) => model.store.local('manualMetadata:${record.id}') == true,
      )
      .toList();
  final donors = manual.isEmpty ? verified : manual;
  final keys = donors.map(mediaSeriesKey).toSet();
  if (keys.length > 1) return value.withMetadata(null, {});
  if (keys.isEmpty) return value;
  return value.withMetadata(mediaFieldsSubject(donors.first.data), {
    ...value.episodeTitles,
    for (final record in records)
      if ((model.store.local('episodeTitle:${record.id}') as String?)
              ?.isNotEmpty ==
          true)
        '${record.data['episode']}':
            model.store.local('episodeTitle:${record.id}') as String,
  });
}

class _FolderArtwork extends StatelessWidget {
  final AppModel model;
  final String poster;
  final String? frame;
  final bool folder, favorite;
  final VoidCallback? onRequestPreview;
  const _FolderArtwork({
    required this.model,
    this.poster = '',
    this.frame,
    this.folder = true,
    this.favorite = false,
    this.onRequestPreview,
  });
  @override
  Widget build(BuildContext context) {
    Widget fallback() => Center(
      child: favorite
          ? Icon(
              Icons.folder_special_outlined,
              size: 32,
              color: GlassPalette.of(context).accent,
            )
          : _FolderIcon(video: !folder),
    );
    return ClipRRect(
      borderRadius: SettingsStyles.folderArtworkRadius,
      child: SizedBox(
        width: 52,
        height: 38,
        child: MediaArtwork(
          poster: poster,
          cache: model.posterCache,
          thumbnail: frame,
          loadWhileScrolling: true,
          placeholder: fallback(),
          onRequestPreview: onRequestPreview,
        ),
      ),
    );
  }
}

class SourcesPage extends StatefulWidget {
  final AppModel model;
  final bool active;
  final Future<void> Function() onImport;
  final Future<void> Function(SyncRecord) onPlay;
  final LanDiscovery? discovery;
  final SourcesController? controller;
  const SourcesPage({
    super.key,
    required this.model,
    required this.onImport,
    required this.onPlay,
    this.active = true,
    this.discovery,
    this.controller,
  });
  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> with WidgetsBindingObserver {
  AppModel get model => widget.model;
  CancelToken? scan;
  bool localOpen = false;
  Map<String, dynamic>? opened;
  String? initialPath, initialName;
  SourceFavorites get favorites => SourceFavorites(model.store);
  final _rootScroll = ScrollController();
  final _knownFolderIndex = _KnownFolderIndex();
  final _localSorter = DirectorySortWorker();
  late final _localSearch = _FolderSearchController(_localSorter);
  Object? _localEntriesKey;
  List<SourceEntry> _localEntriesSnapshot = const [];
  Map<String, SyncRecord> _localRecords = const {};
  int _localHiddenEntries = 0,
      _localSubtitleEntries = 0,
      _localHiddenSubtitleEntries = 0;
  CancelToken? _localSnapshotCancel;
  Completer<void>? _localSnapshotDone;
  bool _foreground = true, _visible = true;
  Object? _renderedRevision;

  Object get _rootRevision => (
    model.store,
    model.store.recordsRevision('media'),
    model.store.locationRevision,
    model.store.localKeyRevision('sources'),
    model.store.localKeyRevision(SourceFavorites.storageKey),
    model.store.localKeyRevision('settings'),
    model.store.localKeyRevision('directorySort:local:imports'),
    model.store.localPrefixRevision('browse:'),
    localOpen
        ? (
            model.store.recordsRevision('progress'),
            model.store.localPrefixRevision('preview:'),
            model.store.localPrefixRevision('mediaMetadata:'),
            model.store.localPrefixRevision('episodeTitle:'),
            model.store.localPrefixRevision('media-title-display:'),
            model.store.localPrefixRevision('directorySort:'),
            model.scanning,
            model.status,
          )
        : null,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    widget.controller?.addListener(_showRoot);
    widget.model.addListener(_refreshRoot);
    _localSearch.addListener(_localSearchChanged);
    _syncLocalSearch();
  }

  @override
  void didUpdateWidget(SourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_showRoot);
      widget.controller?.addListener(_showRoot);
    }
    if (oldWidget.model != widget.model) {
      _knownFolderIndex.clear();
      _localSnapshotCancel?.cancel();
      _localEntriesKey = null;
      _localEntriesSnapshot = const [];
      _localRecords = const {};
      _localHiddenEntries = _localSubtitleEntries =
          _localHiddenSubtitleEntries = 0;
      oldWidget.model.removeListener(_refreshRoot);
      widget.model.addListener(_refreshRoot);
    }
    _syncLocalSearch();
    if (localOpen && _localSearch.active) _prepareLocal();
  }

  void _refreshRoot() {
    if (!mounted || opened != null) return;
    // A retained tab rebuilds with the latest snapshots on activation.
    if (!widget.active || !_visible || !_foreground) return;
    unawaited(_loadLocalSnapshot());
    if (_renderedRevision == _rootRevision) return;
    if (localOpen) _prepareLocal();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _syncLocalSearch();
    _refreshRoot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncLocalSearch();
    if (_foreground) _refreshRoot();
  }

  void _showRoot() {
    NavigationRevealNotification.reveal(context);
    setState(() {
      opened = null;
      localOpen = false;
      initialPath = initialName = null;
    });
    _syncLocalSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rootScroll.hasClients) _rootScroll.jumpTo(0);
    });
  }

  void _openSource(Map<String, dynamic> source, {SourceFavorite? favorite}) {
    _localSearch.dismiss();
    NavigationRevealNotification.reveal(context);
    setState(() {
      opened = source;
      initialPath = favorite?.path;
      initialName = favorite?.name;
    });
    _syncLocalSearch();
  }

  void _showLocal(bool value) {
    _localSearch.dismiss();
    NavigationRevealNotification.reveal(context);
    setState(() => localOpen = value);
    _syncLocalSearch();
    if (value) _prepareLocal();
  }

  void _localSearchChanged() {
    if (mounted) setState(() {});
  }

  bool get _canLoadLocal =>
      mounted && widget.active && _foreground && _visible && opened == null;

  void _syncLocalSearch() {
    _localSearch.setActive(_canLoadLocal && localOpen);
    if (_canLoadLocal) {
      unawaited(_loadLocalSnapshot());
    } else {
      _localSnapshotCancel?.cancel();
    }
  }

  Object get _localSnapshotKey => (
    model.store,
    model.store.recordsRevision('media'),
    model.store.locationRevision,
  );

  Future<void> _loadLocalSnapshot() async {
    if (!_canLoadLocal) return;
    final pending = _localSnapshotDone;
    if (pending != null) return pending.future;
    final key = _localSnapshotKey;
    if (_localEntriesKey == key) return;
    final completion = _localSnapshotDone = Completer<void>();
    final owner = model;
    final token = _localSnapshotCancel = CancelToken();
    var retry = false;
    try {
      final snapshot = await owner.loadLibrarySnapshot(cancel: token);
      token.check();
      if (!_canLoadLocal || !identical(model, owner)) return;
      if (key != _localSnapshotKey) {
        retry = true;
        return;
      }
      _localEntriesKey = key;
      _knownFolderIndex.accept(owner, snapshot);
      _localEntriesSnapshot = snapshot.localEntries;
      _localRecords = snapshot.localRecords;
      _localHiddenEntries = snapshot.localHiddenEntries;
      _localSubtitleEntries = snapshot.localSubtitleEntries;
      _localHiddenSubtitleEntries = snapshot.localHiddenSubtitleEntries;
      _prepareLocal();
      setState(() {});
    } on Cancelled {
      retry = true;
    } catch (failure) {
      if (_canLoadLocal && identical(model, owner)) {
        AppLog.instance.warning('本地视频', safeFailure(failure).message);
      }
    } finally {
      _localSnapshotDone = null;
      completion.complete();
      if (identical(_localSnapshotCancel, token)) _localSnapshotCancel = null;
      if (retry && _canLoadLocal) unawaited(_loadLocalSnapshot());
    }
  }

  Future<void> _refreshSources() async {
    if (!_canLoadLocal) return;
    _localEntriesKey = null;
    await _loadLocalSnapshot();
    if (_canLoadLocal) setState(() {});
  }

  void _prepareLocal() {
    _localSearch.update(
      _localEntriesSnapshot,
      records: _localRecords,
      order: model.directorySorting('directorySort:local:imports'),
      hideHiddenFiles: model.preferences.hideHiddenFiles,
    );
  }

  int get _localCount {
    final hidden = model.preferences.hideHiddenFiles;
    final subtitles = model
        .directorySorting('directorySort:local:imports')
        .showSubtitles;
    return _localEntriesSnapshot.length -
        (hidden ? _localHiddenEntries : 0) -
        (subtitles ? 0 : _localSubtitleEntries) +
        (hidden && !subtitles ? _localHiddenSubtitleEntries : 0);
  }

  void _toggleFavorite(
    Map<String, dynamic> source, {
    SourceFavorite? favorite,
  }) {
    final value =
        favorite ??
        SourceFavorite(
          sourceId: source['id'] as String,
          path: '',
          name: source['label'] as String? ?? _sourceLabel(source['kind']),
        );
    final added = favorites.toggle(value);
    setState(() {});
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已添加到我的收藏' : '已取消收藏'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.removeListener(_showRoot);
    widget.model.removeListener(_refreshRoot);
    _localSnapshotCancel?.cancel();
    _localSearch.dispose();
    _localSorter.close();
    _rootScroll.dispose();
    scan?.cancel();
    super.dispose();
  }

  Future<void> _configure({
    Map<String, dynamic>? existing,
    DiscoveredSource? service,
  }) async {
    try {
      final initial = {...?existing, ...?service?.configuration};
      if (existing != null) {
        initial['password'] =
            await model.secrets.read(key: 'source:${existing['id']}') ?? '';
      }
      if (!mounted) return;
      final source = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => SourceEditorPage(
            initial: initial,
            editing: existing != null,
            discovery: widget.discovery,
          ),
        ),
      );
      if (source == null) return;
      final password = source.remove('password') as String;
      source['id'] = existing?['id'] ?? const Uuid().v4();
      await model.saveSource(source, password);
      AppLog.instance.info('来源', existing == null ? '已添加来源' : '已更新来源配置');
      if (!mounted) return;
      setState(() {
        if (opened?['id'] == source['id']) opened = source;
      });
    } catch (error) {
      if (mounted) await _sourceFailure(context, error, '保存来源失败');
    }
  }

  Future<void> _remove(Map<String, dynamic> source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        titlePadding: GlassMetrics.dialogTitlePadding,
        contentPadding: GlassMetrics.dialogContentPadding,
        actionsPadding: GlassMetrics.dialogActionsPadding,
        title: const Text('移除来源？'),
        content: Text(
          '移除“${source['label']}”的连接配置和凭证。\n服务器上的文件不会被删除，影视库中的视频可重新关联位置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '移除',
              style: SettingsStyles.of(context).destructiveAction,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await model.removeSource(source['id'] as String);
      favorites.removeSource(source['id'] as String);
      AppLog.instance.info('来源', '已移除来源连接');
      if (mounted) {
        setState(() {
          if (opened?['id'] == source['id']) opened = null;
        });
        _syncLocalSearch();
      }
    } catch (error) {
      if (mounted) await _sourceFailure(context, error, '移除来源失败');
    }
  }

  Future<void> _scanFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return;
      scan = CancelToken();
      await model.scan('local', path, cancel: scan);
    } catch (error) {
      if (mounted) await _sourceFailure(context, error, '读取文件夹失败');
    }
  }

  Widget _menu(Map<String, dynamic> source) => PopupMenuButton<String>(
    tooltip: '来源选项',
    icon: const Icon(Icons.more_horiz_rounded, size: 21),
    onSelected: (action) {
      if (action == 'edit') _configure(existing: source);
      if (action == 'remove') _remove(source);
      if (action == 'favorite') _toggleFavorite(source);
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
        height: GlassMetrics.menuItemHeight,
        padding: GlassMetrics.menuItemPadding,
        value: 'edit',
        child: Text('编辑来源'),
      ),
      if (source['kind'] != 'http')
        PopupMenuItem(
          height: GlassMetrics.menuItemHeight,
          padding: GlassMetrics.menuItemPadding,
          value: 'favorite',
          child: Text(
            favorites.contains(source['id'] as String, '') ? '取消收藏' : '收藏文件夹',
          ),
        ),
      const PopupMenuDivider(height: GlassMetrics.menuDividerHeight),
      const PopupMenuItem(
        height: GlassMetrics.menuItemHeight,
        padding: GlassMetrics.menuItemPadding,
        value: 'remove',
        child: Text('移除来源…'),
      ),
    ],
  );

  Widget _root() {
    final desktop = MediaQuery.sizeOf(context).width >= 1000;
    final sources = model.sources;
    final sourcesById = {for (final source in sources) source['id']: source};
    final saved = favorites.available(
      sources.map((source) => source['id'] as String),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: desktop ? GlassMetrics.desktopPageInset : 12,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: desktop ? double.infinity : 960,
          ),
          child: RefreshIndicator(
            onRefresh: _refreshSources,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              key: const PageStorageKey('sources-scroll'),
              controller: _rootScroll,
              scrollCacheExtent: const ScrollCacheExtent.viewport(.75),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.only(
                    top:
                        GlassMetrics.pageTopPadding(context) +
                        MediaQuery.paddingOf(context).top,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _FolderHeader(
                          title: '来源',
                          actions: [
                            IconButton(
                              tooltip: '添加来源',
                              onPressed: () => _configure(),
                              icon: const Icon(Icons.add_rounded),
                            ),
                          ],
                        ),
                        _FolderRow(
                          title: '本地视频',
                          subtitle: '$_localCount 个视频',
                          leading: Icon(
                            _protocolIcon('local'),
                            size: 27,
                            color: GlassPalette.of(context).accent,
                          ),
                          onTap: () => _showLocal(true),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverReorderableList(
                  itemCount: sources.length,
                  proxyDecorator: (child, index, animation) => AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, child) => Material(
                      elevation:
                          6 * Curves.easeInOut.transform(animation.value),
                      child: child,
                    ),
                  ),
                  onReorderItem: (oldIndex, newIndex) {
                    if (oldIndex == newIndex) return;
                    final order = sources
                        .map((source) => source['id'] as String)
                        .toList();
                    order.insert(newIndex, order.removeAt(oldIndex));
                    model.reorderSources(order);
                    setState(() {});
                  },
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(source['id']),
                      index: index,
                      child: _FolderRow(
                        title:
                            source['label'] as String? ??
                            _sourceLabel(source['kind']),
                        subtitle: _sourceLabel(source['kind']),
                        leading: Icon(
                          _protocolIcon(source['kind']),
                          size: 27,
                          color: GlassPalette.of(context).accent,
                        ),
                        trailing: _menu(source),
                        onTap: () => _openSource(source),
                      ),
                    );
                  },
                ),
                if (saved.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      key: const ValueKey('favorites-heading'),
                      padding: const EdgeInsets.fromLTRB(2, 16, 2, 6),
                      child: Text(
                        '我的收藏',
                        style: AppStyles.of(context).sectionTitle,
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: saved.length,
                    itemBuilder: (context, index) {
                      final item = saved[index];
                      final source = sourcesById[item.sourceId]!;
                      final collection = _knownCollection(
                        model,
                        item.sourceId,
                        item.path,
                        _knownFolderIndex.read(),
                        preview: model.catalog
                            .directoryPreview(
                              item.sourceId,
                              item.path,
                              allowStale: true,
                            )
                            ?.collection,
                      );
                      return _FolderRow(
                        key: ValueKey('favorite:${item.key}'),
                        title: item.name,
                        subtitle:
                            source['label'] as String? ??
                            _sourceLabel(source['kind']),
                        leading: _FolderArtwork(
                          model: model,
                          poster: collection?.poster ?? '',
                          favorite: true,
                        ),
                        onTap: () => _openSource(source, favorite: item),
                        onLongPress: () => _favoriteOptions(source, item),
                        trailing: PopupMenuButton<String>(
                          tooltip: '收藏选项',
                          icon: const Icon(Icons.more_horiz_rounded, size: 20),
                          onSelected: (_) =>
                              _toggleFavorite(source, favorite: item),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              height: GlassMetrics.menuItemHeight,
                              padding: GlassMetrics.menuItemPadding,
                              value: 'remove',
                              child: Text('取消收藏'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 20 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _favoriteOptions(
    Map<String, dynamic> source,
    SourceFavorite item,
  ) => showGlassBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.star_border_rounded),
        title: const Text('取消收藏'),
        onTap: () {
          Navigator.pop(context);
          _toggleFavorite(source, favorite: item);
        },
      ),
    ),
  );

  Future<void> _sortLocal() {
    _localSearch.dismiss();
    return showDirectoryOptions(
      context,
      model.directorySorting('directorySort:local:imports'),
      (value) {
        model.setDirectorySorting('directorySort:local:imports', value);
        _prepareLocal();
        setState(() {});
      },
      onApplyAll: model.applyDirectorySortingToAll,
    );
  }

  Future<void> _localMetadataOptions(SyncRecord item) async {
    final action = await showGlassBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('查看文件详情'),
              onTap: () => Navigator.pop(context, 'file-details'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('重新识别影视资料'),
              onTap: () => Navigator.pop(context, 'auto'),
            ),
            ListTile(
              leading: const Icon(Icons.manage_search_rounded),
              title: const Text('手动搜索影视资料'),
              onTap: () => Navigator.pop(context, 'search'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'file-details') {
      await showMediaFileDetails(context, model: model, item: item);
      return;
    }
    await _matchSourceRecords(context, model, [
      item,
    ], automatic: action == 'auto');
    if (mounted) setState(() {});
  }

  Widget _local() {
    final media = _localSearch.results;
    return RefreshIndicator(
      onRefresh: _refreshSources,
      child: _ContentList(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: media.length,
        itemBuilder: (context, index) {
          final item = _localSearch.resultRecords[media[index].path]!;
          final progress = playbackProgressLabel(model.progressFor(item));
          final technical = MediaTechnicalInfo.forRecord(
            model.store,
            item,
            dimensions: model.mediaDimensions(item),
            duration: model.mediaDuration(item),
          ).label;
          return _FolderRow(
            title: model.displayTitle(item),
            subtitle: [
              technical,
              progress,
            ].where((line) => line.isNotEmpty).join('\n'),
            video: true,
            leading: _localArtwork(item),
            onTap: () {
              _localSearch.dismiss();
              widget.onPlay(item);
            },
            onLongPress: () {
              _localSearch.dismiss();
              _localMetadataOptions(item);
            },
          );
        },
        children: [
          _FolderHeader(
            title: '本地视频',
            onBack: () => _showLocal(false),
            actions: [
              IconButton(
                tooltip: '搜索',
                onPressed: _localSearch.toggle,
                icon: const Icon(Icons.search_rounded, size: 21),
              ),
              IconButton(
                tooltip: '排序与显示',
                onPressed: _sortLocal,
                icon: const Icon(Icons.sort_rounded, size: 21),
              ),
              IconButton(
                tooltip: '导入视频',
                onPressed: widget.onImport,
                icon: const Icon(Icons.add_rounded),
              ),
              if (!Platform.isAndroid && !Platform.isIOS)
                PopupMenuButton<String>(
                  tooltip: '本地视频选项',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (_) => _scanFolder(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      height: GlassMetrics.menuItemHeight,
                      padding: GlassMetrics.menuItemPadding,
                      enabled: !model.scanning,
                      value: 'scan',
                      child: const Text('扫描文件夹'),
                    ),
                  ],
                ),
            ],
          ),
          if (_localSearch.shown) _FolderSearchField(_localSearch),
          if (model.scanning) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    model.status,
                    style: AppStyles.of(context).bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () => scan?.cancel(),
                  child: const Text('停止'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (media.isEmpty)
            _EmptyFolder(
              text: _localSearch.query.isEmpty ? '还没有本地视频' : '没有匹配的视频',
              action: _localSearch.query.isNotEmpty
                  ? null
                  : TextButton.icon(
                      onPressed: widget.onImport,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('导入视频'),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _localArtwork(SyncRecord media) {
    final poster = media.data['poster'] as String? ?? '';
    final path = model.thumbnailPath(media.id);
    Widget fallback() => const Center(child: _FolderIcon(video: true));
    final artwork = MediaArtwork(
      poster: poster,
      cache: model.posterCache,
      thumbnail: path,
      loadWhileScrolling: true,
      placeholder: fallback(),
      onRequestPreview: poster.isEmpty
          ? () => model.ensureMediaPreview(media.id)
          : null,
    );
    return ClipRRect(
      borderRadius: SettingsStyles.folderArtworkRadius,
      child: SizedBox(width: 64, height: 42, child: artwork),
    );
  }

  @override
  Widget build(BuildContext context) {
    _renderedRevision = _rootRevision;
    if (opened case final source?) {
      return SourceBrowser(
        key: ValueKey('${source['id']}:${source.hashCode}:$initialPath'),
        model: model,
        active: widget.active,
        source: source,
        embedded: true,
        initialPath: initialPath,
        initialName: initialName,
        onExit: () {
          NavigationRevealNotification.reveal(context);
          setState(() => opened = null);
          _syncLocalSearch();
        },
        onPlay: widget.onPlay,
        onEdit: () => _configure(existing: source),
        onRemove: () => _remove(source),
      );
    }
    return PopScope(
      canPop: !localOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && localOpen) _showLocal(false);
      },
      child: AnimatedSwitcher(
        duration: MotionScope.duration(context, 180),
        child: KeyedSubtree(
          key: ValueKey(localOpen),
          child: localOpen ? _local() : _root(),
        ),
      ),
    );
  }
}

// One latest search per folder. Existing prepared records supply searchable
// names; typing never reads the database or fetches another directory.
class _FolderSearchController extends ChangeNotifier {
  final DirectorySortWorker worker;
  final text = TextEditingController();
  final focus = FocusNode();
  List<SourceEntry> results = const [];
  Map<String, SyncRecord> resultRecords = const {};
  List<SourceEntry> _entries = const [];
  Map<String, SyncRecord> _records = const {};
  Map<String, String> _titles = const {};
  DirectorySort? _order;
  bool _hideHiddenFiles = false;
  Object? _key;
  Object? _sortedKey;
  List<SourceEntry> _sorted = const [];
  Timer? _debounce;
  int _revision = 0, _focusRevision = 0;
  bool active = true, shown = false, _disposed = false;
  String get query => text.text.trim();

  _FolderSearchController(this.worker);

  void update(
    List<SourceEntry> entries, {
    Map<String, SyncRecord> records = const {},
    Map<String, String> titles = const {},
    DirectorySort? order,
    bool hideHiddenFiles = false,
  }) {
    final key = (
      entries,
      records,
      titles,
      order?.field,
      order?.descending,
      order?.showSubtitles,
      hideHiddenFiles,
    );
    if (_key == key) return;
    _key = key;
    _entries = entries;
    _records = records;
    _titles = titles;
    _order = order;
    _hideHiddenFiles = hideHiddenFiles;
    _schedule();
  }

  void changed(String _) {
    _schedule(debounce: true);
    notifyListeners();
  }

  void toggle() {
    shown = !shown;
    if (!shown) {
      dismiss();
      text.clear();
      _schedule();
    } else {
      final revision = ++_focusRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && active && shown && revision == _focusRevision) {
          focus.requestFocus();
        }
      });
    }
    notifyListeners();
  }

  void clear() {
    text.clear();
    changed('');
  }

  void dismiss() {
    _focusRevision++;
    // Clear the field's remembered focus even when a tapped button already
    // owns primary focus. Route restoration must not reopen the keyboard.
    focus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    _revision++;
    _debounce?.cancel();
    worker.cancelPending();
    if (!value) {
      dismiss();
    } else {
      _schedule();
    }
  }

  void _schedule({bool debounce = false}) {
    final revision = ++_revision;
    _debounce?.cancel();
    worker.cancelSearch();
    if (!active || _disposed) return;
    if (debounce && query.isNotEmpty) {
      _debounce = Timer(
        const Duration(milliseconds: 180),
        () => _run(revision),
      );
    } else {
      unawaited(_run(revision));
    }
  }

  Future<void> _run(int revision) async {
    bool current() => !_disposed && active && revision == _revision;
    if (!current()) return;
    try {
      var found = _entries;
      final order = _order;
      if (order != null) {
        final key = (
          found,
          order.field,
          order.descending,
          order.showSubtitles,
          _hideHiddenFiles,
        );
        if (_sortedKey == key) {
          found = _sorted;
        } else {
          found = found.length < 256
              ? order.apply(found, hideHiddenFiles: _hideHiddenFiles)
              : await worker.sort(
                  found,
                  order,
                  hideHiddenFiles: _hideHiddenFiles,
                );
          if (!current()) return;
          _sortedKey = key;
          _sorted = found;
        }
      }
      if (!current()) return;
      if (query.isNotEmpty) {
        found = found.length < 256
            ? searchDirectoryEntries(
                found,
                query,
                records: _records,
                titles: _titles,
              )
            : await worker.search(
                found,
                query,
                records: _records,
                titles: _titles,
              );
      }
      if (!current()) return;
      if (identical(results, found) && identical(resultRecords, _records)) {
        return;
      }
      results = found;
      resultRecords = _records;
      notifyListeners();
    } on DirectorySortCancelled {
      // Pause, navigation or newer text owns the next result.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _debounce?.cancel();
    worker.cancelSearch();
    text.dispose();
    focus.dispose();
    super.dispose();
  }
}

class _FolderSearchField extends StatelessWidget {
  final _FolderSearchController search;
  const _FolderSearchField(this.search);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: TextField(
      key: const ValueKey('folder-search-field'),
      controller: search.text,
      focusNode: search.focus,
      onChanged: search.changed,
      onSubmitted: (_) => search.dismiss(),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索',
        isDense: true,
        contentPadding: SettingsStyles.searchFieldPadding,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        suffixIcon: search.query.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                onPressed: search.clear,
                style: IconButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: const EdgeInsets.all(6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
      ),
    ),
  );
}

class _FolderHeader extends StatelessWidget {
  final String title;
  final bool showTitle;
  final VoidCallback? onBack;
  final List<Widget> actions;
  const _FolderHeader({
    required this.title,
    this.showTitle = true,
    this.onBack,
    this.actions = const [],
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: [
        if (onBack != null) ...[
          IconButton(
            tooltip: '返回',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          ),
          const SizedBox(width: 2),
        ],
        Expanded(
          child: !showTitle
              ? const SizedBox.shrink()
              : Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SettingsStyles.of(
                    context,
                  ).sourceTitle(nested: onBack != null),
                ),
        ),
        ...actions,
      ],
    ),
  );
}

class _ContentList extends StatelessWidget {
  final ScrollPhysics? physics;
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  const _ContentList({
    required this.children,
    this.physics,
    this.itemCount = 0,
    this.itemBuilder,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = MediaQuery.sizeOf(context).width >= 1000;
      final inset = desktop
          ? GlassMetrics.desktopPageInset
          : (constraints.maxWidth < 600 ? 12.0 : 24.0);
      return ListView.builder(
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.viewport(.75),
        padding: EdgeInsets.fromLTRB(
          inset,
          GlassMetrics.pageTopPadding(context) +
              MediaQuery.paddingOf(context).top,
          inset,
          20 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: children.length + itemCount,
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? double.infinity : 960,
            ),
            child: SizedBox(
              width: double.infinity,
              child: index < children.length
                  ? children[index]
                  : itemBuilder!(context, index - children.length),
            ),
          ),
        ),
      );
    },
  );
}

class _FolderRow extends StatelessWidget {
  final String title, subtitle;
  final bool video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing, leading;
  const _FolderRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.video = false,
    this.trailing,
    this.leading,
  });
  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ListTile(
      dense: true,
      visualDensity: SettingsStyles.folderRowDensity,
      horizontalTitleGap: 10,
      minLeadingWidth: 52,
      shape: SettingsStyles.folderRowShape,
      leading: SizedBox(
        width: 52,
        height: 42,
        child: Center(child: leading ?? _FolderIcon(video: video)),
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppStyles.of(context).title14,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: video ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.of(context).caption,
            ),
      trailing:
          trailing ??
          (video
              ? Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: GlassPalette.of(context).muted,
                )
              : null),
      onTap: onTap,
      onLongPress: onLongPress,
    ),
  );
}

class _EmptyFolder extends StatelessWidget {
  final String text;
  final Widget? action;
  const _EmptyFolder({required this.text, this.action});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64),
    child: Column(
      children: [
        Icon(
          Icons.folder_open_rounded,
          size: 44,
          color: SettingsStyles.of(context).emptyFolderIcon,
        ),
        const SizedBox(height: 12),
        Text(text, style: AppStyles.of(context).secondary),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

String _fileSize(int size) => size <= 0
    ? ''
    : size >= 1024 * 1024 * 1024
    ? '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)} GB'
    : '${(size / 1024 / 1024).toStringAsFixed(1)} MB';

typedef SourceConnector =
    Future<SourceAdapter> Function(
      Map<String, dynamic> source,
      String password,
    );

/// Full-page editor. The alias below keeps older callers source-compatible.
class SourceEditorPage extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final bool editing;
  final SourceConnector? connector;
  final LanDiscovery? discovery;
  const SourceEditorPage({
    super.key,
    this.initial,
    this.editing = false,
    this.connector,
    this.discovery,
  });
  @override
  State<SourceEditorPage> createState() => _SourceEditorPageState();
}

typedef SourceDialog = SourceEditorPage;

class _SourceEditorPageState extends State<SourceEditorPage> {
  String kind = 'smb', smbSecurity = 'auto';
  bool encrypted = true, testing = false;
  final fields = {
    for (final key in [
      'label',
      'host',
      'port',
      'share',
      'url',
      'path',
      'user',
      'password',
      'domain',
    ])
      key: TextEditingController(),
  };
  String error = '', connectionInfo = '';
  @override
  void initState() {
    super.initState();
    _apply(sourceFormValues(widget.initial));
  }

  void _apply(Map<String, dynamic> values) {
    kind = values['kind'] as String? ?? kind;
    encrypted = values['encrypted'] as bool? ?? encrypted;
    smbSecurity = values['smbSecurity'] as String? ?? smbSecurity;
    for (final entry in fields.entries) {
      if (values.containsKey(entry.key)) {
        entry.value.text = '${values[entry.key] ?? ''}';
      }
    }
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _parseHost() {
    try {
      final parsed = splitPastedSourceAddress(fields['host']!.text, kind: kind);
      if (parsed != null) setState(() => _apply(parsed));
      return true;
    } catch (failure) {
      setState(() => error = safeFailure(failure).message);
      return false;
    }
  }

  Map<String, dynamic>? _configuration() {
    if (!_parseHost()) return null;
    try {
      final value = buildSourceConfiguration(
        kind: kind,
        fields: {
          for (final entry in fields.entries) entry.key: entry.value.text,
        },
        encrypted: encrypted,
        smbSecurity: smbSecurity,
      );
      setState(() => error = '');
      return value;
    } catch (failure) {
      setState(() => error = safeFailure(failure).message);
      return null;
    }
  }

  void _save() {
    final value = _configuration();
    if (value != null) Navigator.pop(context, value);
  }

  Future<void> _discover() async {
    final selected = await showDialog<DiscoveredSource>(
      context: context,
      builder: (_) =>
          _DiscoveryPicker(discovery: widget.discovery ?? LanDiscovery()),
    );
    if (selected == null || !mounted) return;
    setState(() {
      final values = sourceFormValues(selected.configuration);
      if (fields['label']!.text.isNotEmpty) values.remove('label');
      _apply(values);
      error = '';
      connectionInfo = '';
    });
  }

  Future<void> _test({bool chooseShare = false}) async {
    final configuration = _configuration();
    if (configuration == null) return;
    if (chooseShare) configuration['share'] = '';
    final password = configuration.remove('password') as String;
    setState(() {
      testing = true;
      connectionInfo = '';
    });
    SourceAdapter? adapter;
    try {
      adapter =
          await (widget.connector?.call(configuration, password) ??
              connectSource(configuration, password: password));
      if (!mounted) return;
      final String result;
      if (kind == 'http') {
        final video = await adapter.stat('');
        result = video.seekable ? '连接成功，支持拖动播放。' : '视频可访问；服务器不支持范围读取，拖动可能受限。';
      } else {
        final entries = await adapter.list('');
        final dialect = adapter is SmbServerSource
            ? adapter.dialect
            : adapter is SmbSource
            ? adapter.connection.dialect
            : 0;
        result =
            '${dialect == 0 ? '连接成功' : smbDialectLabel(dialect)} · ${entries.length} ${kind == 'smb' && (configuration['share'] as String).isEmpty ? '个共享' : '个项目'}';
        if (!mounted) return;
        if (chooseShare) {
          setState(() => testing = false);
          final value = await showGlassChoice<String>(
            context: context,
            title: '选择共享',
            value: fields['share']!.text,
            options: [
              const GlassOption('', '所有共享', icon: Icons.dns_outlined),
              for (final entry in entries)
                GlassOption(
                  entry.name,
                  entry.name,
                  icon: Icons.folder_outlined,
                ),
            ],
          );
          if (!mounted) return;
          if (value != null) setState(() => fields['share']!.text = value);
        }
      }
      AppLog.instance.info('来源', '${_sourceLabel(kind)} $result');
      if (mounted) setState(() => connectionInfo = result);
    } catch (failure) {
      if (mounted) {
        setState(() => testing = false);
        await _sourceFailure(context, failure, '连接测试失败');
      }
    } finally {
      await _closeSource(adapter);
      if (mounted) setState(() => testing = false);
    }
  }

  void _changeKind(String value) => setState(() {
    kind = value;
    error = '';
    connectionInfo = '';
    fields['port']!.text = value == 'smb'
        ? '445'
        : encrypted
        ? '443'
        : '80';
    if (value == 'webdav' && fields['path']!.text.isEmpty) {
      fields['path']!.text = '/';
    }
  });
  Widget _field(
    String key,
    String label, {
    TextInputType? keyboard,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: fields[key],
      enabled: !testing,
      obscureText: key == 'password',
      autocorrect: false,
      enableSuggestions: key != 'password',
      style: AppStyles.of(context).bodyLarge,
      keyboardType: keyboard ?? TextInputType.text,
      onChanged: key == 'host'
          ? (value) {
              if (value.contains('://') || value.startsWith(r'\\')) {
                _parseHost();
              }
            }
          : null,
      onEditingComplete: key == 'host'
          ? () {
              _parseHost();
              FocusScope.of(context).nextFocus();
            }
          : null,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassPalette.of(context).canvas,
    appBar: AppBar(
      title: Text(widget.editing ? '编辑来源' : '添加来源'),
      actions: [
        TextButton(onPressed: testing ? null : _save, child: const Text('保存')),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.editing) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: testing ? null : _discover,
                        icon: const Icon(Icons.wifi_find_rounded, size: 20),
                        label: const Text('扫描局域网'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  GlassSelect<String>(
                    label: '来源类型',
                    value: kind,
                    enabled: !testing && !widget.editing,
                    options: const [
                      GlassOption(
                        'smb',
                        'SMB / Samba',
                        icon: Icons.dns_outlined,
                      ),
                      GlassOption(
                        'webdav',
                        'WebDAV',
                        icon: Icons.cloud_outlined,
                      ),
                      GlassOption(
                        'http',
                        'HTTP / HTTPS 直链',
                        icon: Icons.link_rounded,
                      ),
                    ],
                    onChanged: _changeKind,
                  ),
                  const SizedBox(height: 16),
                  _field('label', '显示名称（可选）'),
                  if (kind == 'http')
                    _field('url', '视频直链', keyboard: TextInputType.url),
                  if (kind != 'http') ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _field(
                            'host',
                            '服务器地址',
                            keyboard: TextInputType.url,
                            hint: kind == 'webdav'
                                ? '主机名、IP 或完整 WebDAV 地址'
                                : '主机名或 IP 地址',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _field(
                            'port',
                            '端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (kind == 'webdav') ...[
                    _field('path', 'WebDAV 目录', hint: '/dav/'),
                    SwitchListTile.adaptive(
                      title: const Text('HTTPS 加密'),
                      value: encrypted,
                      onChanged: testing
                          ? null
                          : (value) => setState(() {
                              if (fields['port']!.text ==
                                  (encrypted ? '443' : '80')) {
                                fields['port']!.text = value ? '443' : '80';
                              }
                              encrypted = value;
                            }),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        '填写服务器提供的 WebDAV 地址，网页首页和分享链接不能用于目录浏览。',
                        style: AppStyles.of(context).caption,
                      ),
                    ),
                  ],
                  _field('user', '用户名（可选）'),
                  _field('password', '密码（可选）'),
                  if (kind == 'smb') ...[
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        fields['share']!.text.isEmpty
                            ? '所有共享'
                            : fields['share']!.text,
                      ),
                      trailing: TextButton(
                        onPressed: testing
                            ? null
                            : () => _test(chooseShare: true),
                        child: const Text('浏览共享'),
                      ),
                    ),
                    ExpansionTile(
                      title: Text('高级', style: AppStyles.of(context).bodyLarge),
                      children: [
                        _field('domain', '域（可选）'),
                        GlassSelect<String>(
                          label: '连接安全',
                          value: smbSecurity,
                          enabled: !testing,
                          options: const [
                            GlassOption('auto', '自动协商（SMB 2–3.1.1）'),
                            GlassOption('sign', '要求签名'),
                            GlassOption('encrypt', '要求 SMB 3 加密'),
                          ],
                          onChanged: (value) =>
                              setState(() => smbSecurity = value),
                        ),
                        const SizedBox(height: 14),
                        _field('share', '共享名称（可选）', hint: '仅当服务器禁止枚举共享时填写'),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(error, style: AppStyles.of(context).error),
                    ),
                  if (connectionInfo.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        connectionInfo,
                        style: AppStyles.of(context).accent,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: testing ? null : () => _test(),
                      icon: testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lan_outlined, size: 18),
                      label: Text(testing ? '连接中…' : '测试连接'),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DiscoveryPicker extends StatefulWidget {
  final LanDiscovery discovery;
  const _DiscoveryPicker({required this.discovery});
  @override
  State<_DiscoveryPicker> createState() => _DiscoveryPickerState();
}

class _DiscoveryPickerState extends State<_DiscoveryPicker> {
  final cancel = CancelToken();
  DiscoverySnapshot snapshot = const DiscoverySnapshot(running: true);
  @override
  void initState() {
    super.initState();
    widget.discovery.scan(
      cancel: cancel,
      onUpdate: (value) {
        if (mounted && !cancel.cancelled) setState(() => snapshot = value);
      },
    );
  }

  @override
  void dispose() {
    cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    titlePadding: GlassMetrics.dialogTitlePadding,
    contentPadding: GlassMetrics.dialogContentPadding,
    actionsPadding: GlassMetrics.dialogActionsPadding,
    title: const Text('局域网设备'),
    content: SizedBox(
      width: 440,
      height: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (snapshot.running)
            LinearProgressIndicator(
              minHeight: 2,
              value: snapshot.total == 0
                  ? null
                  : snapshot.completed / snapshot.total,
            ),
          if (snapshot.warning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                snapshot.warning,
                style: AppStyles.of(context).bodySmall,
              ),
            ),
          Expanded(
            child: snapshot.services.isEmpty
                ? Center(
                    child: Text(snapshot.running ? '正在查找…' : '未发现设备，可手动填写地址'),
                  )
                : ListView.builder(
                    itemCount: snapshot.services.length,
                    itemBuilder: (context, index) {
                      final service = snapshot.services[index];
                      return ListTile(
                        dense: true,
                        minVerticalPadding: 4,
                        minLeadingWidth: 20,
                        horizontalTitleGap: 8,
                        contentPadding: GlassMetrics.menuItemPadding,
                        leading: Icon(_protocolIcon(service.kind)),
                        title: Text(service.name),
                        subtitle: Text(
                          '${_sourceLabel(service.kind)} · ${service.endpoint}',
                          style: AppStyles.of(context).bodySmall,
                        ),
                        onTap: () => Navigator.pop(context, service),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(snapshot.running ? '停止' : '关闭'),
      ),
    ],
  );
}

class SourceBrowser extends StatefulWidget {
  final AppModel model;
  final Map<String, dynamic> source;
  final String? associateId;
  final String? initialPath, initialName;
  final bool embedded, active;
  final VoidCallback? onExit, onEdit, onRemove;
  final Future<void> Function(SyncRecord)? onPlay;
  const SourceBrowser({
    super.key,
    required this.model,
    required this.source,
    this.associateId,
    this.initialPath,
    this.initialName,
    this.embedded = false,
    this.active = true,
    this.onExit,
    this.onEdit,
    this.onRemove,
    this.onPlay,
  });
  @override
  State<SourceBrowser> createState() => _SourceBrowserState();
}

class _SourceBrowserState extends State<SourceBrowser>
    with WidgetsBindingObserver {
  SourceAdapter? adapter;
  List<SourceEntry> _entries = [];
  List<SourceEntry> get entries => _entries;
  set entries(List<SourceEntry> value) {
    _entries = value;
    _updateSearch();
  }

  final paths = <({String path, String name})>[];
  bool busy = true;
  bool playing = false;
  String error = '';
  int generation = 0;
  final cancel = CancelToken();
  CancelToken _directoryCancel = CancelToken();
  final scroll = ScrollController();
  final offsets = <String, double>{};
  final _queries = <String, String>{};
  final cached = <String, List<SourceEntry>>{};
  List<SourceEntry> allEntries = [];
  DirectoryCollection? collection;
  Object? _recordsKey;
  List<SyncRecord> _collectionRecords = const [];
  Map<String, SyncRecord> _mediaByPath = const {};
  bool _hasCollectionHeader = false;
  List<SyncRecord>? _headerSeriesRecords;
  MediaCollectionDetails? _headerDetails;
  SyncRecord? _headerLatest;
  final folderCollections = <String, DirectoryCollection?>{};
  final folderQueue = <({SourceEntry entry, String parent})>[];
  final inspectedFolders = <String>{};
  bool inspectingFolder = false;
  bool _modelRefreshScheduled = false;
  bool _modelDirty = false;
  Map<String, _KnownFolder> knownFolders = {};
  final _knownFolderIndex = _KnownFolderIndex();
  final _listingFingerprints = <String, String>{};
  final _completedInspections = <String, (String, Object)>{};
  Object? _catalogRevision;
  int? _cacheRevision;
  CancelToken? _refreshCancel;
  CancelToken? _loadCancel;
  Future<void>? _refreshWork;
  Future<void>? _inspectionWork;
  bool _routeCurrent = true, _foreground = true;
  bool _refreshPending = false, _refreshScheduled = false;
  bool _openPending = false;
  Future<void>? _manualRefreshWork;
  bool get _canRefresh =>
      mounted &&
      widget.active &&
      _routeCurrent &&
      _foreground &&
      !playing &&
      !widget.model.clearingCaches;

  // A favorite is a separate navigation entry point. Its stack must never
  // replace the ordinary source stack with a path missing its ancestors.
  String get _stateKey =>
      'sourceBrowser:${widget.source['id']}'
      '${widget.initialPath == null ? '' : ':favorite:${widget.initialPath}'}';
  int get _rootDepth => widget.initialPath?.isNotEmpty == true ? 1 : 0;
  String get _sortKey => 'directorySort:${widget.source['id']}:$current';
  DirectorySort get sorting => widget.model.directorySorting(_sortKey);
  SourceFavorites get favorites => SourceFavorites(widget.model.store);
  bool get hideHidden => widget.model.preferences.hideHiddenFiles;
  final _sorter = DirectorySortWorker();
  late final _search = _FolderSearchController(_sorter);
  List<SourceEntry> get displayedEntries => _search.results;
  Object? _searchRecordsKey;
  Map<String, SyncRecord> _searchRecords = const {};

  void _searchChanged() {
    if (mounted) setState(() {});
  }

  void _updateSearch() {
    final sourceId = widget.source['id'] as String;
    final key = (_knownFolderIndex._key, sourceId, current);
    if (_searchRecordsKey != key) {
      _searchRecordsKey = key;
      _searchRecords =
          _knownFolderIndex
              .snapshot
              ?.folders[_folderKey(sourceId, current)]
              ?.recordsByPath ??
          const {};
    }
    _search.update(
      entries,
      records: _searchRecords,
      titles: collection?.episodeTitles ?? const {},
    );
  }

  void _restoreSearch() {
    _search.text.text = _queries[current] ?? '';
    _search.shown = _search.query.isNotEmpty;
    _search.changed(_search.query);
  }

  final _sortedListings = Expando<(Object, Future<List<SourceEntry>>)>();
  Future<List<SourceEntry>> _visible(List<SourceEntry> values) async {
    if (!_canRefresh) throw const DirectorySortCancelled();
    final ticket = generation;
    final order = sorting;
    final hidden = hideHidden;
    final key = (order.field, order.descending, order.showSubtitles, hidden);
    final cached = _sortedListings[values];
    final future = cached != null && cached.$1 == key
        ? cached.$2
        : values.length < 256
        ? Future.value(order.apply(values, hideHiddenFiles: hidden))
        : _sorter.sort(values, order, hideHiddenFiles: hidden);
    _sortedListings[values] = (key, future);
    try {
      final result = await future;
      if (!_canRefresh || ticket != generation) {
        throw const DirectorySortCancelled();
      }
      final currentOrder = sorting;
      final currentKey = (
        currentOrder.field,
        currentOrder.descending,
        currentOrder.showSubtitles,
        hideHidden,
      );
      // Sorting can change while a worker is busy. Only publish the newest
      // preference snapshot, sharing its pending job with metadata callers.
      if (key == currentKey) return result;
      return await _visible(values);
    } catch (_) {
      if (identical(_sortedListings[values]?.$2, future)) {
        _sortedListings[values] = null;
      }
      rethrow;
    }
  }

  String get current => paths.lastOrNull?.path ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _search.addListener(_searchChanged);
    _search.setActive(_canRefresh);
    widget.model.addListener(_modelChanged);
    _cacheRevision = widget.model.cacheRevision;
    final stored = widget.model.store.local(_stateKey);
    if (stored is Map && widget.associateId == null) {
      final savedPaths = stored['paths'];
      if (savedPaths is List && widget.initialPath == null) {
        for (final row in savedPaths.whereType<Map>()) {
          if (row['path'] is String && row['name'] is String) {
            paths.add((path: row['path'], name: row['name']));
          }
        }
      }
      final savedOffsets = stored['offsets'];
      if (savedOffsets is Map) {
        for (final entry in savedOffsets.entries) {
          if (entry.key is String && entry.value is num) {
            offsets[entry.key] = (entry.value as num).toDouble().clamp(
              0,
              10000000,
            );
          }
        }
      }
    }
    final initial = widget.initialPath;
    if (initial != null && initial.isNotEmpty) {
      final segments = initial
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList();
      paths.add((
        path: initial,
        name: widget.initialName ?? segments.lastOrNull ?? initial,
      ));
    }
    _restoreSearch();
    _open();
  }

  void _modelChanged() {
    _modelDirty = true;
    final cacheRevision = widget.model.cacheRevision;
    if (_cacheRevision != null && _cacheRevision != cacheRevision) {
      _refreshCancel?.cancel();
      _loadCancel?.cancel();
      _directoryCancel.cancel();
      cached.clear();
      folderCollections.clear();
      folderQueue.clear();
      inspectedFolders.clear();
      _listingFingerprints.clear();
      _completedInspections.clear();
      _openPending = true;
    }
    _cacheRevision = cacheRevision;
    final revision = widget.model.catalog.directoryInspectionRevision(
      widget.source['id'],
    );
    if (_catalogRevision != revision) {
      _catalogRevision = revision;
      _completedInspections.clear();
      _directoryCancel.cancel();
      _queueRefresh();
    }
    if (!_canRefresh) return;
    if (!mounted || _modelRefreshScheduled) return;
    _modelRefreshScheduled = true;
    scheduleMicrotask(() async {
      var applied = false;
      try {
        if (!_canRefresh) return;
        _modelDirty = false;
        final ticket = generation;
        final sorted = busy ? null : await _visible(allEntries);
        if (!_canRefresh || ticket != generation) return;
        final known = await _knownFolderIndex.load(widget.model);
        if (!_canRefresh || ticket != generation) return;
        final metadataChanged = !identical(knownFolders, known);
        knownFolders = known;
        setState(() {
          if (sorted != null && !busy) entries = sorted;
          // Preview completions and playback updates still refresh visible rows,
          // but must not rescan every episode and visited folder. Episode names
          // and progress are read directly from the model by each visible row.
          if (metadataChanged) {
            collection = _knownCollection(
              widget.model,
              widget.source['id'],
              current,
              knownFolders,
              preview: collection,
            );
            for (final path in folderCollections.keys.toList()) {
              folderCollections[path] = _knownCollection(
                widget.model,
                widget.source['id'],
                path,
                knownFolders,
                preview: folderCollections[path],
              );
            }
          }
          _prepareCollectionDetails();
        });
        applied = true;
      } on Cancelled {
        // Snapshot work may finish after this browser/model was disposed.
      } on DirectorySortCancelled {
        // Navigation/disposal superseded this listing.
      } finally {
        if (!applied) _modelDirty = true;
        _modelRefreshScheduled = false;
        // Failed/cancelled reads stay dirty for the next notification/resume.
        // Only a successful read may immediately consume a coalesced update.
        if (applied && _canRefresh && _modelDirty) _modelChanged();
      }
    });
  }

  @override
  void didUpdateWidget(SourceBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = !mapEquals(oldWidget.source, widget.source);
    if (oldWidget.model != widget.model || sourceChanged) {
      _directoryCancel.cancel();
      _refreshCancel?.cancel();
      oldWidget.model.cancelDirectoryRecognition();
    }
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_modelChanged);
      widget.model.addListener(_modelChanged);
      _modelDirty = true;
    }
    if (widget.active &&
        (!oldWidget.active || oldWidget.model != widget.model)) {
      if (_modelDirty) _modelChanged();
      _queueRefresh();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_inspectNextFolder());
      });
    }
    if (!widget.active) _pauseRefresh();
    if (oldWidget.model != widget.model || sourceChanged) unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeCurrent;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!_routeCurrent) {
      _pauseRefresh();
    } else if (!wasCurrent) {
      _queueRefresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _pauseRefresh();
    } else if (!wasForeground) {
      _queueRefresh();
    }
  }

  void _pauseRefresh() {
    _search.setActive(false);
    _refreshCancel?.cancel();
    _loadCancel?.cancel();
    _directoryCancel.cancel();
    _refreshPending = true;
  }

  void _queueRefresh() {
    if (_canRefresh) _search.setActive(true);
    if (_canRefresh && _openPending) {
      unawaited(_open());
      return;
    }
    if (_canRefresh && _directoryCancel.cancelled) {
      _directoryCancel = CancelToken();
    }
    if (_canRefresh && _modelDirty) _modelChanged();
    if (_canRefresh) unawaited(_inspectNextFolder());
    if (widget.source['kind'] == 'http' || widget.associateId != null) return;
    _refreshPending = true;
    if (!_canRefresh ||
        busy ||
        _loadCancel != null ||
        _refreshWork != null ||
        _inspectionWork != null ||
        _refreshScheduled) {
      return;
    }
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (_canRefresh &&
          !busy &&
          _loadCancel == null &&
          _inspectionWork == null &&
          _refreshWork == null &&
          _refreshPending) {
        _refreshPending = false;
        final work = _refreshCurrent();
        _refreshWork = work;
        unawaited(
          work.whenComplete(() {
            if (identical(_refreshWork, work)) _refreshWork = null;
            _resumePendingRefresh();
          }),
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resumePendingRefresh() {
    if (!_canRefresh ||
        busy ||
        _loadCancel != null ||
        _refreshWork != null ||
        _inspectionWork != null ||
        widget.source['kind'] == 'http' ||
        widget.associateId != null) {
      return;
    }
    // Directory reads are driven by navigation, lifecycle/configuration
    // changes and explicit refresh gestures. An idle folder never polls.
    if (_refreshPending) _queueRefresh();
  }

  Future<void> _refreshManually() {
    if (!_canRefresh) return Future.value();
    return _manualRefreshWork ??= _runManualRefresh().whenComplete(() {
      _manualRefreshWork = null;
    });
  }

  Future<void> _runManualRefresh() async {
    final ticket = generation;
    final owner = widget.model;
    final active = _refreshWork;
    if (active != null) {
      await active;
      return;
    }
    // Do not overlap an in-flight listing/metadata reconciliation. A gesture
    // shares that read rather than reconnecting and resetting the folder UI.
    await _inspectionWork;
    if (!_canRefresh || ticket != generation || widget.model != owner) return;
    if (busy || _loadCancel != null) return;
    if (adapter == null || error.isNotEmpty) {
      await _open();
      return;
    }
    _refreshPending = false;
    final work = _refreshCurrent(manual: true);
    _refreshWork = work;
    try {
      await work;
    } finally {
      if (identical(_refreshWork, work)) _refreshWork = null;
      _resumePendingRefresh();
    }
  }

  Future<List<SourceEntry>> _readDirectory(
    String directory,
    CancelToken token,
  ) async {
    token.check();
    // A refresh owns its connection. Cancelling a hidden page must not close
    // the adapter used by the bounded folder preview queue.
    SourceAdapter? connection;
    final model = widget.model;
    final sourceId = widget.source['id'] as String;
    final direct = widget.source['kind'] == 'http';
    Future<void>? closing;
    Future<void> close() => closing ??= _closeSource(connection);
    Future<List<SourceEntry>> read() async {
      final next = await model.adapter(sourceId);
      if (token.cancelled) {
        await _closeSource(next);
        throw const Cancelled();
      }
      connection = next;
      return direct ? [await next.stat('')] : await next.list(directory);
    }

    try {
      return await Future.any([
        read(),
        token.whenCancelled.then((_) async {
          await close();
          throw const Cancelled();
        }),
      ]);
    } finally {
      await close();
    }
  }

  Future<String> _listingFingerprint(
    String directory,
    List<SourceEntry> found,
    CancelToken token,
  ) async {
    token.check();
    final prepare = widget.model.catalog.prepareDirectory;
    final context = 'hideHidden:$hideHidden';
    // Production AppModel binds this to its existing metadata worker. Memory
    // stores in widget tests use the same deterministic preparation directly.
    final prepared = prepare == null
        ? prepareDirectoryInspection(
            widget.source['id'],
            directory,
            context,
            found,
          )
        : await prepare(widget.source['id'], directory, context, found, token);
    token.check();
    return prepared.fingerprint;
  }

  Future<void> _refreshCurrent({bool manual = false}) async {
    final ticket = generation;
    final directory = current;
    final token = _refreshCancel = CancelToken();
    try {
      final found = await _readDirectory(directory, token);
      final fingerprint = await _listingFingerprint(directory, found, token);
      if (!_canRefresh || ticket != generation || directory != current) return;
      if (_listingFingerprints[directory] == fingerprint) {
        if (_inspectionComplete(directory, fingerprint)) {
          return;
        }
        _directoryCancel.cancel();
        _directoryCancel = token;
        await _inspectCurrent(
          ticket,
          directory,
          found,
          fingerprint: fingerprint,
          reconcile: false,
        );
        return;
      }
      final visible = await _visible(found);
      if (!_canRefresh || ticket != generation || directory != current) return;
      if (cached.length >= 16 && !cached.containsKey(directory)) {
        _completedInspections.remove(cached.keys.first);
        _listingFingerprints.remove(cached.keys.first);
        cached.remove(cached.keys.first);
      }
      cached[directory] = found;
      allEntries = found;
      // Retain the controller and its current offset when a server adds files.
      setState(() {
        error = '';
        entries = visible;
      });
      _directoryCancel.cancel();
      _directoryCancel = token;
      await _inspectCurrent(ticket, directory, found, fingerprint: fingerprint);
    } on Cancelled {
      // Hidden/closed pages and newer directories own their next refresh.
    } on DirectorySortCancelled {
      // Navigation superseded the worker result.
    } catch (failure) {
      if (manual && mounted && _canRefresh && ticket == generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(safeFailure(failure, action: '刷新目录失败').message),
          ),
        );
      }
    } finally {
      if (identical(_refreshCancel, token)) _refreshCancel = null;
    }
  }

  bool _inspectionComplete(String directory, String fingerprint) =>
      _completedInspections[directory] ==
      (
        fingerprint,
        widget.model.catalog.directoryInspectionRevision(widget.source['id']),
      );

  Future<void> _inspectCurrent(
    int ticket,
    String directory,
    List<SourceEntry> found, {
    String? fingerprint,
    bool reconcile = true,
  }) async {
    if (widget.associateId != null) return;
    final token = _directoryCancel;
    final revision = widget.model.catalog.directoryInspectionRevision(
      widget.source['id'],
    );
    try {
      final prepared =
          fingerprint ?? await _listingFingerprint(directory, found, token);
      if (!_canRefresh || ticket != generation || current != directory) return;
      final visible = await _visible(found);
      // Opening a folder establishes its complete episode list immediately.
      // A cached poster may describe an older subset of files and must never
      // substitute for the listing that was just opened.
      final resolved = reconcile
          ? await widget.model.synchronizeDirectoryEntriesInBackground(
              widget.source['id'],
              directory,
              visible,
              cancel: token,
            )
          : collection;
      token.check();
      if (!_canRefresh || ticket != generation || current != directory) return;
      // File membership can be complete while optional metadata is still
      // missing. Its retry must not reimport the same directory each time.
      _listingFingerprints[directory] = prepared;
      if (reconcile && resolved != null) {
        if (!_canRefresh ||
            token.cancelled ||
            ticket != generation ||
            current != directory) {
          return;
        }
        final known = await _knownFolderIndex.load(widget.model);
        if (!_canRefresh ||
            token.cancelled ||
            ticket != generation ||
            current != directory) {
          return;
        }
        knownFolders = known;
        setState(() => _setCollection(resolved));
      }
      final value = await widget.model.catalog.inspect(
        widget.source['id'],
        directory,
        visible,
        cancel: token,
      );
      if (_canRefresh &&
          !token.cancelled &&
          ticket == generation &&
          current == directory) {
        // Catalogue caches supply presentation metadata. The current listing
        // remains authoritative even if that cache knows fewer episode paths.
        final enriched = value == null || value.subject == null
            ? resolved ?? collection ?? value
            : resolved?.withMetadata(value.subject, value.episodeTitles) ??
                  value;
        final updated = value == null || (!reconcile && value.subject == null)
            ? enriched
            : await widget.model.synchronizeCollectionInBackground(
                widget.source['id'],
                enriched!,
                importMissing: true,
                cancel: token,
              );
        if (!_canRefresh ||
            token.cancelled ||
            ticket != generation ||
            current != directory) {
          return;
        }
        if (reconcile || !identical(updated, collection)) {
          final known = await _knownFolderIndex.load(widget.model);
          if (!_canRefresh ||
              token.cancelled ||
              ticket != generation ||
              current != directory) {
            return;
          }
          knownFolders = known;
          setState(() {
            _setCollection(updated);
            folderCollections[directory] = collection;
          });
        }
        if (revision !=
            widget.model.catalog.directoryInspectionRevision(
              widget.source['id'],
            )) {
          _refreshPending = true;
          return;
        }
        var metadataComplete =
            updated?.subject != null && value?.metadataComplete != false;
        if (metadataComplete && value?.subject == null) {
          // A failed lookup may leave the existing subject usable. It cannot
          // mark an older subset of episode titles as fully loaded.
          metadataComplete = await widget.model.catalog
              .collectionEpisodeNamesCovered(
                updated!,
                updated.episodeTitles,
                cancel: token,
              );
          token.check();
          if (!_canRefresh || ticket != generation || current != directory) {
            return;
          }
        }
        if (widget.model.catalog.strategy() == 'off' ||
            (value == null && resolved == null) ||
            metadataComplete) {
          _completedInspections[directory] = (prepared, revision);
        }
        // Incomplete metadata stays retryable on the next entry or pull.
      }
    } on Cancelled {
      // Navigation/disposal cancels optional metadata work.
    } on DirectorySortCancelled {
      // A new directory replaced this optional inspection.
    } catch (failure) {
      // Optional catalog work must never surface as an unhandled future or
      // replace a usable file listing with a metadata error.
      if (mounted && ticket == generation) {
        AppLog.instance.warning('来源资料', safeFailure(failure).message);
      }
    } finally {
      if (mounted && ticket == generation && !token.cancelled) {
        _resumePendingRefresh();
      }
    }
  }

  void _queueFolder(SourceEntry entry) {
    if (widget.associateId != null ||
        !entry.directory ||
        inspectedFolders.contains(entry.path)) {
      return;
    }
    if (adapter is SmbServerSource && current.isEmpty) return;
    inspectedFolders.add(entry.path);
    folderQueue.add((entry: entry, parent: current));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inspectNextFolder();
    });
    // Artwork requests can arrive after the last scroll frame has finished.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _inspectNextFolder() async {
    if (inspectingFolder || busy || adapter == null || !_canRefresh) {
      return;
    }
    inspectingFolder = true;
    try {
      while (folderQueue.isNotEmpty && !busy && _canRefresh) {
        final ticket = generation;
        final token = _directoryCancel;
        final connection = adapter;
        if (connection == null) break;
        final batch = folderQueue.take(4).toList();
        folderQueue.removeRange(0, batch.length);
        final results = await Future.wait(
          batch.map((item) async {
            if (item.parent != current) {
              inspectedFolders.remove(item.entry.path);
              return null;
            }
            try {
              final preview = (await widget.model.catalog.loadDirectoryPreview(
                widget.source['id'],
                item.entry.path,
                modified: item.entry.modified,
                cancel: token,
              ))?.collection;
              if (preview?.subject != null) {
                final resolved = await widget.model
                    .synchronizeCollectionInBackground(
                      widget.source['id'],
                      preview!,
                      importMissing: false,
                      cancel: token,
                    );
                if (!mounted ||
                    ticket != generation ||
                    item.parent != current) {
                  return null;
                }
                return (path: item.entry.path, collection: resolved);
              }
              final found =
                  cached[item.entry.path] ??
                  await _readDirectory(item.entry.path, token);
              if (!mounted ||
                  ticket != generation ||
                  !identical(adapter, connection)) {
                return null;
              }
              if (cached.length >= 16 && !cached.containsKey(item.entry.path)) {
                _completedInspections.remove(cached.keys.first);
                _listingFingerprints.remove(cached.keys.first);
                cached.remove(cached.keys.first);
              }
              cached[item.entry.path] = found;
              final visible = await _visible(found);
              final value =
                  await widget.model.catalog.inspect(
                    widget.source['id'],
                    item.entry.path,
                    visible,
                    directoryModified: item.entry.modified,
                    cancel: token,
                  ) ??
                  (visible.length < 256
                      ? widget.model.collectionFromEntries(
                          widget.source['id'],
                          item.entry.path,
                          visible,
                        )
                      : null);
              if (!mounted ||
                  ticket != generation ||
                  item.parent != current ||
                  !identical(adapter, connection)) {
                return null;
              }
              return (
                path: item.entry.path,
                collection: value == null
                    ? null
                    : await widget.model.synchronizeCollectionInBackground(
                        widget.source['id'],
                        value,
                        importMissing: false,
                        cancel: token,
                      ),
              );
            } catch (_) {
              return null; // Optional previews never block manual browsing.
            }
          }),
        );
        if (!mounted) return;
        if (ticket != generation || !identical(adapter, connection)) {
          for (final item in batch) {
            inspectedFolders.remove(item.entry.path);
          }
          continue;
        }
        if (token.cancelled) {
          // These requests did not inspect their folders. Keep their place in
          // the bounded visible-folder queue so resume retries the same batch.
          folderQueue.insertAll(
            0,
            batch.where((item) => item.parent == current),
          );
          for (final item in batch) {
            if (item.parent != current) {
              inspectedFolders.remove(item.entry.path);
            }
          }
          continue;
        }
        void update() {
          for (final result in results.nonNulls) {
            folderCollections[result.path] = result.collection;
          }
        }

        if (_canRefresh) {
          setState(update);
        } else {
          update();
        }
      }
    } finally {
      inspectingFolder = false;
    }
  }

  Widget _entryArtwork(SourceEntry entry) {
    if (entry.directory) {
      final ticket = generation;
      return _posterOrFrame(
        poster: folderCollections[entry.path]?.poster ?? '',
        folder: true,
        onRequestPreview: () {
          if (mounted && ticket == generation) _queueFolder(entry);
        },
      );
    }
    if (!isVideo(entry.name) && widget.source['kind'] != 'http') {
      return _FolderIcon(fileName: entry.name);
    }
    final sourceId = widget.source['id'] as String;
    final id = widget.model.sourcePreviewId(sourceId, entry.path);
    final frame = widget.model.thumbnailPath(id);
    final ticket = generation;
    return _posterOrFrame(
      frame: frame,
      folder: false,
      onRequestPreview: () async {
        final model = widget.model;
        final revision = model.cacheRevision;
        if (!_canRefresh) return;
        final needed = await model.needsMediaPreview(id);
        if (needed &&
            _canRefresh &&
            identical(model, widget.model) &&
            revision == model.cacheRevision &&
            ticket == generation) {
          model.ensureSourceMediaPreview(sourceId, entry);
        }
      },
    );
  }

  DirectoryCollection? _folderCollection(SourceEntry entry) {
    if (!folderCollections.containsKey(entry.path)) {
      final preview = widget.model.catalog.directoryPreview(
        widget.source['id'],
        entry.path,
        modified: entry.modified,
      );
      final artwork =
          preview ??
          widget.model.catalog.directoryPreview(
            widget.source['id'],
            entry.path,
            modified: entry.modified,
            allowStale: true,
          );
      folderCollections[entry.path] = _knownCollection(
        widget.model,
        widget.source['id'],
        entry.path,
        knownFolders,
        preview: artwork?.collection,
      );
      // Preview lookup enriches existing records after layout. Only opening
      // this folder adds its unplayed episodes to the library.
    }
    return folderCollections[entry.path];
  }

  Widget _posterOrFrame({
    String poster = '',
    String? frame,
    required bool folder,
    VoidCallback? onRequestPreview,
  }) => _FolderArtwork(
    model: widget.model,
    poster: poster,
    frame: frame,
    folder: folder,
    onRequestPreview: onRequestPreview,
  );

  void _setCollection(DirectoryCollection? value) {
    collection = value;
    _prepareCollectionDetails();
  }

  // Source and library details consume the same worker-prepared library index.
  // Preparing this when a listing/snapshot arrives keeps queries and full-series
  // scans out of build, scrolling and the lazy row builder.
  void _prepareCollectionDetails() {
    final value = collection;
    final snapshot = _knownFolderIndex.snapshot;
    final sourceId = widget.source['id'] as String;
    final recordsKey = (value, snapshot, current, sourceId);
    if (_recordsKey == recordsKey) return;
    _recordsKey = recordsKey;
    _mediaByPath = snapshot?.recordsBySource[sourceId] ?? const {};
    // Locate this collection in its physical folder, then select its own
    // identity. Another imported series or old movie in that folder must not
    // hide it. Alias conflicts were already excluded by the snapshot worker.
    final firstEntry = value?.videos.firstOrNull;
    final folder = firstEntry == null
        ? null
        : snapshot?.folders[_folderKey(
            sourceId,
            p.posix.dirname(firstEntry.path.replaceAll('\\', '/')),
          )];
    final identity = value == null
        ? null
        : mediaSeriesKey(
            SyncRecord(
              kind: 'media',
              id: 'directory',
              data: {
                'series': value.title,
                'season': value.season,
                'episode': '1',
                if (value.subject case final subject?)
                  ...subjectMediaFields(subject),
              },
            ),
          );
    var seriesKey = folder?.seriesByIdentity[identity];
    if (seriesKey == null &&
        value?.subject == null &&
        value?.videos.length == 1 &&
        value?.identities[firstEntry?.path]?.episode.isEmpty == true) {
      // A recognized single-file collection can use that file's prepared
      // details without inventing episode numbers or merging unrelated files.
      final item = _mediaByPath[firstEntry?.path.replaceAll('\\', '/')];
      final key = item == null ? null : snapshot?.seriesKeyFor(item);
      if (key?.startsWith('file:') == true) seriesKey = key;
    }
    _collectionRecords = folder?.series[seriesKey] ?? const [];
    final first = _collectionRecords.firstOrNull;
    _hasCollectionHeader = value != null && first != null;
    _headerSeriesRecords = first == null ? null : snapshot?.seriesFor(first);
    _headerDetails = first == null ? null : snapshot?.detailsFor(first);
    _headerLatest = folder?.latestBySeries[seriesKey];
    _updateSearch();
  }

  Widget _collectionHeader(
    DirectoryCollection value,
    List<SyncRecord> records,
  ) {
    final latest = _headerLatest;
    final seriesRecords = _headerSeriesRecords!;
    final details = _headerDetails!;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: MediaDetailsOverview(
        model: widget.model,
        details: details,
        records: seriesRecords,
        latest: latest,
        onMatch: () async {
          await _matchSourceRecords(
            context,
            widget.model,
            records,
            automatic: false,
          );
          if (mounted) {
            final resolved = await widget.model
                .synchronizeCollectionInBackground(
                  widget.source['id'],
                  value,
                  importMissing: true,
                  cancel: cancel,
                );
            if (mounted) setState(() => _setCollection(resolved));
          }
        },
        onPlay: (item) {
          final location = _knownFolderIndex.snapshot?.locations[item.id];
          final path = location?['path'];
          if (path is! String ||
              location?['source'] != widget.source['id'] ||
              !value.identities.containsKey(path)) {
            return;
          }
          _select(
            SourceEntry(
              name: '${item.data['fileName'] ?? p.posix.basename(path)}',
              path: path,
              size: (location?['size'] as num?)?.toInt() ?? 0,
              modified: (location?['modified'] as num?)?.toInt() ?? 0,
            ),
          );
        },
        onSort: _sortMenu,
      ),
    );
  }

  void _remember({bool captureOffset = true}) {
    if (captureOffset && scroll.hasClients && !busy) {
      offsets[current] = scroll.offset;
    }
    if (captureOffset) {
      if (_search.query.isEmpty) {
        _queries.remove(current);
      } else {
        _queries[current] = _search.text.text;
      }
    }
    widget.model.store.setLocal(_stateKey, {
      'paths': [
        for (final item in paths) {'path': item.path, 'name': item.name},
      ],
      'offsets': offsets,
    });
  }

  void _restoreScroll(String directory) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current != directory || !scroll.hasClients) return;
      scroll.jumpTo(
        (offsets[directory] ?? 0).clamp(0, scroll.position.maxScrollExtent),
      );
    });
  }

  Future<void> _sortMenu() {
    _search.dismiss();
    return showDirectoryOptions(context, sorting, (value) {
      widget.model.setDirectorySorting(_sortKey, value);
    }, onApplyAll: widget.model.applyDirectorySortingToAll);
  }

  Future<void> _open() async {
    _refreshCancel?.cancel();
    _refreshPending = false;
    if (!_canRefresh) {
      _openPending = true;
      _refreshPending = true;
      busy = false;
      final previous = adapter;
      adapter = null;
      await _closeSource(previous);
      return;
    }
    _openPending = false;
    cached.clear();
    _listingFingerprints.clear();
    _completedInspections.clear();
    _catalogRevision = widget.model.catalog.directoryInspectionRevision(
      widget.source['id'],
    );
    inspectedFolders.clear();
    folderQueue.clear();
    folderCollections.clear();
    _setCollection(null);
    final ticket = ++generation;
    _directoryCancel.cancel();
    _inspectionWork = null;
    final token = _directoryCancel = CancelToken();
    _sorter.cancelPending();
    setState(() {
      busy = true;
      error = '';
      entries = [];
    });
    final previous = adapter;
    adapter = null;
    try {
      await _closeSource(previous);
      if (!mounted || ticket != generation) return;
      token.check();
      if (!_canRefresh) throw const Cancelled();
      final opening = widget.model.adapter(widget.source['id']).then((
        next,
      ) async {
        // A platform connection can complete after cancellation. Release the
        // late adapter without waiting for it before foreground navigation.
        if (token.cancelled ||
            !mounted ||
            ticket != generation ||
            !_canRefresh) {
          await _closeSource(next);
          throw const Cancelled();
        }
        return next;
      });
      final next = await Future.any([
        opening,
        token.whenCancelled.then<SourceAdapter>((_) => throw const Cancelled()),
      ]);
      if (token.cancelled || !_canRefresh || ticket != generation) {
        await _closeSource(next);
        throw const Cancelled();
      }
      adapter = next;
      await _load();
    } on Cancelled {
      if (mounted && ticket == generation) {
        _openPending = true;
        _refreshPending = true;
        setState(() => busy = false);
        if (_canRefresh) _queueRefresh();
      }
    } catch (failure) {
      if (mounted && ticket == generation) _failed(failure);
    }
  }

  void _failed(Object failure) {
    final message = safeFailure(failure, action: '读取来源失败').message;
    AppLog.instance.error('来源', message);
    setState(() {
      error = message;
      busy = false;
      entries = [];
    });
  }

  Future<void> _load() async {
    if (!_canRefresh) {
      _refreshPending = true;
      if (mounted) setState(() => busy = false);
      return;
    }
    if (adapter == null) {
      await _open();
      return;
    }
    final ticket = ++generation;
    _refreshCancel?.cancel();
    _refreshPending = false;
    _directoryCancel.cancel();
    _inspectionWork = null;
    final token = _loadCancel = _directoryCancel = CancelToken();
    _sorter.cancelPending();
    setState(() {
      busy = true;
      error = '';
      entries = [];
      _setCollection(folderCollections[current]);
    });
    try {
      final directory = current;
      final previous = cached[directory];
      if (previous != null) {
        final visible = await _visible(previous);
        if (!mounted || ticket != generation) return;
        final known = await _knownFolderIndex.load(widget.model);
        if (!mounted || ticket != generation) return;
        knownFolders = known;
        allEntries = previous;
        setState(() {
          entries = visible;
          busy = false;
          _setCollection(collection);
        });
        _restoreScroll(directory);
      }
      await _refreshWork;
      token.check();
      final found = await _readDirectory(directory, token);
      token.check();
      String? fingerprint;
      if (previous != null) {
        fingerprint = await _listingFingerprint(directory, found, token);
        if (_listingFingerprints[directory] == fingerprint &&
            _inspectionComplete(directory, fingerprint)) {
          return;
        }
      }
      if (mounted && ticket == generation) {
        if (cached.length >= 16 && !cached.containsKey(directory)) {
          _completedInspections.remove(cached.keys.first);
          _listingFingerprints.remove(cached.keys.first);
          cached.remove(cached.keys.first);
        }
        cached[directory] = found;
        allEntries = found;
        final visible = await _visible(found);
        if (!mounted || ticket != generation) return;
        final known = await _knownFolderIndex.load(widget.model);
        if (!mounted || ticket != generation) return;
        knownFolders = known;
        setState(() {
          entries = visible;
          // Folder metadata is read by the lazy row builder. Looking up every
          // child here used to issue two cache/SQLite reads per directory.
          _setCollection(collection);
        });
        _restoreScroll(directory);
        final work = _inspectCurrent(
          ticket,
          directory,
          found,
          fingerprint: fingerprint,
          reconcile:
              fingerprint == null ||
              _listingFingerprints[directory] != fingerprint,
        );
        _inspectionWork = work;
        unawaited(
          work.whenComplete(() {
            if (identical(_inspectionWork, work)) {
              _inspectionWork = null;
              _resumePendingRefresh();
            }
          }),
        );
      }
    } on Cancelled {
      // A newer directory owns the listing and its metadata work.
    } on DirectorySortCancelled {
      // Keep a newer navigation or refresh in charge of the visible listing.
    } catch (failure) {
      if (mounted && ticket == generation) {
        if (entries.isEmpty) _failed(failure);
      }
    } finally {
      if (identical(_loadCancel, token)) _loadCancel = null;
      if (mounted && ticket == generation) {
        if (busy) setState(() => busy = false);
        unawaited(_inspectNextFolder());
        _resumePendingRefresh();
      }
    }
  }

  void _back() {
    _search.dismiss();
    NavigationRevealNotification.reveal(context);
    _remember();
    if (paths.length > _rootDepth) {
      paths.removeLast();
      _restoreSearch();
      _remember(captureOffset: false);
      _load();
    } else if (widget.onExit != null) {
      widget.onExit!();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _select(SourceEntry entry) async {
    if (playing || busy) return;
    _search.dismiss();
    if (entry.directory) {
      _remember();
      NavigationRevealNotification.reveal(context);
      paths.add((path: entry.path, name: entry.name));
      _restoreSearch();
      _remember(captureOffset: false);
      await _load();
      return;
    }
    setState(() => playing = true);
    _pauseRefresh();
    try {
      final id = widget.model.addMedia(
        widget.source['id'],
        entry,
        associateId: widget.associateId,
      );
      if (widget.associateId != null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      if (collection != null) {
        widget.model.applyCollectionMetadata(id, collection!, entry);
      }
      final media = widget.model.store.get('media', id)!;
      if (widget.onPlay != null) {
        await widget.onPlay!(media);
      } else if (mounted) {
        await PlayerPage.waitForDisposals();
        if (!mounted) return;
        await Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) =>
                PlayerPage(model: widget.model, media: media),
          ),
        );
      }
    } catch (failure) {
      if (mounted) await _sourceFailure(context, failure, '打开视频失败');
    } finally {
      if (mounted) {
        setState(() => playing = false);
        _queueRefresh();
      }
    }
  }

  Future<void> _scan() async {
    await widget.model.scan(widget.source['id'], current, cancel: cancel);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.model.status)));
    }
  }

  Future<void> _recognizeDirectory([String? path]) async {
    final model = widget.model;
    if (!model.recognizingDirectory) {
      unawaited(
        model.recognizeDirectory(
          widget.source['id'],
          path ?? current,
          label: path == null
              ? paths.lastOrNull?.name ?? widget.source['label'] as String?
              : null,
        ),
      );
    }
    await showMetadataTasks(context, model);
  }

  void _toggleFavorite(String path, String name) {
    final added = favorites.toggle(
      SourceFavorite(
        sourceId: widget.source['id'] as String,
        path: path,
        name: name,
      ),
    );
    setState(() {});
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已添加到我的收藏' : '已取消收藏'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _entryOptions(SourceEntry entry) async {
    _search.dismiss();
    final action = await showGlassBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!entry.directory)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('查看文件详情'),
                onTap: () => Navigator.pop(context, 'file-details'),
              ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('重新识别影视资料'),
              onTap: () => Navigator.pop(context, 'auto'),
            ),
            ListTile(
              leading: const Icon(Icons.manage_search_rounded),
              title: const Text('手动搜索影视资料'),
              onTap: () => Navigator.pop(context, 'search'),
            ),
            if (entry.directory)
              ListTile(
                leading: Icon(
                  favorites.contains(widget.source['id'], entry.path)
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
                title: Text(
                  favorites.contains(widget.source['id'], entry.path)
                      ? '取消收藏'
                      : '收藏文件夹',
                ),
                onTap: () => Navigator.pop(context, 'favorite'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'file-details') {
      await showMediaFileDetails(
        context,
        model: widget.model,
        sourceId: widget.source['id'] as String,
        sourceName: '${widget.source['label'] ?? ''}',
        entry: entry,
      );
      return;
    }
    if (action == 'favorite') {
      _toggleFavorite(
        entry.path,
        folderCollections[entry.path]?.displayName ?? entry.name,
      );
      return;
    }
    if (action == 'auto' && entry.directory) {
      await _recognizeDirectory(entry.path);
      return;
    }
    try {
      final found = entry.directory
          ? (cached[entry.path] ?? await adapter!.list(entry.path))
                .where(
                  (item) =>
                      !item.directory &&
                      isVideo(item.name) &&
                      (!hideHidden || !isHiddenEntry(item)),
                )
                .toList()
          : [entry];
      if (found.isEmpty) throw const AppFailure('此文件夹没有可识别的视频，请进入包含视频的文件夹重试。');
      final records = [
        for (final video in found)
          widget.model.store.get(
            'media',
            widget.model.addMedia(widget.source['id'], video),
          )!,
      ];
      if (!mounted) return;
      await _matchSourceRecords(
        context,
        widget.model,
        records,
        automatic: action == 'auto',
      );
      if (!mounted) return;
      if (entry.directory) {
        final value = widget.model.collectionFromEntries(
          widget.source['id'],
          entry.path,
          found,
        );
        if (value != null) {
          final resolved = await widget.model.synchronizeCollectionInBackground(
            widget.source['id'],
            value,
            cancel: _directoryCancel,
          );
          if (mounted) setState(() => folderCollections[entry.path] = resolved);
        }
      } else if (collection != null) {
        final resolved = await widget.model.synchronizeCollectionInBackground(
          widget.source['id'],
          collection!,
          cancel: _directoryCancel,
        );
        if (mounted) setState(() => _setCollection(resolved));
      } else {
        final resolved = await widget.model
            .synchronizeDirectoryEntriesInBackground(
              widget.source['id'],
              current,
              entries,
              cancel: _directoryCancel,
            );
        if (mounted) setState(() => _setCollection(resolved));
      }
    } catch (failure) {
      if (mounted) await _sourceFailure(context, failure, '匹配影视资料失败');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshCancel?.cancel();
    _remember();
    widget.model.removeListener(_modelChanged);
    _search.dispose();
    _sorter.close();
    scroll.dispose();
    generation++;
    cancel.cancel();
    _directoryCancel.cancel();
    unawaited(_closeSource(adapter));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayed = displayedEntries;
    final value = collection;
    final records = value == null ? const <SyncRecord>[] : _collectionRecords;
    final hasCollectionHeader = value != null && _hasCollectionHeader;
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1000;
    final inset = desktop
        ? GlassMetrics.desktopPageInset
        : (width < 600 ? 12.0 : 24.0);
    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        inset,
        GlassMetrics.pageTopPadding(context),
        inset,
        0,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: desktop ? double.infinity : 960,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FolderHeader(
                showTitle: !hasCollectionHeader,
                title:
                    paths.lastOrNull?.name ??
                    widget.source['label'] as String? ??
                    '来源',
                onBack: _back,
                actions: [
                  IconButton(
                    tooltip: '搜索',
                    onPressed: _search.toggle,
                    icon: const Icon(Icons.search_rounded, size: 21),
                  ),
                  if (!hasCollectionHeader)
                    IconButton(
                      tooltip: '排序与显示',
                      onPressed: _sortMenu,
                      icon: const Icon(Icons.sort_rounded, size: 21),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '文件夹选项',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (action) {
                      if (action == 'refresh') unawaited(_refreshManually());
                      if (action == 'scan') _scan();
                      if (action == 'recognize') _recognizeDirectory();
                      if (action == 'cancelRecognition') {
                        widget.model.cancelDirectoryRecognition();
                      }
                      if (action == 'edit') widget.onEdit?.call();
                      if (action == 'remove') widget.onRemove?.call();
                      if (action == 'favorite') {
                        _toggleFavorite(
                          current,
                          paths.lastOrNull?.name ??
                              widget.source['label'] ??
                              '来源',
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      if (hasCollectionHeader) ...[
                        PopupMenuItem<String>(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          enabled: false,
                          child: Text(
                            '当前目录：${current.isEmpty ? widget.source['label'] ?? '来源' : current}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const PopupMenuDivider(
                          height: GlassMetrics.menuDividerHeight,
                        ),
                      ],
                      PopupMenuItem(
                        height: GlassMetrics.menuItemHeight,
                        padding: GlassMetrics.menuItemPadding,
                        value: 'refresh',
                        enabled: !busy,
                        child: const Text('刷新目录'),
                      ),
                      if (widget.associateId == null &&
                          widget.source['kind'] != 'http')
                        PopupMenuItem(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          value: 'favorite',
                          child: Text(
                            favorites.contains(widget.source['id'], current)
                                ? '取消收藏'
                                : '收藏文件夹',
                          ),
                        ),
                      if (widget.associateId == null &&
                          widget.source['kind'] != 'http')
                        PopupMenuItem(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          value: widget.model.recognizingDirectory
                              ? 'cancelRecognition'
                              : 'recognize',
                          enabled:
                              widget.model.recognizingDirectory ||
                              (!busy &&
                                  error.isEmpty &&
                                  !widget.model.scanning),
                          child: Text(
                            widget.model.recognizingDirectory
                                ? '取消文件夹识别'
                                : hasCollectionHeader
                                ? '重新识别信息'
                                : '识别信息',
                          ),
                        ),
                      if (widget.associateId == null &&
                          widget.source['kind'] != 'http')
                        PopupMenuItem(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          value: 'scan',
                          enabled:
                              !busy && error.isEmpty && !widget.model.scanning,
                          child: const Text('添加到影视库'),
                        ),
                      if (widget.onEdit != null)
                        const PopupMenuItem(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          value: 'edit',
                          child: Text('编辑来源'),
                        ),
                      if (widget.onRemove != null) ...[
                        const PopupMenuDivider(
                          height: GlassMetrics.menuDividerHeight,
                        ),
                        const PopupMenuItem(
                          height: GlassMetrics.menuItemHeight,
                          padding: GlassMetrics.menuItemPadding,
                          value: 'remove',
                          child: Text('移除来源…'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              if (_search.shown) _FolderSearchField(_search),
              if (widget.associateId != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '选择此设备上的视频',
                    style: AppStyles.of(context).bodySmall,
                  ),
                ),
              const SizedBox(height: 2),
              if (busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refreshManually,
                  child: error.isNotEmpty
                      ? SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 44,
                              horizontal: 16,
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.wifi_off_rounded,
                                  color: GlassPalette.of(context).muted,
                                  size: 32,
                                ),
                                const SizedBox(height: 14),
                                SelectableText(
                                  error,
                                  textAlign: TextAlign.center,
                                  style: SettingsStyles.of(
                                    context,
                                  ).sourceErrorMessage,
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 12,
                                  children: [
                                    TextButton(
                                      onPressed: _open,
                                      child: const Text('重试'),
                                    ),
                                    if (widget.onEdit != null)
                                      TextButton(
                                        onPressed: widget.onEdit,
                                        child: const Text('编辑来源'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        )
                      : displayed.isEmpty && !busy
                      ? SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: _EmptyFolder(
                            text: _search.query.isEmpty ? '这里还没有文件' : '没有匹配的文件',
                          ),
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          controller: scroll,
                          scrollCacheExtent: const ScrollCacheExtent.viewport(
                            .75,
                          ),
                          padding: EdgeInsets.only(
                            bottom: 20 + MediaQuery.paddingOf(context).bottom,
                          ),
                          itemCount:
                              displayed.length + (hasCollectionHeader ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (hasCollectionHeader && index == 0) {
                              return _collectionHeader(collection!, records);
                            }
                            final entry =
                                displayed[index -
                                    (hasCollectionHeader ? 1 : 0)];
                            final group = entry.directory
                                ? _folderCollection(entry)
                                : null;
                            final playable =
                                entry.directory ||
                                isVideo(entry.name) ||
                                widget.source['kind'] == 'http';
                            final media = entry.directory
                                ? null
                                : _mediaByPath[entry.path.replaceAll(
                                    '\\',
                                    '/',
                                  )];
                            if (hasCollectionHeader && isVideo(entry.name)) {
                              final savedEpisode = media == null
                                  ? ''
                                  : widget.model.episodeLabel(media);
                              final episode = savedEpisode.isNotEmpty
                                  ? savedEpisode
                                  : collection?.episodeLabel(entry.path) ?? '';
                              final sourceId = widget.source['id'] as String;
                              return MediaDetailsEpisodeTile(
                                key: ValueKey(entry.path),
                                model: widget.model,
                                item:
                                    media ??
                                    SyncRecord(
                                      kind: 'media',
                                      id: widget.model.sourcePreviewId(
                                        sourceId,
                                        entry.path,
                                      ),
                                      data: {
                                        'title': entry.name,
                                        'fileName': entry.name,
                                        'size': entry.size,
                                      },
                                    ),
                                title: episode.isEmpty ? null : episode,
                                sourceId: sourceId,
                                sourceEntry: entry,
                                showTechnical:
                                    _headerSeriesRecords?.length != 1,
                                onPlay: () => _select(entry),
                                onLongPress: widget.associateId == null
                                    ? () => _entryOptions(entry)
                                    : null,
                                trailing: widget.associateId == null
                                    ? IconButton(
                                        tooltip: '视频选项',
                                        icon: const Icon(Icons.more_vert),
                                        onPressed: () => _entryOptions(entry),
                                      )
                                    : null,
                              );
                            }
                            final savedEpisode = media == null
                                ? ''
                                : widget.model.episodeLabel(media);
                            final episode = savedEpisode.isNotEmpty
                                ? savedEpisode
                                : collection?.episodeLabel(entry.path) ?? '';
                            final progress = media == null
                                ? ''
                                : playbackProgressLabel(
                                    widget.model.progressFor(media),
                                  );
                            final specRecord =
                                media ??
                                SyncRecord(
                                  kind: 'media',
                                  id: widget.model.sourcePreviewId(
                                    widget.source['id'],
                                    entry.path,
                                  ),
                                  data: {
                                    'title': entry.name,
                                    'fileName': entry.name,
                                    'size': entry.size,
                                  },
                                );
                            final technical =
                                !entry.directory && isVideo(entry.name)
                                ? MediaTechnicalInfo.forRecord(
                                    widget.model.store,
                                    specRecord,
                                    dimensions: widget.model.mediaDimensions(
                                      specRecord,
                                    ),
                                    fileName: entry.name,
                                    fileSize: entry.size,
                                  ).label
                                : _fileSize(entry.size);
                            return Opacity(
                              key: ValueKey(entry.path),
                              opacity: playable ? 1 : .45,
                              child: _FolderRow(
                                title:
                                    group?.displayName ??
                                    (hasCollectionHeader && episode.isNotEmpty
                                        ? episode
                                        : media != null
                                        ? widget.model.displayTitle(media)
                                        : entry.name),
                                subtitle: group != null
                                    ? [
                                        if (group.seasonLabel.isNotEmpty)
                                          group.seasonLabel,
                                        group.episodeCount > 0
                                            ? '${group.episodeCount} 集'
                                            : '${group.videos.length} 个视频',
                                      ].join(' · ')
                                    : entry.directory
                                    ? ''
                                    : [technical, progress]
                                          .where((line) => line.isNotEmpty)
                                          .join('\n'),
                                leading: _entryArtwork(entry),
                                video: !entry.directory,
                                onTap: () {
                                  if (playable) _select(entry);
                                },
                                onLongPress:
                                    playable && widget.associateId == null
                                    ? () => _entryOptions(entry)
                                    : null,
                                trailing: !playable
                                    ? const SizedBox(width: 20)
                                    : entry.directory &&
                                          favorites.contains(
                                            widget.source['id'],
                                            entry.path,
                                          )
                                    ? Icon(
                                        Icons.star_rounded,
                                        size: 18,
                                        color: GlassPalette.of(context).accent,
                                      )
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final contents = PopScope(
      canPop: !widget.embedded && paths.length <= _rootDepth,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: body,
    );
    // The browser keeps its toolbar fixed; only scrolling page headers consume
    // their top inset inside the list. Keep these controls below the status bar.
    if (widget.embedded) {
      return SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: contents,
      );
    }
    return Scaffold(
      backgroundColor: GlassPalette.of(context).canvas,
      body: GlassBackground(child: SafeArea(child: contents)),
    );
  }
}
