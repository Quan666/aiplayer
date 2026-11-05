import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../core/logger.dart';
import '../data/album_catalog.dart';
import '../data/album_catalog_worker.dart';
import '../data/album_images.dart';
import '../data/album_view_settings.dart';
import '../data/app_model.dart';
import '../data/text_document.dart';
import '../sources/apple_access.dart';
import '../sources/source.dart';
import 'album_playback.dart';
import 'album_filter_sheet.dart';
import 'album_folder_thumbnail.dart';
import 'album_thumbnail.dart';
import 'album_video_thumbnail.dart';
import 'album_viewer.dart';
import 'album_viewer_route.dart';
import 'album_wall.dart';
import 'artwork_lifecycle.dart';
import 'artwork_scroll_scope.dart';
import 'player_page.dart';
import 'music_page.dart';
import 'navigation_reveal.dart';
import 'remote_control.dart';
import 'glass.dart';
import 'television_input.dart';
import 'offline_download_controls.dart';
import 'text_file_page.dart';

export 'album_viewer.dart' show AlbumViewer;

class AlbumPage extends StatefulWidget {
  static final _disposals = <Future<void>>{};

  @visibleForTesting
  static int get pendingDisposals => _disposals.length;

  static void _finishWrites(AlbumCatalogWorker worker) {
    final work = worker.flushPreferencesAndClose().catchError((Object error) {
      AppLog.instance.error(
        '相册',
        safeFailure(error, action: '保存浏览位置失败').message,
      );
    });
    _disposals.add(work);
    unawaited(work.whenComplete(() => _disposals.remove(work)));
  }

  final AppModel model;
  final Map<String, dynamic> source;
  final String initialPath;
  final String? initialName;
  final String? initialEntryPath;
  final bool active;
  final int initialAnchor;
  final double? initialOffset;
  final List<SourceEntry>? initialEntries;
  final Map<String, dynamic>? initialSettings;
  final VoidCallback? onExit;
  final void Function(String path, String name)? onFileView;

  const AlbumPage({
    super.key,
    required this.model,
    required this.source,
    required this.initialPath,
    this.initialName,
    this.initialEntryPath,
    this.active = true,
    this.initialAnchor = 0,
    this.initialOffset,
    this.initialEntries,
    this.initialSettings,
    this.onExit,
    this.onFileView,
  });

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  final _worker = AlbumCatalogWorker();
  final _scroll = AlbumScrollController();
  final _wall = GlobalKey<AlbumWallState>();
  final _headerFocus = FocusNode(debugLabel: 'album toolbar');
  final _headerHidden = ValueNotifier(false);
  double _headerScrollTravel = 0;
  final _focusedItems = <String, String>{};
  final _stack = <({String path, String name, int anchor, double? offset})>[];
  final _listings = <String, List<SourceEntry>>{};
  final _settings = <String, Map<String, dynamic>>{};
  final _coverChanges = <String, Object>{};
  // Recycled wall cells and the viewer share prepared paths, never pixels or
  // widget state. Each returning cell revalidates through the preview worker.
  final _videoCovers = <(String, int, int), String>{};
  Object? _videoCoverRevision;

  Object _videoContentRevision() => (
    widget.model.store.sourceConfigurationRevision,
    widget.model.cacheRevision,
  );

  String? _preparedVideoCover(SourceEntry entry) {
    final key = (entry.path, entry.size, entry.modified);
    final path = _videoCovers.remove(key);
    if (path != null) _videoCovers[key] = path;
    return path;
  }

  void _rememberVideoCover(SourceEntry entry, String? path) {
    final key = (entry.path, entry.size, entry.modified);
    _videoCovers.remove(key);
    if (path == null) return;
    _videoCovers[key] = path;
    if (_videoCovers.length > 256) {
      _videoCovers.remove(_videoCovers.keys.first);
    }
  }

  final _viewportAnchors = <String, ({String id, double relativeOffset})>{};
  final _orderingRevisions = <String, int>{};
  int _nextOrderingRevision = 0;
  ({String path, String id, double relativeOffset})? _restoredViewport;
  final _views =
      <
        String,
        ({AlbumSnapshot snapshot, Map<String, AlbumFileMetadata> metadata})
      >{};
  AlbumImageService? _images;
  AlbumOptions _options = AlbumOptions();
  bool _sortSelected = false;
  Set<String> _coverExtensions = const {};
  AlbumSnapshot _snapshot = AlbumSnapshot.empty;
  List<SourceEntry> _entries = const [];
  int _generation = 0, _filterRevision = 0;
  int _connectionRevision = 0;
  CancelToken? _listingCancel;
  AlbumOpenAttempt? _opening;
  bool _busy = true, _covered = false;
  ModalRoute<dynamic>? _route;
  bool get _routeCurrent => _route?.isCurrent ?? true;
  bool _switchingView = false;
  bool _scrolling = false, _pendingLoad = false, _pendingRefresh = false;
  bool _choosingCover = false;
  Map<String, AlbumFileMetadata> _metadata = {};
  int _metadataRevision = 0, _metadataCursor = 0;
  List<SourceEntry> _metadataCandidates = const [];
  Timer? _metadataRefresh;
  bool _metadataDirty = false;
  bool _indexing = false, _indexRunning = false;
  bool _resumeIndex = false, _filterPending = false;
  AlbumImageHandle? _metadataHandle;
  String _error = '';
  bool _initialSelectionPending = true;
  Map<String, dynamic>? _cover;
  bool _hideCover = false;

  String get _sourceId => widget.source['id'] as String;
  String get _path => _stack.last.path;
  bool get _active =>
      mounted &&
      widget.active &&
      _routeCurrent &&
      !_covered &&
      ArtworkLifecycle.instance.value;
  String get _settingsPath =>
      albumSettingsPath(widget.model.documents.path, _sourceId, _path);

  @override
  void initState() {
    super.initState();
    _stack.add((
      path: widget.initialPath,
      name: widget.initialName ?? p.basename(widget.initialPath),
      anchor: widget.initialAnchor,
      offset: widget.initialOffset,
    ));
    if (widget.initialEntries != null) {
      _listings[_path] = widget.initialEntries!;
    }
    if (widget.initialSettings != null) {
      _settings[_path] = widget.initialSettings!;
    }
    ArtworkLifecycle.instance.addListener(_activityChanged);
    _videoCoverRevision = _videoContentRevision();
    widget.model.addListener(_imagePreferencesChanged);
    unawaited(_connect());
  }

  @override
  void didUpdateWidget(AlbumPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_imagePreferencesChanged);
      widget.model.addListener(_imagePreferencesChanged);
    }
    if (oldWidget.model != widget.model ||
        !mapEquals(oldWidget.source, widget.source) ||
        oldWidget.initialPath != widget.initialPath) {
      _generation++;
      _opening?.dispose();
      _opening = null;
      _covered = false;
      _busy = true;
      _cover = null;
      _hideCover = false;
      _choosingCover = false;
      _listingCancel?.cancel();
      _metadataHandle?.cancel();
      _worker.cancelBuilds();
      _images?.removeListener(_imageCapacity);
      _images?.dispose();
      _images = null;
      _listings.clear();
      _settings.clear();
      _coverChanges.clear();
      _videoCovers.clear();
      _videoCoverRevision = _videoContentRevision();
      _viewportAnchors.clear();
      _focusedItems.clear();
      _orderingRevisions.clear();
      _restoredViewport = null;
      _views.clear();
      _metadata.clear();
      _metadataRefresh?.cancel();
      _metadataDirty = false;
      _metadataCandidates = const [];
      _indexing = false;
      _metadataCursor = 0;
      _snapshot = AlbumSnapshot.empty;
      _stack
        ..clear()
        ..add((
          path: widget.initialPath,
          name: widget.initialName ?? p.basename(widget.initialPath),
          anchor: 0,
          offset: null,
        ));
      if (widget.initialEntries != null) {
        _listings[_path] = widget.initialEntries!;
      }
      if (widget.initialSettings != null) {
        _settings[_path] = widget.initialSettings!;
      }
      unawaited(_connect());
    }
    _activityChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _activityChanged();
  }

  void _activityChanged() {
    final enabled = _active;
    _images?.setActive(enabled);
    if (!enabled) {
      if (!_busy) _rememberViewport();
      _metadataRefresh?.cancel();
      _worker.cancelBuilds();
      _listingCancel?.cancel();
      _metadataHandle?.cancel();
      if (_scroll.hasClients &&
          _scroll.position is ScrollPositionWithSingleContext) {
        (_scroll.position as ScrollPositionWithSingleContext).goIdle();
      }
    } else if (_pendingLoad && _images != null) {
      _pendingLoad = false;
      unawaited(_load());
    }
    if (enabled && _metadataDirty) _scheduleMetadataRefresh();
    if (enabled && _filterPending) {
      _filterPending = false;
      unawaited(_filter(retainAnchor: true));
    }
    if (enabled && !_scrolling && _indexing) {
      if (_indexRunning) {
        _resumeIndex = true;
      } else {
        unawaited(_indexMetadata());
      }
    }
  }

  void _imagePreferencesChanged() {
    // Check source/cache revisions once per model event, never for each cell
    // built during a fling. Unrelated preview commits retain the warm paths.
    final videoRevision = _videoContentRevision();
    if (_videoCoverRevision != videoRevision) {
      _videoCoverRevision = videoRevision;
      _videoCovers.clear();
    }
    final images = _images;
    if (images == null) return;
    final preferences = widget.model.preferences;
    images.updateCacheLimits(
      thumbnailBytes: preferences.albumThumbnailCacheBytes,
      originalBytes: preferences.albumOriginalCacheBytes,
      metadataBytes: preferences.albumMetadataCacheBytes,
    );
  }

  Future<void> _connect() async {
    final ticket = ++_connectionRevision;
    final owner = widget.model;
    final source = widget.source;
    final sourceId = _sourceId;
    try {
      // Build a reused listing in parallel with credentials. Mode changes never
      // wait for a second directory request or a settings write before showing.
      final prepared = _listings.containsKey(_path) ? _load() : null;
      final password = sourceId == 'local'
          ? ''
          : await owner.secrets.read(key: 'source:$sourceId') ?? '';
      if (!mounted || ticket != _connectionRevision) return;
      final images = AlbumImageService(
        cacheDirectory: p.join(owner.documents.path, 'album-images-v1'),
        documentsPath: owner.documents.path,
        sourceId: sourceId,
        source: source,
        password: password,
        maxThumbnailBytes: owner.preferences.albumThumbnailCacheBytes,
        maxCacheBytes: owner.preferences.albumOriginalCacheBytes,
        maxMetadataBytes: owner.preferences.albumMetadataCacheBytes,
      );
      images.setActive(_active);
      images.setScrolling(_scrolling);
      images.addListener(_imageCapacity);
      setState(() => _images = images);
      if (prepared != null) {
        await prepared;
        if (!mounted || ticket != _connectionRevision) return;
        _activityChanged();
        _openInitialSelection();
        _startMetadata();
      } else {
        await _load();
      }
    } catch (error) {
      if (mounted && ticket == _connectionRevision) {
        setState(() {
          _busy = false;
          _error = safeFailure(error, action: '打开相册失败').message;
        });
      }
    }
  }

  Future<void> _load({bool refresh = false}) async {
    _pendingRefresh |= refresh;
    if (!_active || (_images == null && !_listings.containsKey(_path))) {
      _pendingLoad = true;
      return;
    }
    refresh = _pendingRefresh;
    _pendingRefresh = false;
    _revealHeader();
    if (refresh) _resetOrdering();
    final restoreIdentity =
        _stack.last.offset == null &&
        _stack.last.anchor == 0 &&
        !_views.containsKey(_path);
    _restoredViewport = null;
    final ticket = ++_generation;
    _filterPending = false;
    _indexing = false;
    _metadataHandle?.cancel();
    _metadata = refresh ? {} : _views[_path]?.metadata ?? {};
    _metadataCursor = 0;
    _metadataCandidates = const [];
    _metadataRefresh?.cancel();
    _metadataDirty = false;
    _metadataRevision++;
    if (refresh) _images?.invalidate();
    _listingCancel?.cancel();
    final cancel = _listingCancel = CancelToken();
    final storedViewport = _settings[_path]?['viewport'];
    final storedOffset = storedViewport is Map
        ? storedViewport['offset']
        : null;
    final initialOffset =
        _stack.last.offset ??
        (storedOffset is num && storedOffset.toDouble().isFinite
            ? storedOffset.toDouble().clamp(0.0, double.infinity)
            : 0.0);
    final wall = _wall.currentState;
    if (wall != null) {
      wall.restoreViewport(initialOffset);
    } else {
      _scroll.restoreOnNextLayout(() => initialOffset);
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final settings = !refresh && _settings.containsKey(_path)
          ? _settings[_path]!
          : await _worker.readPreferences(_settingsPath);
      if (!mounted || ticket != _generation) return;
      cancel.check();
      _settings[_path] = settings;
      final viewport = settings['viewport'];
      if (viewport is Map && viewport['focusedId'] is String) {
        _focusedItems.putIfAbsent(_path, () => viewport['focusedId'] as String);
      }
      if (restoreIdentity && viewport is Map) {
        final id = viewport['id'], relative = viewport['relativeOffset'];
        if (id is String &&
            id.isNotEmpty &&
            relative is num &&
            relative.toDouble().isFinite) {
          final anchor = (id: id, relativeOffset: relative.toDouble());
          _viewportAnchors[_path] = anchor;
          _restoredViewport = (
            path: _path,
            id: anchor.id,
            relativeOffset: anchor.relativeOffset,
          );
        }
      }
      if (_stack.last.offset == null && _stack.last.anchor == 0) {
        if (viewport is Map && viewport['offset'] is num) {
          final offset = (viewport['offset'] as num).toDouble();
          if (offset.isFinite && offset >= 0) {
            final last = _stack.removeLast();
            _stack.add((
              path: last.path,
              name: last.name,
              anchor: last.anchor,
              offset: offset,
            ));
          }
        }
      }
      final savedOptions = settings['options'];
      final legacyDefault =
          !settings.containsKey('sortSelected') &&
          savedOptions is Map &&
          savedOptions['sortField'] == 'captured' &&
          savedOptions['descending'] != false;
      _sortSelected =
          settings['sortSelected'] == true ||
          (!settings.containsKey('sortSelected') &&
              savedOptions is Map &&
              savedOptions.containsKey('sortField') &&
              !legacyDefault);
      final restoredOptions = AlbumOptions.fromJson(savedOptions);
      // Earlier releases also wrote the default chronology on every visit.
      // Migrate that legacy default once; explicit choices now carry a marker.
      _options =
          (legacyDefault
                  ? restoredOptions.copyWith(
                      sortField: 'name',
                      descending: false,
                    )
                  : restoredOptions)
              .copyWith(
                query: '',
                orientation: 'any',
                minSize: null,
                maxSize: null,
                minWidth: null,
                maxWidth: null,
                minHeight: null,
                maxHeight: null,
                minDurationMilliseconds: null,
                maxDurationMilliseconds: null,
                hideHiddenFiles:
                    settings['options'] is Map &&
                        (settings['options'] as Map).containsKey(
                          'hideHiddenFiles',
                        )
                    ? null
                    : widget.model.preferences.hideHiddenFiles,
              );
      _cover = settings['cover'] is Map
          ? Map<String, dynamic>.from(settings['cover'] as Map)
          : null;
      _hideCover = settings['hideCover'] == true;
      if (_sourceId == 'local') await AppleFileAccess.remember(_path);
      cancel.check();
      final entries = !refresh && _listings.containsKey(_path)
          ? _listings[_path]!
          : await _images!.listDirectory(_path, cancel: cancel);
      if (!mounted || ticket != _generation) return;
      cancel.check();
      if (_listings.length >= 8 && !_listings.containsKey(_path)) {
        final oldest = _listings.keys.first;
        _listings.remove(oldest);
        _settings.remove(oldest);
        _viewportAnchors.remove(oldest);
        _focusedItems.remove(oldest);
        _orderingRevisions.remove(oldest);
        _views.remove(oldest);
      }
      _listings[_path] = entries;
      _entries = entries;
      // Navigation ends the previous directory's scroll, but artwork keeps a
      // short idle grace period. Publish the destination before restoring its
      // viewport and focus instead of deferring it past that restoration.
      await _filter(initialLoad: true);
      cancel.check();
      if (!mounted || ticket != _generation) return;
      final restored = _restoredViewport;
      final restoredIndex = restored?.path == _path
          ? _snapshot.indexById[restored?.id]
          : null;
      final initialFocusIndex = restoredIndex ?? _stack.last.anchor;
      final focusedId =
          _focusedItems[_path] ??
          (TelevisionMode.read(context) && _snapshot.items.isNotEmpty
              ? _snapshot
                    .items[initialFocusIndex.clamp(
                      0,
                      _snapshot.items.length - 1,
                    )]
                    .id
              : null);
      if (restoredIndex != null) {
        _wall.currentState?.restoreIndex(
          restoredIndex,
          relativeOffset: restored!.relativeOffset,
          focusedId: focusedId,
        );
      } else if (_stack.last.offset case final double offset) {
        _wall.currentState?.restoreViewport(offset, focusedId: focusedId);
      } else {
        _wall.currentState?.restoreIndex(
          _stack.last.anchor,
          focusedId: focusedId,
        );
      }
      // The saved identity only owns the initial layout. Later metadata
      // publications must preserve the live viewport, including remote moves.
      _restoredViewport = null;
      _save();
    } on Cancelled {
      if (mounted && ticket == _generation) _pendingLoad = true;
    } catch (error) {
      if (mounted && ticket == _generation) {
        setState(() => _error = safeFailure(error, action: '读取相册失败').message);
      }
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
      if (identical(_listingCancel, cancel)) _listingCancel = null;
    }
    if (mounted && ticket == _generation) {
      _openInitialSelection();
      _startMetadata();
    }
  }

  void _openInitialSelection() {
    if (_active && _images != null && _initialSelectionPending && !_busy) {
      _initialSelectionPending = false;
      final index = _snapshot.indexByPath[widget.initialEntryPath];
      if (index != null) unawaited(_open(_snapshot.items[index]));
    }
  }

  Future<void> _filter({
    bool retainAnchor = false,
    bool initialLoad = false,
  }) async {
    if (!_active || (_scrolling && !initialLoad)) {
      _filterPending = true;
      return;
    }
    final ticket = ++_filterRevision;
    _coverExtensions = _options.types.isEmpty || _options.types.contains('*')
        ? _options.includeExtensions
        : Set.unmodifiable(
            _options.types.where((type) => type.startsWith('.')),
          );
    final generation = _generation;
    final directory = _path;
    try {
      final result = await _worker.build(
        _entries,
        sourceId: _sourceId,
        directory: directory,
        options: _options,
        metadata: _metadata,
        dataRevision: _metadataRevision,
        orderingRevision: _orderingRevisions.putIfAbsent(
          directory,
          () => ++_nextOrderingRevision,
        ),
      );
      if (!mounted ||
          ticket != _filterRevision ||
          generation != _generation ||
          directory != _path) {
        return;
      }
      if (!_active || (_scrolling && !initialLoad)) {
        _filterPending = true;
        return;
      }
      // Capture the live viewport at publication, since a gesture may have
      // completed while the worker prepared this snapshot.
      final wall = _wall.currentState;
      final anchor = wall?.anchorIndex ?? 0;
      final restored = _restoredViewport?.path == directory
          ? _restoredViewport
          : null;
      final id =
          restored?.id ??
          (anchor < _snapshot.items.length ? _snapshot.items[anchor].id : null);
      final relativeOffset =
          restored?.relativeOffset ??
          (_scroll.hasClients && wall != null
              ? _scroll.offset - wall.itemScrollOffset(anchor)
              : 0.0);
      setState(() => _snapshot = result);
      if (retainAnchor) {
        final index = result.indexById[id];
        if (index == null) _restoredViewport = null;
        wall?.restoreIndex(
          index ?? 0,
          relativeOffset: index == null ? 0 : relativeOffset,
          onlyWhenIdle: true,
        );
      }
    } on AlbumCatalogCancelled {
      // A newer filter owns the result.
      if (mounted && ticket == _filterRevision && !_active) {
        _filterPending = true;
      }
    } on AlbumCatalogFailure catch (error) {
      if (mounted && ticket == _filterRevision && generation == _generation) {
        setState(() => _error = error.message);
      }
    }
  }

  void _imageCapacity() {
    if (_active &&
        !_scrolling &&
        _indexing &&
        !_indexRunning &&
        _images?.pendingCount == 0) {
      unawaited(_indexMetadata());
    }
  }

  void _metadataLoaded(SourceEntry entry, AlbumImageResult result) {
    if (!mounted ||
        !_active ||
        result.sourcePath != entry.path ||
        result.metadata == null) {
      return;
    }
    final previous = _metadata[entry.path], next = result.metadata!;
    if (previous != null &&
        previous.capturedAt == next.capturedAt &&
        previous.width == next.width &&
        previous.height == next.height &&
        previous.durationMilliseconds == next.durationMilliseconds) {
      return;
    }
    _metadata[entry.path] = next;
    _metadataRevision++;
    _metadataDirty = true;
    _scheduleMetadataRefresh();
  }

  void _scheduleMetadataRefresh() {
    if (!_active ||
        _scrolling ||
        _busy ||
        !_needsCatalogMetadata ||
        !_metadataDirty ||
        (_indexing && !_metadataAffectsFilter) ||
        _metadataRefresh?.isActive == true) {
      return;
    }
    _metadataRefresh = Timer(const Duration(milliseconds: 250), () {
      if (!_active ||
          _scrolling ||
          !_metadataDirty ||
          (_indexing && !_metadataAffectsFilter)) {
        return;
      }
      _metadataDirty = false;
      unawaited(_filter(retainAnchor: true));
    });
  }

  bool get _metadataAffectsFilter =>
      (_options.dateField == 'captured' &&
          (_options.dateFrom != null ||
              _options.dateTo != null ||
              _options.unknownDatesOnly)) ||
      _options.orientation != 'any' ||
      _options.minWidth != null ||
      _options.maxWidth != null ||
      _options.minHeight != null ||
      _options.maxHeight != null ||
      _options.minDurationMilliseconds != null ||
      _options.maxDurationMilliseconds != null;

  bool get _needsCatalogMetadata =>
      _options.sortField == 'captured' || _metadataAffectsFilter;

  void _resetOrdering() {
    _orderingRevisions[_path] = ++_nextOrderingRevision;
    _metadataRefresh?.cancel();
  }

  Future<void> _indexMetadata() async {
    if (_indexRunning ||
        !_indexing ||
        !_active ||
        _scrolling ||
        _images == null ||
        _images!.pendingCount > 0) {
      return;
    }
    _indexRunning = true;
    _resumeIndex = false;
    final directory = _path;
    final ticket = _generation;
    final candidates = _metadataCandidates;
    try {
      while (_active &&
          !_scrolling &&
          _images!.pendingCount == 0 &&
          _indexing &&
          ticket == _generation &&
          _metadataCursor < candidates.length) {
        final entry = candidates[_metadataCursor];
        if (_metadata.containsKey(entry.path)) {
          _metadataCursor++;
          continue;
        }
        final handle = _metadataHandle = _images!.loadMetadata(entry);
        final result = await handle.future;
        if (!_active ||
            _scrolling ||
            !_indexing ||
            ticket != _generation ||
            result.cancelled ||
            result.deferred) {
          return;
        }
        _metadataLoaded(entry, result);
        _metadataCursor++;
      }
      if (mounted &&
          _active &&
          !_scrolling &&
          ticket == _generation &&
          directory == _path &&
          _indexing &&
          _metadataCursor >= candidates.length) {
        _indexing = false;
        _scheduleMetadataRefresh();
      }
    } finally {
      _metadataHandle = null;
      _indexRunning = false;
      if (_resumeIndex && _active && !_scrolling && _indexing) {
        _resumeIndex = false;
        scheduleMicrotask(_indexMetadata);
      }
    }
  }

  void _startMetadata() {
    if (!_needsCatalogMetadata ||
        _snapshot.metadataEntries.isEmpty ||
        _images == null) {
      _indexing = false;
      _resumeIndex = false;
      _metadataHandle?.cancel();
      return;
    }
    _metadataCandidates = _snapshot.metadataEntries;
    _metadataCursor = 0;
    _indexing = true;
    _resumeIndex = _indexRunning;
    // Give the wall its first layout so visible thumbnail requests enter the
    // queue before the low-priority catalog pass. No file work runs here.
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && !_scrolling) {
        unawaited(_indexMetadata());
      }
    });
  }

  Future<void> _save({bool album = true}) async {
    final path = _path;
    final coverChange = _coverChanges[path];
    final images = _images;
    final anchor = _viewportAnchors[_path];
    final values = <String, dynamic>{
      'album': album,
      'options': _options.toJson(),
      'sortSelected': _sortSelected,
      if (_stack.last.offset != null)
        'viewport': {
          'offset': _stack.last.offset,
          if (_focusedItems[_path] case final String id) 'focusedId': id,
          if (anchor != null) ...{
            'id': anchor.id,
            'relativeOffset': anchor.relativeOffset,
          },
        },
      if (_cover != null) 'cover': _cover,
      if (_hideCover) 'hideCover': true,
    };
    _settings[_path] = values;
    try {
      await _worker.savePreferences(_settingsPath, values);
      // Viewport saves can supersede a pending cover write. Invalidate only
      // once the latest choice actually reaches disk, including after back.
      if (coverChange != null && identical(_coverChanges[path], coverChange)) {
        _coverChanges.remove(path);
        if (mounted && identical(_images, images)) images?.invalidate();
      }
    } on AlbumCatalogCancelled {
      /* A newer setting replaces this pending write. */
    } on AlbumCatalogFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _switchToFiles() async {
    if (!_active || _busy || _switchingView || widget.onFileView == null) {
      return;
    }
    _switchingView = true;
    _rememberViewport();
    final path = _path, name = _stack.last.name, generation = _generation;
    try {
      await _save(album: false);
      if (mounted && _active && generation == _generation && path == _path) {
        widget.onFileView?.call(path, name);
      }
    } finally {
      _switchingView = false;
    }
  }

  void _rememberAnchor() {
    final wall = _wall.currentState;
    final focusedId = wall?.focusedId;
    if (focusedId != null && _snapshot.indexById.containsKey(focusedId)) {
      _focusedItems[_path] = focusedId;
    }
    final restored = _restoredViewport?.path == _path
        ? _restoredViewport
        : null;
    final anchor = _snapshot.indexById[restored?.id] ?? wall?.anchorIndex;
    if (anchor != null &&
        anchor >= 0 &&
        anchor < _snapshot.items.length &&
        wall != null &&
        _scroll.hasClients) {
      _viewportAnchors[_path] = (
        id: _snapshot.items[anchor].id,
        relativeOffset: _scroll.offset - wall.itemScrollOffset(anchor),
      );
    }
    final last = _stack.removeLast();
    _stack.add((
      path: last.path,
      name: last.name,
      anchor: anchor ?? last.anchor,
      offset: _scroll.hasClients ? _scroll.offset : last.offset,
    ));
    _views[_path] = (snapshot: _snapshot, metadata: _metadata);
  }

  void _rememberViewport() {
    if (_busy ||
        _scroll.restoring ||
        !_scroll.hasClients ||
        _snapshot.items.isEmpty) {
      return;
    }
    final previous = _stack.last.offset;
    final previousAnchor = _viewportAnchors[_path];
    final previousFocus = _focusedItems[_path];
    _rememberAnchor();
    if (previous != _stack.last.offset ||
        previousAnchor != _viewportAnchors[_path] ||
        previousFocus != _focusedItems[_path]) {
      unawaited(_save());
    }
  }

  Future<void> _open(AlbumItem item) async {
    if (!_active || _busy) return;
    if (_choosingCover) {
      if (item.isPhoto) await _chooseCover(item);
      return;
    }
    if (item.isDirectory) {
      _rememberViewport();
      _stack.add((
        path: item.preferred.path,
        name: item.name,
        anchor: 0,
        offset: null,
      ));
      _snapshot = _views[_path]?.snapshot ?? AlbumSnapshot.empty;
      await _load();
      return;
    }
    if (!item.isPhoto && !item.isAudio && !item.isVideo) {
      if (isTextFile(item.name)) {
        try {
          await openSourceDocument(
            context,
            model: widget.model,
            sourceId: _sourceId,
            source: widget.source,
            entry: item.preferred,
          );
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
          }
        }
      } else {
        await _itemMenu(item);
      }
      return;
    }
    _rememberViewport();
    final returnOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    final returnFocus = _wall.currentState?.focusedId;
    final index = _snapshot.indexById[item.id] ?? 0;
    final generation = _generation;
    final model = widget.model;
    final source = Map<String, dynamic>.unmodifiable(widget.source);
    final sourceId = _sourceId;
    final snapshot = _snapshot;
    bool sameOwner() =>
        mounted &&
        generation == _generation &&
        identical(widget.model, model) &&
        mapEquals(widget.source, source);
    final attempt = _opening = AlbumOpenAttempt(
      () =>
          sameOwner() &&
          widget.active &&
          _routeCurrent &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
    setState(() => _covered = true);
    _activityChanged();
    try {
      attempt.check();
      if (item.isPhoto || item.isVideo) {
        // The viewer owns a separate queue so the hidden wall cannot refill it.
        final password = sourceId == 'local'
            ? ''
            : await model.secrets.read(key: 'source:$sourceId') ?? '';
        attempt.check();
        final entry = item.preferred;
        final videoThumbnail = item.isVideo ? _preparedVideoCover(entry) : null;
        if (!mounted) return;
        final route = AlbumViewerRoute<int>(
          builder: (_) => AlbumViewer(
            model: model,
            source: source,
            password: password,
            snapshot: snapshot,
            initialIndex: index,
            initialPreview: _images?.peek(item.preferred),
            initialVideoThumbnail: videoThumbnail,
          ),
        );
        await Navigator.push<int>(context, route);
        // The push future finishes when pop starts. Retain the wall's pixels
        // without resuming decoding, EXIF or filtering during the return slide.
        await route.completed;
      } else if (item.isAudio) {
        await PlayerPage.waitForDisposals();
        attempt.check();
        await MusicPage.waitForDisposals();
        attempt.check();
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MusicPage(
              model: model,
              sourceId: sourceId,
              entries: snapshot.audioEntries,
              initialIndex: snapshot.audioIndexByPath[item.preferred.path] ?? 0,
            ),
          ),
        );
      } else {
        await playAlbumMedia(
          context,
          model,
          sourceId,
          item.preferred,
          attempt: attempt,
        );
      }
    } on Cancelled {
      // Backgrounding or changing the owning page permanently ends this tap.
    } catch (error) {
      if (mounted && sameOwner() && !attempt.token.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(safeFailure(error, action: '打开媒体失败').message)),
        );
      }
    } finally {
      attempt.dispose();
      if (identical(_opening, attempt)) {
        _opening = null;
        if (mounted) {
          setState(() => _covered = false);
          _activityChanged();
          if (sameOwner()) {
            _wall.currentState?.restoreViewport(
              returnOffset,
              focusedId: returnFocus,
            );
          }
        }
      }
    }
  }

  void _back() {
    _opening?.cancel();
    if (_choosingCover) {
      setState(() => _choosingCover = false);
      return;
    }
    if (_stack.length > 1) {
      _rememberViewport();
      _stack.removeLast();
      _snapshot = _views[_path]?.snapshot ?? AlbumSnapshot.empty;
      unawaited(_load());
    } else if (widget.onExit != null) {
      _rememberViewport();
      widget.onExit!();
    } else {
      _rememberViewport();
      Navigator.maybePop(context);
    }
  }

  Future<void> _filters() async {
    if (_busy) return;
    final generation = _generation;
    final options = await showAlbumFilterSheet(
      context,
      initial: _options,
      snapshot: _snapshot,
    );
    if (options == null || !mounted || generation != _generation) return;
    _options = options;
    _sortSelected = true;
    _resetOrdering();
    _save();
    await _filter(retainAnchor: true);
    _startMetadata();
  }

  Future<void> _itemMenu(AlbumItem item) async {
    if (!item.isPhoto) {
      await showSourceFileDownloadMenu(
        context,
        widget.model,
        _sourceId,
        item.preferred,
        personalMedia: true,
        source: widget.source,
      );
      return;
    }
    final generation = _generation;
    final local = _sourceId == 'local';
    final action = await showGlassBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: GlassSheetBody(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(sheet),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('设为相册封面'),
                  onTap: () => Navigator.pop(sheet, 'cover'),
                ),
                if (local)
                  ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('保存位置'),
                    onTap: () => Navigator.pop(sheet, 'path'),
                  )
                else ...[
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(
                      item.members.length > 1
                          ? '下载全部格式（${item.members.length}）'
                          : '下载',
                    ),
                    onTap: () => Navigator.pop(sheet, 'download'),
                  ),
                  if (item.members.length > 1)
                    ListTile(
                      leading: const Icon(Icons.layers_outlined),
                      title: const Text('选择格式下载'),
                      onTap: () => Navigator.pop(sheet, 'version'),
                    ),
                  if (item.members.length == 1 &&
                      widget.model.downloads.entryForSource(
                            _sourceId,
                            item.preferred.path,
                          ) !=
                          null)
                    ListTile(
                      leading: const Icon(Icons.downloading_outlined),
                      title: const Text('下载管理'),
                      onTap: () => Navigator.pop(sheet, 'manage'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || generation != _generation) return;
    switch (action) {
      case 'cover':
        await _chooseCover(item);
      case 'download':
        await _download(item.members);
      case 'version':
        final selected = await _pickMember(item, '选择格式下载');
        if (selected != null && mounted && generation == _generation) {
          await _download([selected]);
        }
      case 'manage':
        await showSourceFileDownloadMenu(
          context,
          widget.model,
          _sourceId,
          item.preferred,
          personalMedia: true,
        );
      case 'path':
        await showDownloadedFileLocation(context, item.preferred.path);
    }
  }

  Future<void> _download(List<SourceEntry> entries) async {
    final owner = widget.model;
    try {
      await owner.downloadSourceEntries(
        _sourceId,
        entries,
        personalMedia: true,
      );
      if (mounted && identical(widget.model, owner)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(owner.status)));
      }
    } catch (error) {
      if (mounted && identical(widget.model, owner)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(safeFailure(error, action: '下载失败').message)),
        );
      }
    }
  }

  Future<SourceEntry?> _pickMember(AlbumItem item, String title) =>
      showGlassBottomSheet<SourceEntry>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          top: false,
          child: GlassSheetBody(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(title),
                  trailing: IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(sheet),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemExtent: 48,
                    padding: EdgeInsets.zero,
                    itemCount: item.members.length,
                    itemBuilder: (_, index) => ListTile(
                      title: Text(
                        item.members[index].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(sheet, item.members[index]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _chooseCover(AlbumItem item) async {
    final generation = _generation;
    final selected = item.members.length == 1
        ? item.preferred
        : await _pickMember(item, '设为相册封面');
    if (selected == null || !mounted || generation != _generation) return;
    await _setCover(
      cover: {
        'name': selected.name,
        'path': selected.path,
        'size': selected.size,
        'modified': selected.modified,
      },
    );
  }

  Future<void> _setCover({
    Map<String, dynamic>? cover,
    bool hidden = false,
  }) async {
    setState(() {
      _cover = cover;
      _hideCover = hidden;
      _choosingCover = false;
      _coverChanges[_path] = Object();
    });
    await _save();
  }

  void _revealHeader() {
    _headerScrollTravel = 0;
    _headerHidden.value = false;
  }

  void _focusHeader() {
    final wallContext = _wall.currentContext;
    if (wallContext != null && TelevisionMode.read(context)) {
      TelevisionHeaderNavigation.focusHeader(wallContext);
      return;
    }
    _revealHeader();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active) return;
      final targets = _headerFocus.traversalDescendants;
      if (targets.isNotEmpty) targets.first.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _onScroll(ScrollNotification notification) {
    if (!_active ||
        _busy ||
        !widget.model.preferences.hideNavigationOnScroll ||
        _scroll.restoring ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        notification is! ScrollUpdateNotification) {
      return false;
    }
    final delta = notification.scrollDelta ?? 0;
    if (_headerScrollTravel.sign != delta.sign) _headerScrollTravel = 0;
    _headerScrollTravel += delta;
    if (_headerScrollTravel > 24 &&
        notification.metrics.pixels > 24 &&
        !_headerFocus.hasFocus) {
      _headerHidden.value = true;
    } else if (_headerScrollTravel < -12 || notification.metrics.pixels <= 0) {
      _headerHidden.value = false;
    }
    return false;
  }

  @override
  void dispose() {
    _rememberViewport();
    _generation++;
    _connectionRevision++;
    _filterRevision++;
    _listingCancel?.cancel();
    _opening?.dispose();
    _metadataHandle?.cancel();
    ArtworkLifecycle.instance.removeListener(_activityChanged);
    widget.model.removeListener(_imagePreferencesChanged);
    _images?.dispose();
    AlbumPage._finishWrites(_worker);
    _metadataRefresh?.cancel();
    _scroll.dispose();
    _headerFocus.dispose();
    _headerHidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = _images;
    final generation = _generation;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: GlassMenuTheme(
        child: PopScope(
          canPop:
              !widget.active ||
              (_stack.length <= 1 && !_choosingCover && widget.onExit == null),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop &&
                widget.active &&
                !TelevisionMenuRegion.navigationOwnsBack(context)) {
              _back();
            }
          },
          child: TelevisionHeaderNavigation(
            headerFocusNode: _headerFocus,
            onHeaderRequested: _revealHeader,
            child: NavigationRevealRegion(
              onReveal: _revealHeader,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: Scaffold(
                  backgroundColor: Colors.white,
                  extendBodyBehindAppBar: true,
                  appBar: PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _headerHidden,
                      builder: (context, hidden, child) => ExcludeFocus(
                        excluding: hidden,
                        child: IgnorePointer(
                          ignoring: hidden,
                          child: FractionalTranslation(
                            translation: hidden
                                ? const Offset(0, -1)
                                : Offset.zero,
                            child: child,
                          ),
                        ),
                      ),
                      child: Focus(
                        focusNode: _headerFocus,
                        skipTraversal: true,
                        canRequestFocus: false,
                        onFocusChange: (focused) {
                          if (focused) _revealHeader();
                        },
                        child: AppBar(
                          toolbarHeight: 48,
                          backgroundColor: Colors.white.withValues(alpha: .82),
                          surfaceTintColor: Colors.transparent,
                          elevation: 0,
                          actionsPadding: EdgeInsets.zero,
                          leading: BackButton(onPressed: _back),
                          title: Text(
                            _choosingCover
                                ? '选择相册封面'
                                : _stack.last.name.isEmpty
                                ? '相册'
                                : _stack.last.name,
                          ),
                          actions: [
                            if (widget.onFileView != null)
                              IconButton(
                                constraints: const BoxConstraints.tightFor(
                                  width: 36,
                                  height: 40,
                                ),
                                padding: EdgeInsets.zero,
                                tooltip: '文件视图',
                                onPressed: _busy ? null : _switchToFiles,
                                icon: const Icon(Icons.view_list_outlined),
                              ),
                            IconButton(
                              constraints: const BoxConstraints.tightFor(
                                width: 36,
                                height: 40,
                              ),
                              padding: EdgeInsets.zero,
                              tooltip: '排序',
                              onPressed: _busy ? null : _filters,
                              icon: const Icon(Icons.sort),
                            ),
                            PopupMenuButton<String>(
                              padding: EdgeInsets.zero,
                              tooltip: '相册选项',
                              child: const SizedBox(
                                width: 36,
                                height: 40,
                                child: Icon(Icons.more_vert),
                              ),
                              onSelected: (value) async {
                                if (!mounted || generation != _generation) {
                                  return;
                                }
                                if (value == 'remote') {
                                  await showRemoteControlDialog(context);
                                }
                                if (value == 'refresh') {
                                  unawaited(_load(refresh: true));
                                }
                                if (value == 'choose-cover') {
                                  setState(() => _choosingCover = true);
                                }
                                if (value == 'files') {
                                  await _switchToFiles();
                                }
                                if (value == 'cover') {
                                  await _setCover();
                                }
                                if (value == 'hide-cover') {
                                  await _setCover(hidden: true);
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  height: GlassMetrics.menuItemHeight,
                                  padding: GlassMetrics.menuItemPadding,
                                  value: 'remote',
                                  child: Text('手机控制'),
                                ),
                                const PopupMenuItem(
                                  height: GlassMetrics.menuItemHeight,
                                  padding: GlassMetrics.menuItemPadding,
                                  value: 'refresh',
                                  child: Text('刷新'),
                                ),
                                PopupMenuItem(
                                  height: GlassMetrics.menuItemHeight,
                                  padding: GlassMetrics.menuItemPadding,
                                  value: 'choose-cover',
                                  enabled: !_busy,
                                  child: const Text('选择相册封面'),
                                ),
                                if (!_hideCover)
                                  PopupMenuItem(
                                    height: GlassMetrics.menuItemHeight,
                                    padding: GlassMetrics.menuItemPadding,
                                    value: 'hide-cover',
                                    enabled: !_busy,
                                    child: const Text('不显示相册封面'),
                                  ),
                                if (_cover != null || _hideCover)
                                  PopupMenuItem(
                                    height: GlassMetrics.menuItemHeight,
                                    padding: GlassMetrics.menuItemPadding,
                                    value: 'cover',
                                    enabled: !_busy,
                                    child: const Text('恢复自动封面'),
                                  ),
                                if (widget.onFileView != null)
                                  const PopupMenuItem(
                                    height: GlassMetrics.menuItemHeight,
                                    padding: GlassMetrics.menuItemPadding,
                                    value: 'files',
                                    child: Text('文件视图'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  body: Stack(
                    children: [
                      Positioned.fill(
                        child: ArtworkScrollScope(
                          onActivityChanged: (value) {
                            _scrolling = value;
                            images?.setScrolling(_scrolling);
                            if (_scrolling) {
                              _restoredViewport = null;
                              _metadataRefresh?.cancel();
                              _metadataHandle?.cancel();
                            } else {
                              _rememberViewport();
                              if (_filterPending) {
                                _filterPending = false;
                                _metadataDirty = false;
                                unawaited(_filter(retainAnchor: true));
                              }
                              _scheduleMetadataRefresh();
                              if (_indexing) {
                                if (_indexRunning) {
                                  _resumeIndex = true;
                                } else {
                                  unawaited(_indexMetadata());
                                }
                              }
                            }
                          },
                          child: TickerMode(
                            enabled: _active,
                            child: AlbumWall(
                              key: _wall,
                              snapshot: _snapshot,
                              controller: _scroll,
                              active: _active,
                              onExitUp: _focusHeader,
                              padding: EdgeInsets.only(
                                top: MediaQuery.paddingOf(context).top + 48,
                                bottom: MediaQuery.paddingOf(context).bottom,
                              ),
                              onOpen: (item) => unawaited(_open(item)),
                              onMenu: (item) => unawaited(_itemMenu(item)),
                              thumbnail: (context, item, edge) {
                                if (item.isVideo) {
                                  final entry = item.preferred;
                                  return AlbumVideoThumbnail(
                                    model: widget.model,
                                    sourceId: _sourceId,
                                    entry: item.preferred,
                                    edge: edge,
                                    active: _active,
                                    initialThumbnail: _preparedVideoCover(
                                      entry,
                                    ),
                                    onThumbnailChanged: (path) {
                                      if (!mounted ||
                                          generation != _generation) {
                                        return;
                                      }
                                      _rememberVideoCover(entry, path);
                                    },
                                  );
                                }
                                final placeholder = Center(
                                  child: Icon(
                                    item.isDirectory
                                        ? Icons.folder_outlined
                                        : item.isVideo
                                        ? Icons.play_circle_outline
                                        : item.isAudio
                                        ? Icons.music_note
                                        : item.isPhoto
                                        ? Icons.image_outlined
                                        : Icons.insert_drive_file_outlined,
                                    color: Colors.black38,
                                    size: 36,
                                  ),
                                );
                                // A folder cover must not leak a member excluded by a filter
                                // that the shallow preview provider cannot evaluate.
                                if (images == null ||
                                    item.isAudio ||
                                    (!item.isPhoto && !item.isDirectory) ||
                                    (item.isDirectory &&
                                        (_options.query.isNotEmpty ||
                                            _options.kinds.isNotEmpty ||
                                            _options.minSize != null ||
                                            _options.maxSize != null ||
                                            _options.dateFrom != null ||
                                            _options.dateTo != null ||
                                            _options.orientation != 'any' ||
                                            _options.unknownDatesOnly ||
                                            _options.minWidth != null ||
                                            _options.maxWidth != null ||
                                            _options.minHeight != null ||
                                            _options.maxHeight != null ||
                                            _options.minDurationMilliseconds !=
                                                null ||
                                            _options.maxDurationMilliseconds !=
                                                null))) {
                                  return placeholder;
                                }
                                if (item.isDirectory) {
                                  return AlbumFolderThumbnail(
                                    model: widget.model,
                                    service: images,
                                    sourceId: _sourceId,
                                    entry: item.preferred,
                                    edge: edge,
                                    active: _active,
                                    placeholder: placeholder,
                                    extensions: _coverExtensions,
                                    excludedExtensions:
                                        _options.excludeExtensions,
                                    hideHidden: _options.hideHiddenFiles,
                                    preparedVideoCover: _preparedVideoCover,
                                    onVideoCoverChanged: (entry, path) {
                                      if (mounted &&
                                          generation == _generation) {
                                        _rememberVideoCover(entry, path);
                                      }
                                    },
                                  );
                                }
                                return AlbumThumbnail(
                                  service: images,
                                  entry: item.preferred,
                                  edge: edge,
                                  placeholder: placeholder,
                                  extensions: _coverExtensions,
                                  excludedExtensions:
                                      _options.excludeExtensions,
                                  hideHidden: _options.hideHiddenFiles,
                                  onLoaded: (result) {
                                    if (generation == _generation) {
                                      _metadataLoaded(item.preferred, result);
                                    }
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      if (_busy && _snapshot.items.isEmpty)
                        Positioned(
                          top: MediaQuery.paddingOf(context).top + 48,
                          left: 0,
                          right: 0,
                          child: const LinearProgressIndicator(minHeight: 2),
                        ),
                      if (!_busy &&
                          (_error.isNotEmpty || _snapshot.items.isEmpty))
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  _error.isNotEmpty ? _error : '没有符合条件的项目',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.black54),
                                ),
                              ),
                              TextButton(
                                onPressed: _error.isNotEmpty
                                    ? () => unawaited(_load(refresh: true))
                                    : _filters,
                                child: Text(_error.isNotEmpty ? '重试' : '调整筛选'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
