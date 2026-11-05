import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../core/logger.dart';
import '../data/album_catalog.dart';
import '../data/album_images.dart';
import '../data/app_model.dart';
import '../data/media_file_details.dart';
import '../playback/album_video_controller.dart';
import '../playback/session.dart';
import '../playback/display.dart';
import '../playback/desktop_window.dart';
import '../playback/input.dart';
import '../sources/source.dart';
import 'album_playback.dart';
import 'album_thumbnail.dart';
import 'album_video_player.dart';
import 'album_video_thumbnail.dart';
import 'artwork_lifecycle.dart';
import 'artwork_decode_queue.dart';
import 'media_artwork.dart';
import 'media_file_details.dart';
import 'glass.dart';
import 'music_page.dart';
import 'player_page.dart';
import 'remote_control.dart';

class AlbumViewer extends StatefulWidget {
  final AppModel model;
  final Map<String, dynamic> source;
  final String password;
  final AlbumSnapshot snapshot;
  final int initialIndex;
  final AlbumImageResult? initialPreview;
  final String? initialVideoThumbnail;
  final bool albumMode;
  const AlbumViewer({
    super.key,
    required this.model,
    required this.source,
    required this.password,
    required this.snapshot,
    required this.initialIndex,
    this.initialPreview,
    this.initialVideoThumbnail,
    this.albumMode = true,
  });
  @override
  State<AlbumViewer> createState() => _AlbumViewerState();
}

class _AlbumViewerState extends State<AlbumViewer>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;
  int _member = 0, _rotation = 0;
  int _lifecycleRevision = 0;
  final _transform = TransformationController();
  late final _transition =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 360),
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed &&
            mounted &&
            (_previous != null || _settleOffset != null)) {
          setState(() {
            _previous = null;
            _settleOffset = null;
          });
        }
        _syncVideoArtwork();
        if (status == AnimationStatus.completed && mounted) {
          _prefetchNeighbors();
        }
      });
  final _random = math.Random();
  final _prefetches = <String, _ViewerPrefetch>{};
  ({AlbumImageResult? result, int rotation, SourceEntry? video})? _previous;
  late AlbumVideoController _video = _createVideo();
  AlbumVideoController _createVideo() => AlbumVideoController(
    model: widget.model,
    sourceId: widget.source['id'] as String,
    beforeOpen: () async {
      await PlayerPage.waitForDisposals();
      await MusicPage.waitForDisposals();
    },
  );
  final _videoArtworkActive = ValueNotifier<bool>(false);
  final _videoCovers = <String, String>{};
  final _videoCoverReads = <String, ({CancelToken cancel, Object revision})>{};
  int _transitionKind = 0, _slideDirection = 1, _imageEdge = 512;
  int _prefetchDirection = 1;
  static const _pageGap = 12.0;
  double _dragOffset = 0;
  double? _settleOffset;
  final _pageUpdates = ValueNotifier<int>(0);
  Size _viewportSize = Size.zero;
  final _viewerFocus = FocusNode(debugLabel: 'album-viewer');
  final _infoFocus = FocusNode(debugLabel: 'album-info');
  final _videoControlsFocus = FocusNode(debugLabel: 'album-video-controls');
  late AlbumImageService _images = _createImages();
  AlbumImageService _createImages() => AlbumImageService(
    cacheDirectory: p.join(widget.model.documents.path, 'album-images-v1'),
    documentsPath: widget.model.documents.path,
    sourceId: widget.source['id'] as String,
    source: widget.source,
    password: widget.password,
    preferOriginal: true,
    maxThumbnailBytes: widget.model.preferences.albumThumbnailCacheBytes,
    maxCacheBytes: widget.model.preferences.albumOriginalCacheBytes,
    maxMetadataBytes: widget.model.preferences.albumMetadataCacheBytes,
  );
  bool _playing = false, _leaving = false;
  AlbumOpenAttempt? _opening;
  bool _infoOpen = false, _infoReadComplete = false;
  bool _slideshowSettingsOpen = false;
  SourceEntry? _infoEntry;
  AlbumImageHandle? _infoRequest;
  ValueNotifier<AlbumImageResult?>? _infoResult;
  bool _routeCurrent = true;
  ModalRoute<dynamic>? _route;
  Timer? _slideshow;
  bool _slides = false, _controlsVisible = true;
  late final _controlsTimer = PlaybackControlsTimer(() {
    if (_canInteract && !_infoOpen) _setControlsVisible(false);
  });
  bool _whiteCanvas = true, _zoomed = false;
  bool? _slideshowLandscape;
  PlayerViewportRestore? _viewportRestore;
  bool _motionEnabled = true;
  Offset? _doubleTapPosition, _swipeStart, _swipeLast;
  int? _swipePointer;
  bool _swipeAllowed = false;
  bool _horizontalSwipe = false;
  VelocityTracker? _swipeVelocity;
  final _pointers = <int>{};
  final _systemUi = _ViewerSystemUi();
  late AlbumImageResult? _imageResult = widget.initialPreview;
  AlbumItem get _item => widget.snapshot.items[_index];
  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _transform.addListener(_transformChanged);
    _seedVideoCover();
    _video.select(_item.isVideo ? _item.preferred : null);
    _video.addListener(_videoChanged);
    ArtworkLifecycle.instance.addListener(_lifecycle);
    widget.model.addListener(_imagePreferencesChanged);
    _lifecycle();
  }

  @override
  void didUpdateWidget(AlbumViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_imagePreferencesChanged);
      widget.model.addListener(_imagePreferencesChanged);
    }
    final ownerChanged =
        oldWidget.model != widget.model ||
        !mapEquals(oldWidget.source, widget.source) ||
        oldWidget.password != widget.password ||
        oldWidget.albumMode != widget.albumMode;
    if (!ownerChanged && identical(oldWidget.snapshot, widget.snapshot)) return;
    final previousId = oldWidget.snapshot.items[_index].id;
    _opening?.cancel();
    _lifecycleRevision++;
    _infoRequest?.cancel();
    _infoRequest = null;
    _infoEntry = null;
    _cancelPrefetches();
    if (ownerChanged) {
      _video.removeListener(_videoChanged);
      _video.dispose();
      _images.dispose();
      _images = _createImages();
      _video = _createVideo()..addListener(_videoChanged);
    }
    _index =
        (!ownerChanged ? widget.snapshot.indexById[previousId] : null) ??
        widget.initialIndex.clamp(0, widget.snapshot.items.length - 1);
    _member = _rotation = 0;
    _prefetchDirection = 1;
    _previous = null;
    _videoCovers.clear();
    _imageResult = ownerChanged ? widget.initialPreview : null;
    _clearSwipe();
    _transition.stop();
    _transition.value = 1;
    _transform.value = Matrix4.identity();
    _video.select(_item.isVideo ? _item.preferred : null);
    _lifecycle();
  }

  void _seedVideoCover() {
    final thumbnail = widget.initialVideoThumbnail;
    if (thumbnail != null && _index == widget.initialIndex && _item.isVideo) {
      _videoCovers[_item.preferred.path] = thumbnail;
    }
  }

  void _lifecycle() {
    // Playback handles hidden/paused directly. Inactive only suspends artwork.
    _video.setVisible(!_leaving && !_playing && _routeCurrent && !_infoOpen);
    if (!ArtworkLifecycle.instance.value) {
      _lifecycleRevision++;
      _infoRequest?.cancel();
      _infoRequest = null;
    }
    _images.setActive(
      ArtworkLifecycle.instance.value &&
          !_playing &&
          !_leaving &&
          (_routeCurrent || _infoOpen),
    );
    _syncPresentation();
    if (!ArtworkLifecycle.instance.value ||
        !_routeCurrent ||
        _leaving ||
        _playing) {
      _slideshow?.cancel();
      _slideshow = null;
      final stopSlides =
          !ArtworkLifecycle.instance.value ||
          _leaving ||
          _playing ||
          !_slideshowSettingsOpen;
      final presentationChanged = stopSlides && _slides || !_controlsVisible;
      if (stopSlides) _slides = false;
      _controlsVisible = true;
      if (presentationChanged && mounted) setState(() {});
      _controlsTimer.cancel();
      _syncPresentation();
      final hadSwipe = _dragOffset != 0;
      _clearSwipe();
      _transition.stop();
      _previous = null;
      if (_transition.value != 1) _transition.value = 1;
      if (hadSwipe && mounted) setState(() {});
      _cancelPrefetches();
    } else {
      _prefetchNeighbors();
    }
    if (_infoOpen && ArtworkLifecycle.instance.value) _loadInfoMetadata();
    _syncVideoArtwork();
  }

  void _imagePreferencesChanged() {
    final preferences = widget.model.preferences;
    _images.updateCacheLimits(
      thumbnailBytes: preferences.albumThumbnailCacheBytes,
      originalBytes: preferences.albumOriginalCacheBytes,
      metadataBytes: preferences.albumMetadataCacheBytes,
    );
  }

  void _syncVideoArtwork() {
    // Gestures still prepare the immediate neighbor. Optional disk reclamation
    // and thumbnail conversion wait until the gesture/transition has settled.
    _images.setMaintenanceHeld(_horizontalSwipe || _transition.isAnimating);
    _videoArtworkActive.value =
        !_leaving &&
        !_playing &&
        _routeCurrent &&
        !_infoOpen &&
        ArtworkLifecycle.instance.value &&
        !_transition.isAnimating &&
        !_horizontalSwipe &&
        !_video.loading &&
        _video.session == null;
  }

  void _videoChanged() {
    if (!mounted) return;
    _syncVideoArtwork();
    _syncPresentation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mobile) _viewportRestore ??= PlayerViewportRestore(View.of(context));
    _motionEnabled = MotionScope.enabledOf(context);
    if (!_motionEnabled) {
      _transition.stop();
      _previous = null;
      if (_transition.value != 1) _transition.value = 1;
    }
    final size = MediaQuery.sizeOf(context);
    final edge =
        ((math.max(size.width, size.height) *
                        MediaQuery.devicePixelRatioOf(context) /
                        64)
                    .ceil() *
                64)
            .clamp(512, 2560);
    if (_imageEdge != edge) {
      _imageEdge = edge;
    }
    if (_viewportSize != size) {
      _viewportSize = size;
      _centerImage(_transform.value.getMaxScaleOnAxis());
    }
    _route = ModalRoute.of(context);
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _lifecycle();
  }

  void _next(int delta, {double? dragOffset}) {
    if (!_canInteract) return;
    final index = delta < 0
        ? widget.snapshot.previousMediaIndex[_index]
        : widget.snapshot.nextMediaIndex[_index];
    if (index == null) return;
    if (dragOffset == null) _clearSwipe();
    _opening?.cancel();
    final warmed =
        _prefetches[widget.snapshot.items[index].preferred.path]?.result;
    final animate =
        _motionEnabled &&
        (dragOffset != null ||
            !_slides ||
            widget.model.preferences.albumSlideshowTransition != 'none');
    _previous = animate
        ? (
            result: _imageResult,
            rotation: _rotation,
            video: _item.isVideo ? _item.preferred : null,
          )
        : null;
    if (_slides && animate && dragOffset == null) {
      // Pick a different effect at each advance, without a repeating timer.
      _transitionKind =
          switch (widget.model.preferences.albumSlideshowTransition) {
            'slide' => 0,
            'fade' => 1,
            _ => (_transitionKind + 1 + _random.nextInt(5)) % 6,
          };
    } else {
      _transitionKind = 0;
    }
    _slideDirection = delta.sign;
    _prefetchDirection = delta.sign;
    _settleOffset = dragOffset;
    _dragOffset = 0;
    // Keep an in-flight neighbor request alive when it becomes visible. Its
    // thumbnail joins the same worker job instead of cancelling and rereading.
    _prefetches[widget.snapshot.items[index].preferred.path]
        ?.handle
        .updatePriority
        ?.call(0);
    _prefetches[widget.snapshot.items[index].preferred.path]?.decode
        ?.refreshPriority();
    setState(() {
      _index = index;
      _member = 0;
      _rotation = 0;
      _imageResult = warmed ?? _images.peek(_item.preferred);
      _transform.value = Matrix4.identity();
      if (_item.isVideo) _controlsVisible = true;
    });
    _video.select(_item.isVideo ? _item.preferred : null);
    final retainedCovers = {
      _item.preferred.path,
      if (_previous?.video != null) _previous!.video!.path,
      if (widget.snapshot.previousMediaIndex[_index] case final int previous)
        widget.snapshot.items[previous].preferred.path,
      if (widget.snapshot.nextMediaIndex[_index] case final int next)
        widget.snapshot.items[next].preferred.path,
    };
    _videoCovers.removeWhere((path, _) => !retainedCovers.contains(path));
    if (animate) {
      _transition.forward(from: 0);
    } else {
      _transition.stop();
      _transition.value = 1;
    }
    // Already warm neighbors can render immediately; the newly exposed side
    // starts a bounded disk/decode prefetch before another swipe finishes.
    _prefetchNeighbors();
    _syncVideoArtwork();
    _syncPresentation();
  }

  void _cancelPrefetches() {
    for (final read in _videoCoverReads.values) {
      read.cancel.cancel();
    }
    _videoCoverReads.clear();
    for (final prefetch in _prefetches.values) {
      prefetch.handle.cancel();
      prefetch.decode?.cancel();
    }
    _prefetches.clear();
  }

  void _prefetchNeighbors({int? direction}) {
    if (!_canInteract) return;
    if (direction != null) _prefetchDirection = direction.sign;
    _updateOriginalWindow();
    if (_viewportSize.isEmpty) return;
    final current = _item.members[_member];
    final previous = widget.snapshot.previousMediaIndex[_index];
    final next = widget.snapshot.nextMediaIndex[_index];
    _prefetchVideoCovers([previous, next]);
    final entries = <SourceEntry>[
      if (_item.isPhoto) current,
      for (final index
          in direction == null
              ? (_prefetchDirection > 0 ? [next, previous] : [previous, next])
              : [direction > 0 ? next : previous])
        if (index != null && widget.snapshot.items[index].isPhoto)
          widget.snapshot.items[index].preferred,
    ];
    final retainedPaths = {
      current.path,
      if (previous != null) widget.snapshot.items[previous].preferred.path,
      if (next != null) widget.snapshot.items[next].preferred.path,
    };
    for (final path in _prefetches.keys.toList(growable: false)) {
      if (retainedPaths.contains(path)) continue;
      final stale = _prefetches.remove(path)!;
      stale.handle.cancel();
      stale.decode?.cancel();
    }
    for (final entry in entries) {
      final existing = _prefetches[entry.path];
      if (existing != null) {
        existing.handle.updatePriority?.call(_prefetchPriority(entry));
        existing.decode?.refreshPriority();
        if (existing.result != null &&
            !existing.result!.encodedSource &&
            existing.edge < _imageEdge) {
          _prefetches.remove(entry.path);
          existing.handle.cancel();
          existing.decode?.cancel();
        } else {
          _decodePrefetch(entry, existing);
          continue;
        }
      }
      // At most the current in-flight photo and its two immediate neighbors.
      if (_prefetches.length >= 3) break;
      final prefetch = _ViewerPrefetch(
        _images.load(
          entry,
          targetEdge: _imageEdge,
          priority: _prefetchPriority(entry),
        ),
        _imageEdge,
      );
      _prefetches[entry.path] = prefetch;
      unawaited(
        prefetch.handle.future.then((result) {
          if (!_canInteract || !identical(_prefetches[entry.path], prefetch)) {
            return;
          }
          if (result.cancelled || result.deferred) {
            _prefetches.remove(entry.path);
            return;
          }
          prefetch.result = result;
          if (_dragOffset != 0) _pageUpdates.value++;
          // A DPR/viewport change must not abort an encoded source download.
          // Only a generated RAW/other-format preview may need a larger file.
          if (!result.encodedSource && prefetch.edge < _imageEdge) {
            _prefetchNeighbors();
          } else {
            _decodePrefetch(entry, prefetch);
          }
        }),
      );
    }
  }

  void _updateOriginalWindow() {
    // Protect a small neighborhood without reading or preloading the album.
    // Only the immediate neighbors below create source/decode requests; the
    // second neighbors allow a short reversal to reuse already cached files.
    final entries = <SourceEntry>[if (_item.isPhoto) _item.members[_member]];
    final forward = _prefetchDirection > 0
        ? widget.snapshot.nextMediaIndex
        : widget.snapshot.previousMediaIndex;
    final backward = _prefetchDirection > 0
        ? widget.snapshot.previousMediaIndex
        : widget.snapshot.nextMediaIndex;
    int? nextLeading = _index, nextTrailing = _index;
    for (var distance = 0; distance < 2; distance++) {
      nextLeading = nextLeading == null ? null : forward[nextLeading];
      nextTrailing = nextTrailing == null ? null : backward[nextTrailing];
      for (final index in [nextLeading, nextTrailing]) {
        if (index != null && widget.snapshot.items[index].isPhoto) {
          entries.add(widget.snapshot.items[index].preferred);
        }
      }
    }
    _images.setOriginalWindow(entries);
  }

  int _prefetchPriority(SourceEntry entry) {
    if (entry.path == _item.members[_member].path) return 0;
    final leading = _prefetchDirection > 0
        ? widget.snapshot.nextMediaIndex[_index]
        : widget.snapshot.previousMediaIndex[_index];
    return leading != null &&
            widget.snapshot.items[leading].preferred.path == entry.path
        ? 1
        : 2;
  }

  void _prefetchVideoCovers(List<int?> neighbors) {
    // Only read the two adjacent cache bindings; capture stays with visible,
    // idle thumbnails. A warm cover can then follow the finger immediately.
    if (_horizontalSwipe || _transition.isAnimating || _video.playing) return;
    final entries = <SourceEntry>[
      for (final index in neighbors)
        if (index != null && widget.snapshot.items[index].isVideo)
          widget.snapshot.items[index].preferred,
    ];
    final paths = {for (final entry in entries) entry.path};
    for (final path in _videoCoverReads.keys.toList(growable: false)) {
      if (paths.contains(path)) continue;
      _videoCoverReads.remove(path)?.cancel.cancel();
    }
    final owner = widget.model;
    final revision = owner.sourcePreviewRevision;
    for (final entry in entries) {
      if (_videoCoverReads[entry.path]?.revision == revision) continue;
      _videoCoverReads.remove(entry.path)?.cancel.cancel();
      final cancel = CancelToken();
      _videoCoverReads[entry.path] = (cancel: cancel, revision: revision);
      unawaited(() async {
        try {
          final binding = await owner.readSourceMediaPreview(
            widget.source['id'] as String,
            entry,
            cancel: cancel,
            albumCover: widget.albumMode,
            originalResolution: widget.albumMode,
          );
          if (cancel.cancelled ||
              !mounted ||
              owner != widget.model ||
              revision != owner.sourcePreviewRevision) {
            return;
          }
          final path = binding.thumbnail;
          if (path == null) {
            _videoCovers.remove(entry.path);
          } else {
            _videoCovers[entry.path] = path;
          }
          if (_dragOffset != 0) _pageUpdates.value++;
        } catch (_) {
          // Cache lookup is optional; the visible thumbnail owns retries.
        }
      }());
    }
  }

  void _decodePrefetch(SourceEntry entry, _ViewerPrefetch prefetch) {
    final path = prefetch.result?.path;
    // The visible thumbnail owns its decode. Neighbors share that exact
    // physical-size bucket when they become visible, including after rotation.
    if (path == null ||
        entry.path == _item.members[_member].path ||
        prefetch.decodeEdge == _imageEdge) {
      return;
    }
    prefetch.decode?.cancel();
    prefetch.decodeEdge = _imageEdge;
    prefetch.decode = ArtworkDecodeQueue.instance.request(
      artworkImage(File(path), _imageEdge),
      canStart: () =>
          _canInteract && identical(_prefetches[entry.path], prefetch),
      priority: () => _prefetchPriority(entry),
      onStart: () {},
      onError: (_, _) {},
    );
    if (prefetch.decode == null) prefetch.decodeEdge = null;
  }

  void _slidesChanged() {
    _setSlides(!_slides);
  }

  void _setSlides(bool enabled) {
    if (!_canInteract || !_item.isPhoto) return;
    _slideshow?.cancel();
    setState(() {
      _slides = enabled;
      _slideshowLandscape = null;
      _controlsVisible = !enabled;
    });
    _syncPresentation();
    if (_slides) _scheduleSlide();
  }

  void _syncPresentation() {
    final active = ArtworkLifecycle.instance.value && !_playing && !_leaving;
    unawaited(
      _systemUi.setPresentation(
        active: active,
        controlsVisible:
            _controlsVisible || _infoOpen || _slideshowSettingsOpen,
        fullscreen: _slides,
        landscape: _slides ? _slideshowLandscape : null,
      ),
    );
    _controlsTimer.configure(
      playing:
          active &&
          _canInteract &&
          (_slides || _video.playing && !_video.buffering) &&
          _controlsVisible,
      seconds: widget.model.preferences.controlsHideSeconds,
    );
  }

  void _setControlsVisible(bool visible) {
    if (!_canInteract) return;
    if (_controlsVisible != visible) {
      setState(() => _controlsVisible = visible);
    }
    _syncPresentation();
    if (visible) _controlsTimer.arm();
  }

  void _transformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (_zoomed == zoomed) return;
    setState(() => _zoomed = zoomed);
    if (zoomed && _dragOffset != 0) _cancelSwipe();
    _setControlsVisible(!zoomed);
  }

  void _toggleSlideshowOrientation() {
    if (!_canInteract || !_slides) return;
    setState(() {
      _slideshowLandscape =
          !(_slideshowLandscape ?? _viewportSize.width > _viewportSize.height);
    });
    _syncPresentation();
    _controlsTimer.arm();
  }

  void _scheduleSlide() {
    _slideshow?.cancel();
    if (!_slides || !_canInteract) {
      return;
    }
    _slideshow = Timer(
      Duration(seconds: widget.model.preferences.albumSlideshowSeconds),
      () {
        if (!mounted ||
            !_slides ||
            !ArtworkLifecycle.instance.value ||
            !_routeCurrent) {
          return;
        }
        final next = widget.snapshot.nextMediaIndex[_index];
        if (next == null || !widget.snapshot.items[next].isPhoto) {
          _setSlides(false);
          return;
        }
        _next(1);
        _scheduleSlide();
      },
    );
  }

  Future<void> _showSlideshowSettings() async {
    if (!_canInteract || !_slides || _slideshowSettingsOpen) return;
    final model = widget.model;
    _slideshowSettingsOpen = true;
    _slideshow?.cancel();
    _controlsTimer.hold();
    _syncPresentation();
    var exit = false;
    try {
      exit =
          await showGlassBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _AlbumSlideshowSettings(
              model: model,
              onSaved: () {
                if (mounted &&
                    identical(widget.model, model) &&
                    _slides &&
                    !_slideshowSettingsOpen) {
                  // Saving may finish after the user has dismissed the sheet.
                  // Apply the newly committed interval to the active session.
                  _scheduleSlide();
                }
              },
            ),
          ) ??
          false;
    } finally {
      _slideshowSettingsOpen = false;
      _controlsTimer.release();
      if (mounted) {
        // The sheet's future can finish before inherited route dependencies
        // rebuild. Read the live route before restoring this session's timer.
        _routeCurrent = _route?.isCurrent ?? true;
        _lifecycle();
        if (exit && _slides) {
          _setSlides(false);
        } else if (_slides) {
          _scheduleSlide();
        }
      }
    }
  }

  Future<void> _play({bool fullPlayer = false}) async {
    if (!_canInteract) return;
    if (_item.isVideo && !fullPlayer) {
      await _video.toggle();
      return;
    }
    final model = widget.model;
    final source = Map<String, dynamic>.unmodifiable(widget.source);
    final index = _index, itemId = _item.id;
    final entry = _item.preferred;
    final attempt = _opening = AlbumOpenAttempt(
      () =>
          mounted &&
          _routeCurrent &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          identical(widget.model, model) &&
          mapEquals(widget.source, source) &&
          _index == index &&
          _item.id == itemId &&
          _item.preferred.path == entry.path,
    );
    _slideshow?.cancel();
    _slides = false;
    _playing = true;
    _lifecycle();
    PlaybackSession? transferredSession;
    try {
      if (fullPlayer) {
        transferredSession = await _video.takeSession();
        await AlbumVideoController.waitForDisposals();
        attempt.check();
      }
      await _systemUi.setActive(false);
      attempt.check();
      if (!mounted) return;
      final transfer = transferredSession;
      transferredSession = null; // The route helper owns every cleanup path.
      await playAlbumMedia(
        context,
        model,
        source['id'] as String,
        entry,
        attempt: attempt,
        transferredSession: transfer,
        play: fullPlayer ? true : null,
      );
    } on Cancelled {
      // A lifecycle change while releasing immersive UI ends this tap.
    } catch (error) {
      if (mounted && !attempt.token.cancelled && attempt.isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(safeFailure(error, action: '打开媒体失败').message)),
        );
      }
    } finally {
      await transferredSession?.close();
      attempt.dispose();
      if (identical(_opening, attempt)) {
        _opening = null;
        _playing = false;
        if (mounted) {
          _routeCurrent = _route?.isCurrent ?? true;
          _lifecycle();
          setState(() {});
        }
      }
    }
  }

  void _back() {
    if (_leaving) return;
    _opening?.cancel();
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      setState(() => _transform.value = Matrix4.identity());
    } else {
      unawaited(_leave());
    }
  }

  Future<void> _leave() async {
    _leaving = true;
    _lifecycle();
    final restore = _viewportRestore;
    if (restore == null) {
      await _systemUi.setActive(false);
    } else {
      await restore.restore(() => _systemUi.setActive(false));
    }
    if (mounted) Navigator.pop(context, _index);
  }

  bool get _canInteract =>
      mounted &&
      !_playing &&
      !_leaving &&
      (_route?.isCurrent ?? true) &&
      ArtworkLifecycle.instance.value;

  void _clearSwipe({bool synchronizeArtwork = true}) {
    _swipeAllowed = false;
    _swipePointer = null;
    _swipeStart = _swipeLast = null;
    _swipeVelocity = null;
    _horizontalSwipe = false;
    _dragOffset = 0;
    _settleOffset = null;
    _pointers.clear();
    if (synchronizeArtwork) _syncVideoArtwork();
  }

  void _cancelSwipe() {
    final offset = _dragOffset;
    _clearSwipe(synchronizeArtwork: false);
    if (offset != 0 && mounted) _settleSwipe(offset);
    _syncVideoArtwork();
    if (_slides) _scheduleSlide();
  }

  void _settleSwipe(double offset) {
    setState(() {
      _settleOffset = offset;
      _dragOffset = 0;
      _previous = null;
      _transitionKind = 0;
    });
    if (_motionEnabled) {
      _transition.forward(from: 0);
    } else {
      _settleOffset = null;
      _transition.value = 1;
    }
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _swipeAllowed = false;
      if (_dragOffset != 0) _settleSwipe(_dragOffset);
      return;
    }
    // Finish the previous snap before a new gesture takes ownership. The
    // resident thumbnail keeps its element throughout every drag and snap.
    if (_transition.isAnimating) {
      _transition.stop();
      setState(() {
        _transition.value = 1;
        _previous = null;
        _settleOffset = null;
      });
    }
    _swipePointer = event.pointer;
    _swipeStart = _swipeLast = event.localPosition;
    _swipeVelocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    _horizontalSwipe = false;
    _swipeAllowed =
        _canInteract &&
        (_item.isPhoto || _item.isVideo) &&
        _transform.value.getMaxScaleOnAxis() <= 1.01;
    if (_swipeAllowed) _slideshow?.cancel();
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer == _swipePointer) {
      _swipeLast = event.localPosition;
      _swipeVelocity?.addPosition(event.timeStamp, event.localPosition);
      final start = _swipeStart;
      if (_swipeAllowed && start != null) {
        final delta = event.localPosition - start;
        if (!_horizontalSwipe &&
            delta.dx.abs() > 12 &&
            delta.dx.abs() > delta.dy.abs() * 1.4) {
          _horizontalSwipe = true;
          _syncVideoArtwork();
          if (_item.isVideo) unawaited(_video.setPlaying(false));
          _prefetchNeighbors(direction: delta.dx < 0 ? 1 : -1);
        }
        if (_horizontalSwipe) {
          final direction = delta.dx < 0 ? 1 : -1;
          if (delta.dx.abs() > 12 && direction != _prefetchDirection) {
            _prefetchNeighbors(direction: direction);
          }
          final neighbor = delta.dx < 0
              ? widget.snapshot.nextMediaIndex[_index]
              : widget.snapshot.previousMediaIndex[_index];
          final span = _viewportSize.width + _pageGap;
          final offset = neighbor == null
              ? delta.dx * .22
              : delta.dx.clamp(-span, span);
          if (_dragOffset != offset) {
            _dragOffset = offset;
            _pageUpdates.value++;
          }
        }
      }
    }
    if (_transform.value.getMaxScaleOnAxis() > 1.01) _swipeAllowed = false;
  }

  void _pointerUp(PointerUpEvent event) {
    final start = _swipeStart, end = _swipeLast;
    final swiped =
        _swipeAllowed &&
        _pointers.length == 1 &&
        event.pointer == _swipePointer &&
        _transform.value.getMaxScaleOnAxis() <= 1.01 &&
        start != null &&
        end != null;
    _pointers.remove(event.pointer);
    if (!swiped) {
      if (_pointers.isEmpty && _slides) _scheduleSlide();
      return;
    }
    _swipeAllowed = false;
    _horizontalSwipe = false;
    // Keep the completed direction before clearing gesture ownership.
    final horizontal = _dragOffset != 0;
    final delta = end - start;
    final velocity = _swipeVelocity?.getVelocity().pixelsPerSecond.dx ?? 0;
    if (horizontal) {
      final direction = delta.dx < 0 ? 1 : -1;
      final neighbor = direction > 0
          ? widget.snapshot.nextMediaIndex[_index]
          : widget.snapshot.previousMediaIndex[_index];
      final advance =
          delta.dx.abs() >= _viewportSize.width * .22 ||
          (delta.dx.abs() >= 32 &&
              velocity.abs() >= 650 &&
              velocity.sign == delta.dx.sign);
      if (advance && neighbor != null) {
        _next(direction, dragOffset: _dragOffset);
        if (_slides) _scheduleSlide();
      } else {
        _settleSwipe(_dragOffset);
      }
    } else if (delta.dy.abs() >= 64 && delta.dy.abs() > delta.dx.abs() * 1.4) {
      _setControlsVisible(delta.dy > 0);
    }
    if (_slides) _scheduleSlide();
    _syncVideoArtwork();
  }

  void _doubleTap() {
    if (!_canInteract || !(_item.isPhoto || _item.isVideo)) return;
    final point = _doubleTapPosition ?? Offset.zero;
    _transform.value = _transform.value.getMaxScaleOnAxis() > 1.01
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-point.dx, -point.dy, 0, 1)
            ..scaleByDouble(2, 2, 1, 1));
  }

  void _zoom(double factor) {
    if (!(_item.isPhoto || _item.isVideo)) return;
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(1.0, 8.0);
    setState(() {
      final center = _viewportSize.center(Offset.zero);
      final ratio = next / current;
      _transform.value = next <= 1.01
          ? Matrix4.identity()
          : (Matrix4.identity()
              ..translateByDouble(center.dx, center.dy, 0, 1)
              ..scaleByDouble(ratio, ratio, 1, 1)
              ..translateByDouble(-center.dx, -center.dy, 0, 1)
              ..multiply(_transform.value));
    });
  }

  void _centerImage(double scale) {
    final center = _viewportSize.center(Offset.zero);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        center.dx * (1 - scale),
        center.dy * (1 - scale),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _rotate() {
    setState(() {
      _rotation = (_rotation + 1) % 4;
      _centerImage(_transform.value.getMaxScaleOnAxis());
    });
  }

  void _activateViewer() {
    if (_item.isPhoto) {
      if (!_controlsVisible) {
        _setControlsVisible(true);
      } else {
        _viewerFocus.focusInDirection(TraversalDirection.up);
      }
    } else {
      unawaited(_play());
    }
  }

  RemoteCommandResult? _remote(RemoteCommand command) {
    if (!command.isCurrent ||
        !mounted ||
        !_routeCurrent ||
        !ArtworkLifecycle.instance.value) {
      return RemoteCommandResult.unavailable;
    }
    switch (command.action) {
      case 'previous':
        _next(-1);
      case 'next':
        _next(1);
      case 'zoomIn':
        _zoom(2);
      case 'zoomOut':
        _zoom(.5);
      case 'rotate':
        if (!_item.isPhoto) return RemoteCommandResult.unavailable;
        _rotate();
      case 'toggle' || 'play' || 'pause':
        if (_item.isVideo) {
          unawaited(
            command.action == 'toggle'
                ? _video.toggle()
                : _video.setPlaying(command.action == 'play'),
          );
          break;
        }
        if (!_item.isPhoto) return null;
        if (command.action == 'toggle' ||
            command.action == 'play' && !_slides ||
            command.action == 'pause' && _slides) {
          _slidesChanged();
        }
      case 'back':
        _back();
      case 'select':
        if (FocusManager.instance.primaryFocus != _viewerFocus) return null;
        _activateViewer();
      case 'up' || 'down' || 'left' || 'right':
        if (!_viewerFocus.hasFocus) return null;
        final key = switch (command.action) {
          'up' => LogicalKeyboardKey.arrowUp,
          'down' => LogicalKeyboardKey.arrowDown,
          'left' => LogicalKeyboardKey.arrowLeft,
          _ => LogicalKeyboardKey.arrowRight,
        };
        if (_direction(key) == KeyEventResult.ignored) return null;
      default:
        return null;
    }
    return const RemoteCommandResult(true);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    return _direction(event.logicalKey);
  }

  KeyEventResult _direction(LogicalKeyboardKey key) {
    if (!_canInteract) return KeyEventResult.ignored;
    if (_item.isVideo &&
        (key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.mediaPlayPause)) {
      unawaited(_play());
      return KeyEventResult.handled;
    }
    if (_item.isVideo &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      final focus = key == LogicalKeyboardKey.arrowUp
          ? _infoFocus
          : _videoControlsFocus;
      if (_controlsVisible) {
        focus.requestFocus();
      } else {
        final item = _item;
        _setControlsVisible(true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_canInteract && identical(item, _item)) {
            focus.requestFocus();
          }
        });
      }
      return KeyEventResult.handled;
    }
    if (_item.isPhoto &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _zoom(key == LogicalKeyboardKey.arrowUp ? 2 : .5);
      return KeyEventResult.handled;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => const Offset(80, 0),
      LogicalKeyboardKey.arrowRight => const Offset(-80, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, 80),
      LogicalKeyboardKey.arrowDown => const Offset(0, -80),
      _ => Offset.zero,
    };
    if (direction == Offset.zero) return KeyEventResult.ignored;
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = _transform.value.clone()
        ..translateByDouble(direction.dx, direction.dy, 0, 1);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _next(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    unawaited(_systemUi.setActive(false));
    _opening?.dispose();
    _infoRequest?.cancel();
    _infoRequest = null;
    _slideshow?.cancel();
    _controlsTimer.dispose();
    _video.removeListener(_videoChanged);
    _video.dispose();
    _videoArtworkActive.dispose();
    ArtworkLifecycle.instance.removeListener(_lifecycle);
    widget.model.removeListener(_imagePreferencesChanged);
    _cancelPrefetches();
    _images.dispose();
    _viewportRestore?.dispose();
    _transition.dispose();
    _pageUpdates.dispose();
    _transform.removeListener(_transformChanged);
    _transform.dispose();
    _viewerFocus.dispose();
    _infoFocus.dispose();
    _videoControlsFocus.dispose();
    super.dispose();
  }

  void _loadInfoMetadata() {
    final entry = _infoEntry, info = _infoResult;
    if (!mounted ||
        !_infoOpen ||
        info == null ||
        entry == null ||
        _infoRequest != null ||
        _infoReadComplete ||
        info.value?.exif.isNotEmpty == true ||
        !ArtworkLifecycle.instance.value ||
        !_images.active) {
      return;
    }
    final revision = _lifecycleRevision;
    final request = _infoRequest = _images.loadMetadata(entry);
    unawaited(
      Future<AlbumImageResult>.value(request.future).then((result) {
        if (!identical(_infoRequest, request)) return;
        _infoRequest = null;
        if (!mounted ||
            !identical(_infoResult, info) ||
            !_infoOpen ||
            revision != _lifecycleRevision ||
            result.deferred ||
            result.cancelled ||
            result.error != null) {
          return;
        }
        _infoReadComplete = true;
        info.value = result;
      }),
    );
  }

  Future<void> _showInfo(SourceEntry entry) async {
    if (!_canInteract || _infoOpen) return;
    if (!_item.isPhoto) {
      _infoOpen = true;
      _controlsTimer.hold();
      _lifecycle();
      try {
        await showMediaFileDetails(
          context,
          model: widget.model,
          sourceId: widget.source['id'] as String,
          entry: entry,
          sourceName: '${widget.source['label'] ?? ''}',
        );
      } finally {
        _infoOpen = false;
        _controlsTimer.release();
        if (mounted) {
          _routeCurrent = _route?.isCurrent ?? true;
          _lifecycle();
        }
      }
      return;
    }
    final info = ValueNotifier<AlbumImageResult?>(_imageResult);
    _infoOpen = true;
    _controlsTimer.hold();
    _syncPresentation();
    _infoReadComplete = false;
    _infoEntry = entry;
    _infoResult = info;
    _loadInfoMetadata();
    try {
      await showGlassBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ValueListenableBuilder<AlbumImageResult?>(
          valueListenable: info,
          builder: (_, result, _) => AlbumPhotoInfoSheet(
            entry: entry,
            source: widget.source,
            result: result,
          ),
        ),
      );
    } finally {
      _infoOpen = false;
      _infoEntry = null;
      _infoResult = null;
      _infoRequest?.cancel();
      _infoRequest = null;
      info.dispose();
      _controlsTimer.release();
      if (mounted) _lifecycle();
    }
  }

  void _selectMember(int index) {
    if (!_canInteract || index < 0 || index >= _item.members.length) return;
    setState(() {
      _member = index;
      _rotation = 0;
      _imageResult = null;
      _transform.value = Matrix4.identity();
    });
    _prefetchNeighbors();
  }

  Future<void> _showFormats() async {
    if (!_canInteract) return;
    final item = _item, revision = _lifecycleRevision, selected = _member;
    _controlsTimer.hold();
    final choice = await showGlassBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.sizeOf(sheetContext).width, 560),
            maxHeight: math.min(
              MediaQuery.sizeOf(sheetContext).height * .72,
              480,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择格式',
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭格式选择',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  key: const ValueKey('album-formats-list'),
                  itemCount: item.members.length,
                  itemBuilder: (_, index) => ListTile(
                    key: ValueKey('album-format:$index'),
                    dense: true,
                    minTileHeight: GlassMetrics.menuItemHeight,
                    contentPadding: GlassMetrics.menuItemPadding,
                    selected: index == selected,
                    leading: index == selected
                        ? const Icon(Icons.check_rounded, size: 20)
                        : const SizedBox(width: 20, height: 20),
                    title: Text(
                      item.members[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(sheetContext, index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _controlsTimer.release();
    if (!mounted ||
        choice == null ||
        revision != _lifecycleRevision ||
        !identical(item, _item)) {
      return;
    }
    _selectMember(choice);
  }

  Widget _preparedPhoto(AlbumImageResult? result, int rotation, int edge) {
    Widget image = MediaArtwork(
      thumbnail: result?.path,
      fit: BoxFit.contain,
      maxDecodeEdge: edge,
      loadWhileScrolling: true,
      placeholder: Icon(
        Icons.image_outlined,
        color: _whiteCanvas ? Colors.black38 : Colors.white54,
        size: 48,
      ),
    );
    if (rotation != 0) image = RotatedBox(quarterTurns: rotation, child: image);
    return Center(child: image);
  }

  Widget _videoCover(SourceEntry entry, int edge, {bool active = false}) =>
      ColoredBox(
        color: _whiteCanvas ? Colors.white : Colors.black,
        child: AlbumVideoThumbnail(
          key: ValueKey('album-video-cover:${entry.path}'),
          model: widget.model,
          sourceId: widget.source['id'] as String,
          entry: entry,
          edge: edge,
          firstFrame: widget.albumMode,
          originalResolution: widget.albumMode,
          fit: BoxFit.contain,
          active: active,
          activity: _videoArtworkActive,
          initialThumbnail: _videoCovers[entry.path],
          onThumbnailChanged: (path) {
            if (path == null) {
              _videoCovers.remove(entry.path);
            } else {
              _videoCovers[entry.path] = path;
            }
          },
          placeholder: Center(
            child: Icon(
              Icons.videocam_outlined,
              color: _whiteCanvas ? Colors.black38 : Colors.white38,
              size: 48,
            ),
          ),
        ),
      );

  Widget _animatedPhoto(SourceEntry entry, int edge) {
    final current = _item.isVideo
        ? Stack(
            key: ValueKey('album-video:${entry.path}'),
            fit: StackFit.expand,
            children: [
              AlbumVideoSurface(
                controller: _video,
                backgroundColor: _whiteCanvas ? Colors.white : Colors.black,
                cover: _videoCover(entry, edge, active: true),
              ),
            ],
          )
        : Center(
            child: RotatedBox(
              quarterTurns: _rotation,
              child: AlbumThumbnail(
                key: ValueKey(entry.path),
                service: _images,
                entry: entry,
                edge: edge,
                fit: BoxFit.contain,
                showLoading: !_infoOpen,
                loadingPlaceholder: _imageResult?.path == null
                    ? null
                    : _preparedPhoto(_imageResult, 0, edge),
                initialResult: _imageResult,
                onLoaded: (result) {
                  if (mounted &&
                      _item.members[_member].path == entry.path &&
                      result.sourcePath == entry.path) {
                    setState(() => _imageResult = result);
                    _prefetchNeighbors();
                  }
                },
                // Keep the wall/neighbor's warm image visible while the full-screen
                // request prepares its larger version in the background worker.
                placeholder: _preparedPhoto(_imageResult, 0, edge),
              ),
            ),
          );
    final previous = _previous;
    final outgoing = previous == null
        ? null
        : previous.video != null
        ? _videoCover(previous.video!, edge)
        : _preparedPhoto(previous.result, previous.rotation, edge);
    return AnimatedBuilder(
      key: const ValueKey('album-photo-transition'),
      animation: _transition,
      child: current,
      builder: (_, child) => ListenableBuilder(
        listenable: _pageUpdates,
        child: child,
        builder: (_, child) {
          final progress = Curves.easeOutCubic.transform(_transition.value);
          final span = _viewportSize.width + _pageGap;
          final physicalPaging = _transitionKind == 0;
          final settlingBack = _previous == null && _settleOffset != null;
          final currentOffset = _dragOffset != 0
              ? _dragOffset
              : settlingBack
              ? _settleOffset! * (1 - progress)
              : _previous != null && physicalPaging
              ? ((_settleOffset ?? 0) + span * _slideDirection) * (1 - progress)
              : 0.0;
          Widget frame(Widget photo, bool incoming, {double? offset}) {
            final distance = incoming ? 1 - progress : -progress;
            final translation = offset != null
                ? Offset(offset / _viewportSize.width, 0)
                : _transitionKind == 2
                ? Offset(0, distance * .18)
                : _transitionKind == 5
                ? Offset(0, distance * _slideDirection)
                : Offset.zero;
            final fade =
                offset == null && _transitionKind >= 1 && _transitionKind <= 4;
            final matrix = Matrix4.identity();
            if (offset == null && _transitionKind == 3) {
              matrix.scaleByDouble(
                1 + distance * .12,
                1 + distance * .12,
                1,
                1,
              );
            } else if (offset == null && _transitionKind == 4) {
              matrix.rotateZ(distance * .06);
              final scale = 1 + distance.abs() * .08;
              matrix.scaleByDouble(scale, scale, 1, 1);
            }
            // Keep this hierarchy and the current page's key stable when a
            // neighbor/outgoing frame is inserted. Replacing it drops the live
            // Image and briefly exposes a placeholder even after preloading.
            return FractionalTranslation(
              key: ValueKey(
                incoming ? 'album-current-page' : 'album-other-page',
              ),
              translation: translation,
              child: Transform(
                alignment: Alignment.center,
                transform: matrix,
                child: Opacity(
                  opacity: fade ? (incoming ? progress : 1 - progress) : 1,
                  child: photo,
                ),
              ),
            );
          }

          final dragging = _dragOffset != 0 || settlingBack && progress < 1;
          final direction = currentOffset < 0 ? 1 : -1;
          final neighbor = direction > 0
              ? widget.snapshot.nextMediaIndex[_index]
              : widget.snapshot.previousMediaIndex[_index];
          Widget? adjacent;
          if (dragging && neighbor != null) {
            final item = widget.snapshot.items[neighbor];
            adjacent = item.isPhoto
                ? _preparedPhoto(
                    _prefetches[item.preferred.path]?.result ??
                        _images.peek(item.preferred),
                    0,
                    edge,
                  )
                : item.isVideo
                ? _videoCover(item.preferred, edge)
                : Center(
                    child: Icon(
                      item.isAudio ? Icons.music_note : Icons.play_arrow,
                      size: 60,
                      color: _whiteCanvas ? Colors.black54 : Colors.white70,
                    ),
                  );
          }

          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (outgoing != null && progress < 1)
                  frame(
                    outgoing,
                    false,
                    offset: physicalPaging
                        ? (_settleOffset ?? 0) * (1 - progress) -
                              span * _slideDirection * progress
                        : null,
                  ),
                if (adjacent != null)
                  frame(
                    adjacent,
                    false,
                    offset: currentOffset + span * direction,
                  ),
                frame(
                  child!,
                  true,
                  offset: physicalPaging || dragging ? currentOffset : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar(SourceEntry entry) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x99000000), Color(0x00000000)],
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Row(
            children: [
              BackButton(color: Colors.white, onPressed: _back),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              if (_item.members.length > 24)
                IconButton(
                  tooltip: '选择格式',
                  icon: const Icon(Icons.layers_outlined, color: Colors.white),
                  onPressed: _showFormats,
                )
              else if (_item.members.length > 1)
                PopupMenuButton<int>(
                  tooltip: '选择格式',
                  onOpened: _controlsTimer.hold,
                  onCanceled: _controlsTimer.release,
                  icon: const Icon(Icons.layers_outlined, color: Colors.white),
                  onSelected: (index) {
                    _controlsTimer.release();
                    _selectMember(index);
                  },
                  itemBuilder: (_) => [
                    for (var i = 0; i < _item.members.length; i++)
                      CheckedPopupMenuItem(
                        height: GlassMetrics.menuItemHeight,
                        padding: GlassMetrics.menuItemPadding,
                        value: i,
                        checked: i == _member,
                        child: Text(_item.members[i].name),
                      ),
                  ],
                ),
              IconButton(
                focusNode: _infoFocus,
                tooltip: _item.isPhoto
                    ? '照片信息'
                    : _item.isVideo
                    ? '视频信息'
                    : '音频信息',
                color: Colors.white,
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showInfo(entry),
              ),
              if (_item.isVideo)
                IconButton(
                  key: const ValueKey('album-open-full-player'),
                  tooltip: '使用完整播放器',
                  color: Colors.white,
                  visualDensity: VisualDensity.compact,
                  onPressed: _playing ? null : () => _play(fullPlayer: true),
                  icon: const Icon(Icons.open_in_new_rounded, size: 21),
                ),
              if (_slides && _mobile)
                IconButton(
                  key: const ValueKey('album-slideshow-orientation'),
                  color: Colors.white,
                  tooltip:
                      (_slideshowLandscape ??
                          _viewportSize.width > _viewportSize.height)
                      ? '切换竖屏'
                      : '切换横屏',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  onPressed: _toggleSlideshowOrientation,
                  icon: Icon(
                    (_slideshowLandscape ??
                            _viewportSize.width > _viewportSize.height)
                        ? Icons.stay_current_portrait_rounded
                        : Icons.stay_current_landscape_rounded,
                    size: 20,
                  ),
                ),
              if (_slides)
                IconButton(
                  key: const ValueKey('album-slideshow-settings'),
                  color: Colors.white,
                  tooltip: '幻灯片',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  onPressed: _showSlideshowSettings,
                  icon: const Icon(Icons.slideshow_rounded, size: 22),
                ),
              if (_item.isPhoto)
                PopupMenuButton<String>(
                  tooltip: '更多选项',
                  onOpened: _controlsTimer.hold,
                  onCanceled: _controlsTimer.release,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: Colors.white,
                  ),
                  onSelected: (action) {
                    _controlsTimer.release();
                    if (action == 'startSlides') _setSlides(true);
                    if (action == 'stopSlides') _setSlides(false);
                    if (action == 'rotate') {
                      _rotate();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      height: GlassMetrics.menuItemHeight,
                      padding: GlassMetrics.menuItemPadding,
                      value: _slides ? 'stopSlides' : 'startSlides',
                      child: Text(_slides ? '停止幻灯片' : '开始幻灯片'),
                    ),
                    const PopupMenuItem(
                      height: GlassMetrics.menuItemHeight,
                      padding: GlassMetrics.menuItemPadding,
                      value: 'rotate',
                      child: Text('旋转'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final entry = item.members[_member.clamp(0, item.members.length - 1)];
    final edge = _imageEdge;
    return GlassMenuTheme(
      child: RemoteControlTarget(
        onCommand: _remote,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarIconBrightness: _whiteCanvas
                  ? Brightness.dark
                  : Brightness.light,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
              systemStatusBarContrastEnforced: false,
            ),
            child: Scaffold(
              backgroundColor: _whiteCanvas ? Colors.white : Colors.black,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Actions(
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (_) {
                            _activateViewer();
                            return null;
                          },
                        ),
                      },
                      child: Focus(
                        focusNode: _viewerFocus,
                        autofocus: true,
                        onKeyEvent: _key,
                        child: item.isPhoto || item.isVideo
                            ? Listener(
                                onPointerDown: _pointerDown,
                                onPointerMove: _pointerMove,
                                onPointerUp: _pointerUp,
                                onPointerCancel: (_) => _cancelSwipe(),
                                child: GestureDetector(
                                  key: const ValueKey('album-photo-canvas'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_canInteract) {
                                      if (!item.isVideo || widget.albumMode) {
                                        setState(
                                          () => _whiteCanvas = !_whiteCanvas,
                                        );
                                      }
                                      if (item.isVideo) {
                                        _setControlsVisible(!_controlsVisible);
                                      }
                                    }
                                  },
                                  onDoubleTapDown: (details) =>
                                      _doubleTapPosition =
                                          details.localPosition,
                                  onDoubleTap: _doubleTap,
                                  child: InteractiveViewer(
                                    transformationController: _transform,
                                    minScale: 1,
                                    maxScale: 8,
                                    child: _animatedPhoto(entry, edge),
                                  ),
                                ),
                              )
                            : Center(
                                child: IconButton.filled(
                                  tooltip: '播放',
                                  onPressed: _playing ? null : _play,
                                  iconSize: 60,
                                  icon: Icon(
                                    item.isAudio
                                        ? Icons.music_note
                                        : Icons.play_arrow,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (item.isVideo && (_controlsVisible || _zoomed))
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0xBB000000)],
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          minimum: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                          child: AlbumVideoControls(
                            controller: _video,
                            playPauseFocusNode: _videoControlsFocus,
                            onInteractionStart: _controlsTimer.hold,
                            onInteractionEnd: _controlsTimer.release,
                          ),
                        ),
                      ),
                    ),
                  if (_controlsVisible)
                    Align(
                      key: const ValueKey('album-viewer-toolbar'),
                      alignment: Alignment.topCenter,
                      child: _toolbar(entry),
                    ),
                  SafeArea(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_imageResult?.error != null ||
                            _imageResult?.previewOnly == true)
                          Positioned(
                            bottom: 16,
                            left: 24,
                            right: 24,
                            child: IgnorePointer(
                              child: Text(
                                _imageResult?.error ?? 'RAW 内嵌预览',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _whiteCanvas
                                      ? Colors.black54
                                      : Colors.white70,
                                ),
                              ),
                            ),
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
    );
  }
}

class _ViewerPrefetch {
  final AlbumImageHandle handle;
  final int edge;
  int? decodeEdge;
  AlbumImageResult? result;
  ArtworkDecodeRequest? decode;
  _ViewerPrefetch(this.handle, this.edge);
}

class _AlbumSlideshowSettings extends StatefulWidget {
  final AppModel model;
  final VoidCallback onSaved;
  const _AlbumSlideshowSettings({required this.model, required this.onSaved});

  @override
  State<_AlbumSlideshowSettings> createState() =>
      _AlbumSlideshowSettingsState();
}

class _AlbumSlideshowSettingsState extends State<_AlbumSlideshowSettings> {
  bool _saving = false;
  String? _error;

  Future<void> _save(Map<String, dynamic> patch) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.model.updatePreferences(patch);
      widget.onSaved();
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.model.preferences;
    final seconds = preferences.albumSlideshowSeconds;
    final intervals = <int>{2, 3, 5, 10, 15, 30, 60, seconds}.toList()..sort();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '幻灯片设置',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭幻灯片设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      dense: true,
                      minTileHeight: GlassMetrics.menuItemHeight,
                      title: const Text('切换间隔'),
                      trailing: DropdownButton<int>(
                        key: const ValueKey('album-slideshow-interval'),
                        value: seconds,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final value in intervals)
                            DropdownMenuItem(
                              value: value,
                              child: Text('$value 秒'),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) {
                                if (value != null) {
                                  unawaited(
                                    _save({'albumSlideshowSeconds': value}),
                                  );
                                }
                              },
                      ),
                    ),
                    ListTile(
                      dense: true,
                      minTileHeight: GlassMetrics.menuItemHeight,
                      title: const Text('转场效果'),
                      trailing: DropdownButton<String>(
                        key: const ValueKey('album-slideshow-transition'),
                        value: preferences.albumSlideshowTransition,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'random', child: Text('随机')),
                          DropdownMenuItem(value: 'slide', child: Text('推拉')),
                          DropdownMenuItem(value: 'fade', child: Text('淡入淡出')),
                          DropdownMenuItem(value: 'none', child: Text('无')),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) {
                                if (value != null) {
                                  unawaited(
                                    _save({'albumSlideshowTransition': value}),
                                  );
                                }
                              },
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ListTile(
                      key: const ValueKey('album-slideshow-exit'),
                      dense: true,
                      minTileHeight: GlassMetrics.menuItemHeight,
                      leading: const Icon(Icons.stop_circle_outlined, size: 22),
                      title: const Text('退出幻灯片模式'),
                      onTap: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays already prepared source facts and EXIF. Thumbnail dimensions never
/// stand in for an original image's dimensions, including RAW previews.
class AlbumPhotoInfoSheet extends StatelessWidget {
  final SourceEntry entry;
  final Map<String, dynamic> source;
  final AlbumImageResult? result;
  const AlbumPhotoInfoSheet({
    super.key,
    required this.entry,
    required this.source,
    this.result,
  });

  String _date(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(milliseconds)
          .toLocal()
          .toIso8601String()
          .split('.')
          .first
          .replaceFirst('T', ' ');

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _safeLocation(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return value;
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';
  }

  @override
  Widget build(BuildContext context) {
    final width = result?.sourceWidth, height = result?.sourceHeight;
    final extension = mediaExtension(entry.name);
    final sourceName = (source['label'] as String?)?.trim();
    final sourceKind = switch (source['kind']) {
      'local' => '本地',
      'smb' => 'SMB',
      'webdav' => 'WebDAV',
      'http' => 'HTTP',
      _ => '',
    };
    final captured = result?.capturedAt;
    final captureRaw = result?.captureTimeRaw?.trim();
    final facts = <String, String>{
      '文件名': entry.name,
      if (extension.isNotEmpty) '类型': extension.substring(1).toUpperCase(),
      if (width != null && width > 0 && height != null && height > 0)
        '尺寸': '$width × $height',
      if (entry.size > 0) '大小': _size(entry.size),
      if (captured != null)
        '拍摄时间': captureRaw != null && captureRaw.isNotEmpty
            ? captureRaw
            : _date(captured),
      if (entry.modified > 0) '修改时间': _date(entry.modified),
    };
    final exif = result?.exif ?? const <String, String>{};
    const cameraOrder = [
      '相机',
      '相机型号',
      '相机厂商',
      '镜头',
      '镜头型号',
      '光圈',
      '曝光时间',
      'ISO',
      '焦距',
      '35mm 等效焦距',
      '曝光补偿',
      '白平衡',
    ];
    final camera = <String, String>{
      for (final label in cameraOrder)
        if (exif[label]?.trim().isNotEmpty == true)
          label: formatCameraParameter(label, exif[label]!),
    };
    final omitted = {...facts.keys, ...camera.keys};
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
          maxWidth: 640,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '照片信息',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭照片信息',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: MediaFileParameterList(
                sections: [
                  MediaParameterSection(values: facts),
                  MediaParameterSection(title: '拍摄参数', values: camera),
                ],
                moreSections: [
                  MediaParameterSection(values: exif, omit: omitted),
                  MediaParameterSection(
                    values: {
                      if (sourceName != null && sourceName.isNotEmpty)
                        '来源': _safeLocation(sourceName)
                      else if (sourceKind.isNotEmpty)
                        '来源': sourceKind,
                      if (entry.path.isNotEmpty)
                        '位置': _safeLocation(entry.path),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Coalesces route/lifecycle changes, including when no further frame is drawn.
/// Every await checks the latest desired mode before applying another change.
class _ViewerSystemUi {
  var _desired = (
    active: false,
    controlsVisible: true,
    fullscreen: false,
    landscape: null as bool?,
  );
  var _applied = (
    active: false,
    controlsVisible: true,
    fullscreen: false,
    landscape: null as bool?,
  );
  Future<void>? _pending;
  bool _ownsDesktopFullscreen = false;

  Future<void> setActive(bool active) => setPresentation(
    active: active,
    controlsVisible: _desired.controlsVisible,
    fullscreen: _desired.fullscreen,
    landscape: active ? _desired.landscape : null,
  );

  Future<void> setPresentation({
    required bool active,
    required bool controlsVisible,
    required bool fullscreen,
    required bool? landscape,
  }) {
    if (kIsWeb) return Future.value();
    _desired = (
      active: active,
      controlsVisible: controlsVisible,
      fullscreen: fullscreen,
      landscape: active && fullscreen ? landscape : null,
    );
    return _pending ??= _update().whenComplete(() async {
      _pending = null;
      if (_desired != _applied) {
        await setPresentation(
          active: _desired.active,
          controlsVisible: _desired.controlsVisible,
          fullscreen: _desired.fullscreen,
          landscape: _desired.landscape,
        );
      }
    });
  }

  Future<void> _update() async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    while (_desired != _applied) {
      final requested = _desired;
      bool current() => _desired == requested;
      try {
        if (mobile) {
          // The system handles free rotation; the slideshow's explicit toggle
          // temporarily locks only the requested axis, without a sensor stream.
          if (requested.active != _applied.active ||
              requested.landscape != _applied.landscape) {
            await SystemChrome.setPreferredOrientations(
              !requested.active || requested.landscape == null
                  ? []
                  : requested.landscape!
                  ? [
                      DeviceOrientation.landscapeLeft,
                      DeviceOrientation.landscapeRight,
                    ]
                  : [
                      DeviceOrientation.portraitUp,
                      DeviceOrientation.portraitDown,
                    ],
            );
          }
          if (current()) {
            if (requested.active && !requested.controlsVisible) {
              await SystemChrome.setEnabledSystemUIMode(
                SystemUiMode.immersiveSticky,
              );
              if (current()) await PlayerDisplay.setImmersive(true);
            } else {
              await SystemChrome.setEnabledSystemUIMode(
                SystemUiMode.manual,
                overlays: SystemUiOverlay.values,
              );
              if (current()) {
                await SystemChrome.setEnabledSystemUIMode(
                  SystemUiMode.edgeToEdge,
                );
              }
              if (current()) await PlayerDisplay.setImmersive(false);
            }
          }
        } else {
          final enter = requested.active && requested.fullscreen;
          if (enter &&
              !_ownsDesktopFullscreen &&
              !DesktopWindow.state.value.fullscreen) {
            _ownsDesktopFullscreen = await DesktopWindow.setFullscreen(true);
          } else if (!enter && _ownsDesktopFullscreen) {
            await DesktopWindow.setFullscreen(false);
            _ownsDesktopFullscreen = false;
          }
        }
      } catch (_) {
        // Optional window presentation must not prevent browsing or returning.
      }
      _applied = requested;
    }
  }
}
