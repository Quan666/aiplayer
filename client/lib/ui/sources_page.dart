import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../data/library_catalog.dart';
import '../data/media_presentation.dart';
import '../data/media_technical_info.dart';
import '../sources/configuration.dart';
import '../sources/discovery.dart';
import '../sources/directory_sort.dart';
import '../sources/favorites.dart';
import '../sources/source.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';
import 'player_page.dart';
import 'navigation_reveal.dart';
import 'media_details_header.dart';
import 'media_artwork.dart';
import 'metadata_match_dialog.dart';

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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('降序'),
                  value: value.descending,
                  onChanged: (descending) =>
                      change(value.copyWith(descending: descending)),
                ),
                if (showSubtitleOption)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示字幕文件'),
                    value: value.showSubtitles,
                    onChanged: (show) =>
                        change(value.copyWith(showSubtitles: show)),
                  ),
                if (onApplyAll != null) ...[
                  const Divider(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
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

class _KnownFolder {
  final entries = <SourceEntry>[];
  final records = <SyncRecord>[];
}

class _KnownFolderIndex {
  Object? _key;
  Map<String, _KnownFolder> _folders = {};

  Map<String, _KnownFolder> read(AppModel model) {
    final key = (
      model.store,
      model.store.recordsRevision('media'),
      model.store.locationRevision,
    );
    if (_key != key) {
      _folders = _knownFolders(model);
      _key = key;
    }
    return _folders;
  }
}

Map<String, _KnownFolder> _knownFolders(AppModel model) {
  final records = {for (final media in model.media) media.id: media};
  final folders = <String, _KnownFolder>{};
  for (final location in model.store.locations) {
    final record = records[location['id']];
    if (record == null ||
        location['source'] is! String ||
        location['path'] is! String) {
      continue;
    }
    final path = '${location['path']}'.replaceAll('\\', '/');
    final folder = folders.putIfAbsent(
      _folderKey(location['source'], p.posix.dirname(path)),
      _KnownFolder.new,
    );
    folder.records.add(record);
    folder.entries.add(
      SourceEntry(
        name: '${record.data['fileName'] ?? p.posix.basename(path)}',
        path: path,
        size: (location['size'] as num?)?.toInt() ?? 0,
        modified: (location['modified'] as num?)?.toInt() ?? 0,
      ),
    );
  }
  return folders;
}

DirectoryCollection? _knownCollection(
  AppModel model,
  String sourceId,
  String path,
  Map<String, _KnownFolder> folders, {
  DirectoryCollection? preview,
}) {
  final folder = folders[_folderKey(sourceId, path)];
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
          placeholder: fallback(),
          onRequestPreview: onRequestPreview,
        ),
      ),
    );
  }
}

class SourcesPage extends StatefulWidget {
  final AppModel model;
  final Future<void> Function() onImport;
  final Future<void> Function(SyncRecord) onPlay;
  final LanDiscovery? discovery;
  final SourcesController? controller;
  const SourcesPage({
    super.key,
    required this.model,
    required this.onImport,
    required this.onPlay,
    this.discovery,
    this.controller,
  });
  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  AppModel get model => widget.model;
  CancelToken? scan;
  bool localOpen = false;
  Map<String, dynamic>? opened;
  String? initialPath, initialName;
  SourceFavorites get favorites => SourceFavorites(model.store);
  final _rootScroll = ScrollController();
  final _knownFolderIndex = _KnownFolderIndex();
  Object? _localMediaKey;
  List<SyncRecord> _localMediaSnapshot = const [];

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_showRoot);
    widget.model.addListener(_refreshRoot);
  }

  @override
  void didUpdateWidget(SourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_showRoot);
      widget.controller?.addListener(_showRoot);
    }
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_refreshRoot);
      widget.model.addListener(_refreshRoot);
    }
  }

  void _refreshRoot() {
    if (mounted && opened == null) setState(() {});
  }

  void _showRoot() {
    NavigationRevealNotification.reveal(context);
    setState(() {
      opened = null;
      localOpen = false;
      initialPath = initialName = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rootScroll.hasClients) _rootScroll.jumpTo(0);
    });
  }

  void _openSource(Map<String, dynamic> source, {SourceFavorite? favorite}) {
    NavigationRevealNotification.reveal(context);
    setState(() {
      opened = source;
      initialPath = favorite?.path;
      initialName = favorite?.name;
    });
  }

  void _showLocal(bool value) {
    NavigationRevealNotification.reveal(context);
    setState(() => localOpen = value);
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
    widget.controller?.removeListener(_showRoot);
    widget.model.removeListener(_refreshRoot);
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
      const PopupMenuItem(value: 'edit', child: Text('编辑来源')),
      if (source['kind'] != 'http')
        PopupMenuItem(
          value: 'favorite',
          child: Text(
            favorites.contains(source['id'] as String, '') ? '取消收藏' : '收藏文件夹',
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'remove', child: Text('移除来源…')),
    ],
  );

  Widget _root() {
    final sources = model.sources;
    final sourcesById = {for (final source in sources) source['id']: source};
    final known = _knownFolderIndex.read(model);
    final saved = favorites.available(
      sources.map((source) => source['id'] as String),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            key: const PageStorageKey('sources-scroll'),
            controller: _rootScroll,
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
                        subtitle: '${_localMedia.length} 个视频',
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
                    elevation: 6 * Curves.easeInOut.transform(animation.value),
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
                      known,
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
                          PopupMenuItem(value: 'remove', child: Text('取消收藏')),
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

  List<SyncRecord> get _localMedia {
    final sorting = model.directorySorting('directorySort:local:imports');
    final hideHidden = model.preferences.hideHiddenFiles;
    final key = (
      model.store,
      model.store.recordsRevision('media'),
      model.store.locationRevision,
      sorting.field,
      sorting.descending,
      sorting.showSubtitles,
      hideHidden,
    );
    if (_localMediaKey == key) return _localMediaSnapshot;
    final locations = {
      for (final value in model.store.locations.where(
        (v) => v['source'] == 'local',
      ))
        value['id'] as String: value,
    };
    final media = {
      for (final value in model.media.where((v) => locations.containsKey(v.id)))
        value.id: value,
    };
    final sorted = sorting.apply([
      for (final value in media.values)
        SourceEntry(
          name:
              value.data['fileName'] as String? ??
              value.data['title'] as String? ??
              '',
          path: value.id,
          size: (locations[value.id]?['size'] as num?)?.toInt() ?? 0,
          modified: (locations[value.id]?['modified'] as num?)?.toInt() ?? 0,
        ),
    ], hideHiddenFiles: hideHidden);
    _localMediaKey = key;
    return _localMediaSnapshot = sorted
        .map((entry) => media[entry.path]!)
        .toList();
  }

  Future<void> _sortLocal() => showDirectoryOptions(
    context,
    model.directorySorting('directorySort:local:imports'),
    (value) {
      model.setDirectorySorting('directorySort:local:imports', value);
      setState(() {});
    },
    onApplyAll: model.applyDirectorySortingToAll,
  );

  Future<void> _localMetadataOptions(SyncRecord item) async {
    final action = await showGlassBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    await _matchSourceRecords(context, model, [
      item,
    ], automatic: action == 'auto');
    if (mounted) setState(() {});
  }

  Widget _local() {
    final media = _localMedia;
    return _ContentList(
      itemCount: media.length,
      itemBuilder: (context, index) {
        final item = media[index];
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
          onTap: () => widget.onPlay(item),
          onLongPress: () => _localMetadataOptions(item),
        );
      },
      children: [
        _FolderHeader(
          title: '本地视频',
          onBack: () => _showLocal(false),
          actions: [
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
                    enabled: !model.scanning,
                    value: 'scan',
                    child: const Text('扫描文件夹'),
                  ),
                ],
              ),
          ],
        ),
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
            text: '还没有本地视频',
            action: TextButton.icon(
              onPressed: widget.onImport,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('导入视频'),
            ),
          ),
      ],
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
    if (opened case final source?) {
      return SourceBrowser(
        key: ValueKey('${source['id']}:${source.hashCode}:$initialPath'),
        model: model,
        source: source,
        embedded: true,
        initialPath: initialPath,
        initialName: initialName,
        onExit: () {
          NavigationRevealNotification.reveal(context);
          setState(() => opened = null);
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
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  const _ContentList({
    required this.children,
    this.itemCount = 0,
    this.itemBuilder,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView.builder(
      padding: EdgeInsets.fromLTRB(
        constraints.maxWidth < 600 ? 12 : 24,
        GlassMetrics.pageTopPadding(context) +
            MediaQuery.paddingOf(context).top,
        constraints.maxWidth < 600 ? 12 : 24,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: children.length + itemCount,
      itemBuilder: (context, index) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: SizedBox(
            width: double.infinity,
            child: index < children.length
                ? children[index]
                : itemBuilder!(context, index - children.length),
          ),
        ),
      ),
    ),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
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
                      contentPadding: EdgeInsets.zero,
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
                      contentPadding: EdgeInsets.zero,
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
                      tilePadding: EdgeInsets.zero,
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
                        contentPadding: EdgeInsets.zero,
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
  final bool embedded;
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
    this.onExit,
    this.onEdit,
    this.onRemove,
    this.onPlay,
  });
  @override
  State<SourceBrowser> createState() => _SourceBrowserState();
}

class _SourceBrowserState extends State<SourceBrowser> {
  SourceAdapter? adapter;
  List<SourceEntry> entries = [];
  final paths = <({String path, String name})>[];
  bool busy = true;
  bool playing = false;
  String error = '';
  int generation = 0;
  final cancel = CancelToken();
  final scroll = ScrollController();
  final offsets = <String, double>{};
  final cached = <String, List<SourceEntry>>{};
  List<SourceEntry> allEntries = [];
  DirectoryCollection? collection;
  Object? _recordsKey;
  List<SyncRecord> _collectionRecords = const [];
  bool _hasCollectionHeader = false;
  List<SyncRecord>? _headerSeriesRecords;
  MediaCollectionDetails? _headerDetails;
  Object? _headerProgressKey;
  SyncRecord? _headerLatest;
  final folderCollections = <String, DirectoryCollection?>{};
  final folderQueue = <({SourceEntry entry, String parent})>[];
  final inspectedFolders = <String>{};
  bool inspectingFolder = false;
  bool _modelRefreshScheduled = false;
  Map<String, _KnownFolder> knownFolders = {};
  final _knownFolderIndex = _KnownFolderIndex();

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
  final _sortedListings = Expando<(Object, List<SourceEntry>)>();
  List<SourceEntry> _visible(List<SourceEntry> values) {
    final order = sorting;
    final hidden = hideHidden;
    final key = (order.field, order.descending, order.showSubtitles, hidden);
    final cached = _sortedListings[values];
    if (cached != null && cached.$1 == key) return cached.$2;
    final result = order.apply(values, hideHiddenFiles: hidden);
    // Directory snapshots are replaced on refresh. Weak keys release sorted
    // copies when the bounded folder cache drops their source listing.
    _sortedListings[values] = (key, result);
    return result;
  }

  String get current => paths.lastOrNull?.path ?? '';

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
    knownFolders = _knownFolderIndex.read(widget.model);
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
    _open();
  }

  void _modelChanged() {
    if (!mounted || _modelRefreshScheduled) return;
    _modelRefreshScheduled = true;
    scheduleMicrotask(() {
      _modelRefreshScheduled = false;
      if (!mounted) return;
      final known = _knownFolderIndex.read(widget.model);
      final metadataChanged = !identical(knownFolders, known);
      knownFolders = known;
      setState(() {
        if (!busy) entries = _visible(allEntries);
        // Preview completions and playback updates still refresh visible rows,
        // but must not rescan every episode and visited folder. Episode names
        // and progress are read directly from the model by each visible row.
        if (!metadataChanged) return;
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
      });
    });
  }

  Future<void> _inspectCurrent(
    int ticket,
    String directory,
    List<SourceEntry> found,
  ) async {
    if (widget.associateId != null) return;
    try {
      final value = await widget.model.catalog.inspect(
        widget.source['id'],
        directory,
        _visible(found),
      );
      if (mounted && ticket == generation && current == directory) {
        setState(() {
          collection = value == null
              ? collection
              : widget.model.synchronizeCollection(
                  widget.source['id'],
                  value,
                  importMissing: true,
                );
          folderCollections[directory] = collection;
        });
      }
    } catch (failure) {
      // Optional catalog work must never surface as an unhandled future or
      // replace a usable file listing with a metadata error.
      if (mounted && ticket == generation) {
        AppLog.instance.warning('来源资料', safeFailure(failure).message);
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
    if (inspectingFolder || busy || adapter == null || !mounted) return;
    inspectingFolder = true;
    try {
      while (folderQueue.isNotEmpty && mounted && !busy) {
        final ticket = generation;
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
              final found =
                  cached[item.entry.path] ??
                  await connection.list(item.entry.path);
              if (!mounted ||
                  ticket != generation ||
                  !identical(adapter, connection)) {
                return null;
              }
              if (cached.length >= 16) cached.remove(cached.keys.first);
              cached[item.entry.path] = found;
              final value =
                  await widget.model.catalog.inspect(
                    widget.source['id'],
                    item.entry.path,
                    _visible(found),
                    directoryModified: item.entry.modified,
                  ) ??
                  widget.model.collectionFromEntries(
                    widget.source['id'],
                    item.entry.path,
                    _visible(found),
                  );
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
                    : widget.model.synchronizeCollection(
                        widget.source['id'],
                        value,
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
        setState(() {
          for (final result in results.nonNulls) {
            folderCollections[result.path] = result.collection;
          }
        });
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
    final media = widget.model.sourceMedia(sourceId, entry.path);
    final id = widget.model.sourcePreviewId(sourceId, entry.path);
    final storedPoster = media?.data['poster'] as String? ?? '';
    final poster = storedPoster.isNotEmpty
        ? storedPoster
        : collection?.poster ?? '';
    final frame = widget.model.thumbnailPath(id);
    final ticket = generation;
    return _posterOrFrame(
      poster: poster,
      frame: frame,
      folder: false,
      onRequestPreview: widget.model.needsMediaPreview(id)
          ? () {
              if (mounted && ticket == generation) {
                widget.model.ensureSourceMediaPreview(sourceId, entry);
              }
            }
          : null,
    );
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

  Widget _collectionHeader(
    DirectoryCollection value,
    List<SyncRecord> records,
  ) {
    final progressKey = (
      records,
      widget.model.store.recordsRevision('progress'),
    );
    if (progressKey != _headerProgressKey) {
      _headerLatest = widget.model.recentMedia(items: records).firstOrNull;
      _headerProgressKey = progressKey;
    }
    final latest = _headerLatest;
    final seriesRecords = _headerSeriesRecords ??= widget.model.seriesRecords(
      records.first,
    );
    final details = _headerDetails ??= MediaCollectionDetails.fromRecords(
      seriesRecords,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaDetailsHeader(
            model: widget.model,
            details: details,
            records: seriesRecords,
            onMatch: () async {
              await _matchSourceRecords(
                context,
                widget.model,
                records,
                automatic: false,
              );
              if (mounted) {
                setState(
                  () => collection = widget.model.synchronizeCollection(
                    widget.source['id'],
                    value,
                  ),
                );
              }
            },
          ),
          if (latest != null) ...[
            const SizedBox(height: 8),
            Text(
              [
                widget.model.episodeLabel(latest),
                playbackProgressLabel(widget.model.progressFor(latest)),
              ].where((text) => text.isNotEmpty).join(' · '),
              style: AppStyles.of(context).micro,
            ),
            TextButton.icon(
              onPressed: () => _select(
                value.videos.firstWhere(
                  (entry) =>
                      widget.model
                          .sourceMedia(widget.source['id'], entry.path)
                          ?.id ==
                      latest.id,
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('继续观看'),
            ),
          ],
        ],
      ),
    );
  }

  void _remember({bool captureOffset = true}) {
    if (captureOffset && scroll.hasClients && !busy) {
      offsets[current] = scroll.offset;
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

  Future<void> _sortMenu() => showDirectoryOptions(context, sorting, (value) {
    widget.model.setDirectorySorting(_sortKey, value);
    setState(
      () => entries = value.apply(allEntries, hideHiddenFiles: hideHidden),
    );
  }, onApplyAll: widget.model.applyDirectorySortingToAll);

  Future<void> _open({bool refresh = false}) async {
    if (refresh) {
      widget.model.catalog.invalidateDirectoryPreviews(widget.source['id']);
    }
    cached.clear();
    inspectedFolders.clear();
    folderQueue.clear();
    folderCollections.clear();
    collection = null;
    final ticket = ++generation;
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
      final next = await widget.model.adapter(widget.source['id']);
      if (!mounted || ticket != generation) {
        await next.close();
        return;
      }
      adapter = next;
      await _load();
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
    if (adapter == null) {
      await _open();
      return;
    }
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      entries = [];
      collection = folderCollections[current];
    });
    try {
      final directory = current;
      final found =
          cached[directory] ??
          (widget.source['kind'] == 'http'
              ? [await adapter!.stat('')]
              : await adapter!.list(directory));
      if (mounted && ticket == generation) {
        if (cached.length >= 16) cached.remove(cached.keys.first);
        cached[directory] = found;
        allEntries = found;
        knownFolders = _knownFolderIndex.read(widget.model);
        setState(() {
          entries = _visible(found);
          for (final entry in entries.where((entry) => entry.directory)) {
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
            if (preview != null) inspectedFolders.add(entry.path);
          }
          collection ??= widget.model.collectionFromEntries(
            widget.source['id'],
            directory,
            entries,
          );
        });
        if (collection != null && widget.associateId == null) {
          collection = widget.model.synchronizeCollection(
            widget.source['id'],
            collection!,
            importMissing: true,
          );
        }
        _restoreScroll(directory);
        unawaited(_inspectCurrent(ticket, directory, found));
      }
    } catch (failure) {
      if (mounted && ticket == generation) _failed(failure);
    } finally {
      if (mounted && ticket == generation) {
        setState(() => busy = false);
        unawaited(_inspectNextFolder());
      }
    }
  }

  void _back() {
    NavigationRevealNotification.reveal(context);
    _remember();
    if (paths.length > _rootDepth) {
      paths.removeLast();
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
    if (entry.directory) {
      _remember();
      NavigationRevealNotification.reveal(context);
      paths.add((path: entry.path, name: entry.name));
      _remember(captureOffset: false);
      await _load();
      return;
    }
    setState(() => playing = true);
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
      if (mounted) setState(() => playing = false);
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
    final action = await showGlassBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    if (action == 'favorite') {
      _toggleFavorite(
        entry.path,
        folderCollections[entry.path]?.displayName ?? entry.name,
      );
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
          setState(
            () => folderCollections[entry.path] = widget.model
                .synchronizeCollection(widget.source['id'], value),
          );
        }
      } else if (collection != null) {
        setState(
          () => collection = widget.model.synchronizeCollection(
            widget.source['id'],
            collection!,
          ),
        );
      } else {
        setState(
          () => collection = widget.model.collectionFromEntries(
            widget.source['id'],
            current,
            entries,
          ),
        );
      }
    } catch (failure) {
      if (mounted) await _sourceFailure(context, failure, '匹配影视资料失败');
    }
  }

  @override
  void dispose() {
    _remember();
    widget.model.removeListener(_modelChanged);
    scroll.dispose();
    generation++;
    cancel.cancel();
    unawaited(_closeSource(adapter));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = collection;
    final recordsKey = (
      value,
      widget.model.store.recordsRevision('media'),
      widget.model.store.locationRevision,
    );
    if (value != null && recordsKey != _recordsKey) {
      _collectionRecords = widget.model.collectionRecords(
        widget.source['id'],
        value,
      );
      final first = _collectionRecords.firstOrNull;
      final seriesKey = first == null ? null : mediaSeriesKey(first);
      _hasCollectionHeader =
          first != null &&
          _collectionRecords.every(
            (record) => mediaSeriesKey(record) == seriesKey,
          );
      _headerSeriesRecords = null;
      _headerDetails = null;
      _recordsKey = recordsKey;
    }
    final records = value == null ? const <SyncRecord>[] : _collectionRecords;
    final hasCollectionHeader = value != null && _hasCollectionHeader;
    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
        GlassMetrics.pageTopPadding(context),
        MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
        0,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
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
                    tooltip: '排序与显示',
                    onPressed: _sortMenu,
                    icon: const Icon(Icons.sort_rounded, size: 21),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '文件夹选项',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (action) {
                      if (action == 'refresh') _open(refresh: true);
                      if (action == 'scan') _scan();
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
                          enabled: false,
                          child: Text(
                            '当前目录：${current.isEmpty ? widget.source['label'] ?? '来源' : current}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const PopupMenuDivider(),
                      ],
                      PopupMenuItem(
                        value: 'refresh',
                        enabled: !busy,
                        child: const Text('刷新目录'),
                      ),
                      if (widget.associateId == null &&
                          widget.source['kind'] != 'http')
                        PopupMenuItem(
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
                          value: 'scan',
                          enabled:
                              !busy && error.isEmpty && !widget.model.scanning,
                          child: const Text('添加到影视库'),
                        ),
                      if (widget.onEdit != null)
                        const PopupMenuItem(value: 'edit', child: Text('编辑来源')),
                      if (widget.onRemove != null) ...[
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('移除来源…'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
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
                child: error.isNotEmpty
                    ? SingleChildScrollView(
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
                    : entries.isEmpty && !busy
                    ? const SingleChildScrollView(
                        child: _EmptyFolder(text: '这里还没有文件'),
                      )
                    : ListView.builder(
                        controller: scroll,
                        padding: EdgeInsets.only(
                          bottom: 20 + MediaQuery.paddingOf(context).bottom,
                        ),
                        itemCount:
                            entries.length + (hasCollectionHeader ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (hasCollectionHeader && index == 0) {
                            return _collectionHeader(collection!, records);
                          }
                          final entry =
                              entries[index - (hasCollectionHeader ? 1 : 0)];
                          final group = entry.directory
                              ? folderCollections[entry.path]
                              : null;
                          final playable =
                              entry.directory ||
                              isVideo(entry.name) ||
                              widget.source['kind'] == 'http';
                          final media = entry.directory
                              ? null
                              : widget.model.sourceMedia(
                                  widget.source['id'],
                                  entry.path,
                                );
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
