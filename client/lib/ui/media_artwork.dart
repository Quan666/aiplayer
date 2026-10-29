import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/logger.dart';
import '../data/poster_cache.dart';
import 'artwork_decode_queue.dart';
import 'artwork_lifecycle.dart';
import 'artwork_scroll_scope.dart';
import 'glass.dart';
import 'theme/library_styles.dart';

// One cheap layout generation for all covers. Priority checks in the download
// and decode queues reuse geometry within a frame, including zero-time test
// frames; no per-card frame callbacks or timers are installed.
int _artworkLayoutGeneration = 0;
bool _tracksArtworkLayout = false;

/// Decode artwork to its displayed size, with a bounded physical pixel budget.
class MediaArtwork extends StatefulWidget {
  final String poster;
  final String? thumbnail;
  final PosterCache? cache;
  final Widget? placeholder;
  final BoxFit fit;

  /// Bounds decoding in physical pixels. Fullscreen viewers can opt into a
  /// larger image while their first frame reuses the already visible cover.
  final int maxDecodeEdge;

  /// Additional display magnification for a zoomable viewer. Update after a
  /// gesture settles, so panning/pinching does not repeatedly start decodes.
  final double decodeScale;

  /// Keep visible wall posters progressing during scrolling, with bounded
  /// native decoding. Video capture previews still wait for the region to idle.
  final bool loadWhileScrolling;

  /// Runs after layout, when the surrounding scrollables allow expensive work.
  /// A later widget update retries a previously full preview queue.
  final VoidCallback? onRequestPreview;

  /// Returns false when the bounded preview queue is full. Only rejected
  /// artwork listens for capacity, and retries when visible and idle again.
  final FutureOr<bool> Function()? tryRequestPreview;
  final ValueListenable<int>? previewCapacity;

  /// Runs once per revision when this artwork is visible and scrolling is idle,
  /// including when a poster is already available. The owner bounds and
  /// cancels any asynchronous work started by this callback.
  final VoidCallback? onVisibleIdle;
  final Object? visibleIdleRevision;
  const MediaArtwork({
    super.key,
    this.poster = '',
    this.thumbnail,
    this.cache,
    this.placeholder,
    this.fit = BoxFit.cover,
    this.maxDecodeEdge = 640,
    this.decodeScale = 1,
    this.loadWhileScrolling = false,
    this.onRequestPreview,
    this.tryRequestPreview,
    this.previewCapacity,
    this.onVisibleIdle,
    this.visibleIdleRevision,
  }) : assert(maxDecodeEdge >= 64),
       assert(decodeScale >= 1 && decodeScale < double.infinity);
  @override
  State<MediaArtwork> createState() => _MediaArtworkState();
}

class _MediaArtworkState extends State<MediaArtwork> {
  String? _reportedFailure;
  bool _posterInvalidated = false;
  bool _repairingPoster = false;
  bool _posterFailed = false;
  int _posterRevision = 0;
  Listenable? _cacheCapacity;
  Future<File?>? _poster;
  bool _previewPending = false, _previewFrameScheduled = false;
  bool _previewRequestRunning = false, _previewBlocked = false;
  int _previewRequestRevision = 0;
  ValueListenable<int>? _previewCapacity;
  bool _visibleIdlePending = false;
  bool _imageLoadingAllowed = false;
  bool _active = true;
  bool get _enabled => _active && ArtworkLifecycle.instance.value;
  bool get _needsPreview =>
      _previewPending &&
      !_previewRequestRunning &&
      !_previewBlocked &&
      (widget.poster.isEmpty || widget.cache == null || _posterFailed);
  ValueListenable<bool>? _scrollActivity;
  final _scrollPositions = <ScrollPosition>{};
  ModalRoute<dynamic>? _route;
  Animation<double>? _routeEntrance;
  Animation<double>? _routeTransition;
  ArtworkDecodeRequest? _decodeRequest;
  ResizeImage? _queuedImage, _failedImage;
  bool _waitingForDecodeCapacity = false;
  bool _posterWasNearby = false;
  int _geometryGeneration = -1, _geometryPriority = -1;
  ScrollPosition? _nearestScrollPosition;
  Axis _scrollAxis = Axis.vertical;

  void _cancelDecode() {
    _decodeRequest?.cancel();
    _decodeRequest = null;
    _queuedImage = null;
    if (_waitingForDecodeCapacity) {
      ArtworkDecodeQueue.instance.capacity.removeListener(_loadArtwork);
      _waitingForDecodeCapacity = false;
    }
  }

  @override
  void initState() {
    super.initState();
    ArtworkLifecycle.instance.addListener(_lifecycleChanged);
    if (!_tracksArtworkLayout) {
      _tracksArtworkLayout = true;
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        _artworkLayoutGeneration++;
      });
    }
    _previewPending =
        widget.onRequestPreview != null || widget.tryRequestPreview != null;
    _visibleIdlePending = widget.onVisibleIdle != null;
    widget.cache?.changes.addListener(_cacheChanged);
  }

  void _lifecycleChanged() {
    if (!ArtworkLifecycle.instance.value) {
      _stopWaitingForPreviewCapacity();
      _cancelDecode();
      // Even if no background frame rebuilds TickerMode, the first resumed
      // frame must retry the cold image whose queued request was cancelled.
      _imageLoadingAllowed = false;
    } else {
      _geometryGeneration = -1;
      _loadArtwork();
    }
  }

  void _cacheChanged() {
    final change = widget.cache?.changes.value;
    if (!mounted ||
        change == null ||
        (!change.all && change.url != widget.poster)) {
      return;
    }
    void changed() {
      _cancelDecode();
      _failedImage = null;
      _posterFailed = false;
      _posterWasNearby = false;
      _poster = change.file == null ? null : SynchronousFuture(change.file);
      _posterRevision++;
    }

    if (_enabled) {
      setState(changed);
    } else {
      // A hidden route reads the newest generation once it becomes active.
      changed();
    }
    _loadArtwork();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _geometryGeneration = -1;
    final nearest = Scrollable.maybeOf(context);
    _nearestScrollPosition = nearest?.position;
    _scrollAxis = axisDirectionToAxis(
      nearest?.axisDirection ?? AxisDirection.down,
    );
    _active = TickerMode.valuesOf(context).enabled;
    if (!_enabled) {
      _cancelDecode();
    }
    _route = ModalRoute.of(context);
    if (!_enabled || _route?.isCurrent == false) {
      _stopWaitingForPreviewCapacity();
    }
    // Sheets can lay out their covers below the screen during entrance. Retry
    // after the transform settles even if the user has not started scrolling.
    final entrance = _route?.animation;
    if (entrance != _routeEntrance) {
      _routeEntrance?.removeStatusListener(_routeSettled);
      _routeEntrance = entrance;
      _routeEntrance?.addStatusListener(_routeSettled);
    }
    final transition = _route?.secondaryAnimation;
    if (transition != _routeTransition) {
      _routeTransition?.removeStatusListener(_routeSettled);
      _routeTransition = transition;
      _routeTransition?.addStatusListener(_routeSettled);
    }
    final activity = ArtworkScrollScope.maybeOf(context);
    if (_scrollActivity != activity) {
      _scrollActivity?.removeListener(_activityChanged);
      _scrollActivity = activity;
      _scrollActivity?.addListener(_activityChanged);
    }
    final positions = <ScrollPosition>{};
    if (_scrollActivity == null) {
      for (final axis in Axis.values) {
        final position = Scrollable.maybeOf(context, axis: axis)?.position;
        if (position != null) positions.add(position);
      }
    }
    for (final position in _scrollPositions.difference(positions)) {
      position.removeListener(_scrollChanged);
      position.isScrollingNotifier.removeListener(_scrollChanged);
    }
    for (final position in positions.difference(_scrollPositions)) {
      position.addListener(_scrollChanged);
      position.isScrollingNotifier.addListener(_scrollChanged);
    }
    _scrollPositions
      ..clear()
      ..addAll(positions);
    _loadArtwork();
  }

  bool get _deferLoading =>
      _scrollActivity?.value == true ||
      Scrollable.recommendDeferredLoadingForContext(
        context,
        axis: Axis.vertical,
      ) ||
      Scrollable.recommendDeferredLoadingForContext(
        context,
        axis: Axis.horizontal,
      );

  void _activityChanged() {
    if (_scrollActivity?.value == true) {
      if (widget.loadWhileScrolling) _loadArtwork();
    } else {
      _loadArtwork();
    }
  }

  void _scrollChanged() {
    if (!mounted ||
        _scrollPositions.any(
          (position) => position.isScrollingNotifier.value,
        )) {
      return;
    }
    _loadArtwork();
  }

  void _routeSettled(AnimationStatus status) {
    if (!_enabled || _route?.isCurrent == false) {
      _stopWaitingForPreviewCapacity();
    }
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      _loadArtwork();
    }
  }

  bool get _visible => _artworkPriority == 0;

  void _stopWaitingForPreviewCapacity() {
    _previewCapacity?.removeListener(_previewCapacityChanged);
    _previewCapacity = null;
    _previewBlocked = false;
  }

  void _previewCapacityChanged() {
    _stopWaitingForPreviewCapacity();
    if (mounted && _enabled && _visible && !_deferLoading) _loadArtwork();
  }

  Future<void> _tryPreview() async {
    final request = widget.tryRequestPreview!;
    final revision = ++_previewRequestRevision;
    final capacity = widget.previewCapacity;
    final before = capacity?.value;
    _previewRequestRunning = true;
    bool accepted;
    try {
      accepted = await Future<bool>.sync(request);
    } catch (error) {
      if (mounted && revision == _previewRequestRevision) {
        _previewRequestRunning = false;
        _reportFailure(error);
      }
      return;
    }
    if (!mounted || revision != _previewRequestRevision) return;
    _previewRequestRunning = false;
    if (accepted) return;
    _previewPending = true;
    if (!_enabled || _route?.isCurrent == false || capacity == null) return;
    // Capacity may have become available while the asynchronous visibility
    // check was answering. Observe its revision before waiting for an event.
    if (capacity.value != before) {
      if (_visible && !_deferLoading) _loadArtwork();
      return;
    }
    _previewBlocked = true;
    _previewCapacity = capacity..addListener(_previewCapacityChanged);
  }

  // Only the immediately adjacent viewport is speculative. Distant sliver
  // children, covered routes and hidden tabs never start artwork work.
  int get _artworkPriority {
    if (!_enabled || _route?.isCurrent == false) return -1;
    if (_geometryGeneration == _artworkLayoutGeneration) {
      return _geometryPriority;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return -1;
    RenderObject? ancestor = box;
    while (ancestor != null) {
      final data = ancestor.parentData;
      // A retained cover can already have a size while predictive back has
      // inserted an unlaid-out route transform above it. Retry via the existing
      // layout/route callbacks; do not cache this temporary lack of geometry.
      if (!ancestor.attached ||
          (ancestor is RenderBox && !ancestor.hasSize) ||
          (ancestor is RenderSliver && ancestor.geometry == null) ||
          (data is SliverMultiBoxAdaptorParentData && data.keptAlive) ||
          (data is SliverLogicalParentData && data.layoutOffset == null)) {
        return -1;
      }
      ancestor = ancestor.parent;
    }
    // A zoomed poster can move its local origin outside the viewport while
    // its scaled image remains visible. Transform the full rectangle before
    // deciding whether its higher-resolution decode may start.
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    // Retained sliver children have no paint transform while offscreen.
    // NaN rectangles can pass overlaps(), so reject them before prioritizing.
    if (!bounds.isFinite) return -1;
    final screen = MediaQuery.maybeSizeOf(context);
    var viewport = screen != null && !screen.isEmpty
        ? Offset.zero & screen
        : bounds;
    var hasViewport = false;
    ancestor = box.parent;
    while (!viewport.isEmpty && ancestor != null) {
      if (ancestor is RenderAbstractViewport) {
        hasViewport = true;
        final clip = MatrixUtils.transformRect(
          ancestor.getTransformTo(null),
          ancestor.paintBounds,
        );
        if (!clip.isFinite) return -1;
        viewport = viewport.intersect(clip);
      }
      ancestor = ancestor.parent;
    }
    var priority = -1;
    if (!viewport.isEmpty && bounds.overlaps(viewport)) {
      priority = 0;
    } else if (widget.loadWhileScrolling && hasViewport && !viewport.isEmpty) {
      final vertical = _scrollAxis == Axis.vertical;
      final extent = (vertical ? viewport.height : viewport.width) * .75;
      final nearby = vertical
          ? Rect.fromLTRB(
              viewport.left,
              viewport.top - extent,
              viewport.right,
              viewport.bottom + extent,
            )
          : Rect.fromLTRB(
              viewport.left - extent,
              viewport.top,
              viewport.right + extent,
              viewport.bottom,
            );
      if (bounds.overlaps(nearby)) {
        final before = vertical
            ? bounds.bottom <= viewport.top
            : bounds.right <= viewport.left;
        final direction = _nearestScrollPosition?.userScrollDirection;
        priority = switch (direction) {
          ScrollDirection.forward => before ? 1 : 2,
          ScrollDirection.reverse => before ? 2 : 1,
          _ => 1,
        };
      }
    }
    _geometryGeneration = _artworkLayoutGeneration;
    return _geometryPriority = priority;
  }

  void _loadArtwork() {
    final needsPoster =
        (_poster == null || _posterWasNearby) &&
        widget.cache != null &&
        widget.poster.isNotEmpty;
    if (!_enabled ||
        _repairingPoster ||
        (_scrollActivity?.value == true && !widget.loadWhileScrolling) ||
        (!needsPoster &&
            _imageLoadingAllowed &&
            _queuedImage == null &&
            ((!_needsPreview && !_visibleIdlePending) ||
                _scrollActivity?.value == true)) ||
        _previewFrameScheduled) {
      return;
    }
    _previewFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _previewFrameScheduled = false;
      if (!mounted ||
          !_enabled ||
          (_scrollActivity?.value == true && !widget.loadWhileScrolling)) {
        return;
      }
      final priority = _artworkPriority;
      if (priority < 0) return;
      // A nearby request can become visible while another prefetch is decoding.
      // Reuse the reserved foreground slot without waiting for that decode.
      _decodeRequest?.refreshPriority();
      // Prepare the small adjacent band before its posters enter the viewport;
      // both queues reserve capacity for visible artwork.
      if (_deferLoading && !widget.loadWhileScrolling) {
        // The scope's idle transition or the fallback ScrollPosition listener
        // retries once when scrolling ends. A timer per deferred cover would
        // keep waking the UI isolate throughout every sustained gesture.
        return;
      }
      if (!_imageLoadingAllowed ||
          (_queuedImage != null && _decodeRequest?.isPending != true)) {
        setState(() => _imageLoadingAllowed = true);
      }
      if ((_poster == null || (_posterWasNearby && priority == 0)) &&
          widget.cache != null &&
          widget.poster.isNotEmpty) {
        final cache = widget.cache!;
        final poster = priority == 0
            ? cache.loadVisible(widget.poster)
            : cache.loadNearby(
                widget.poster,
                canStart: () => mounted && _artworkPriority >= 0,
              );
        if (poster == null) {
          if (_cacheCapacity != cache.capacity) {
            _cacheCapacity?.removeListener(_loadArtwork);
            _cacheCapacity = cache.capacity..addListener(_loadArtwork);
          }
        } else {
          _cacheCapacity?.removeListener(_loadArtwork);
          _cacheCapacity = null;
          setState(() {
            _poster = poster;
            _posterWasNearby = priority > 0;
          });
          poster.then((file) {
            if (!mounted || !identical(_poster, poster)) return;
            // Null can also mean cancelled prefetch, a paused cache or a full
            // queue. Only an actual failure makes software video capture a
            // useful fallback; downloaded and pending posters need no frame.
            _posterFailed = file == null && cache.hasFailed(widget.poster);
            if (_posterWasNearby) {
              if (file == null) {
                // A speculative admission can be dropped after scrolling
                // away. A later visible visit must be able to request it.
                final priority = _artworkPriority;
                if (priority < 0) {
                  _poster = null;
                  _posterWasNearby = false;
                } else if (priority == 0) {
                  _loadArtwork();
                }
              } else {
                _posterWasNearby = false;
              }
            }
            if (_needsPreview) _loadArtwork();
          });
        }
      }
      if (_needsPreview && priority == 0 && !_deferLoading) {
        _previewPending = false;
        if (widget.tryRequestPreview != null) {
          unawaited(_tryPreview());
        } else {
          widget.onRequestPreview?.call();
        }
      }
      if (_visibleIdlePending && priority == 0 && !_deferLoading) {
        _visibleIdlePending = false;
        widget.onVisibleIdle?.call();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(MediaArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache) {
      oldWidget.cache?.changes.removeListener(_cacheChanged);
      widget.cache?.changes.addListener(_cacheChanged);
    }
    if (oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.poster != widget.poster ||
        oldWidget.cache != widget.cache) {
      _cancelDecode();
      _failedImage = null;
      _posterWasNearby = false;
      _imageLoadingAllowed = false;
    }
    if (oldWidget.thumbnail != widget.thumbnail) _reportedFailure = null;
    if (oldWidget.poster != widget.poster || oldWidget.cache != widget.cache) {
      _reportedFailure = null;
      _posterInvalidated = false;
      _repairingPoster = false;
      _posterFailed = false;
      _cacheCapacity?.removeListener(_loadArtwork);
      _cacheCapacity = null;
      _poster = null;
    }
    if (oldWidget.poster != widget.poster ||
        oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.previewCapacity != widget.previewCapacity ||
        (widget.thumbnail == null &&
            (oldWidget.onRequestPreview != widget.onRequestPreview ||
                oldWidget.tryRequestPreview != widget.tryRequestPreview))) {
      _previewRequestRevision++;
      _previewRequestRunning = false;
      _stopWaitingForPreviewCapacity();
      _previewPending =
          widget.onRequestPreview != null || widget.tryRequestPreview != null;
    }
    if (oldWidget.visibleIdleRevision != widget.visibleIdleRevision ||
        (oldWidget.onVisibleIdle == null) != (widget.onVisibleIdle == null)) {
      // Parent rebuilds often replace a closure without changing its work.
      // Only a new revision or enabling the callback admits another request.
      _visibleIdlePending = widget.onVisibleIdle != null;
    }
    _loadArtwork();
  }

  bool _canLoadImage(ResizeImage provider) {
    // Permission granted before a download is not permission to decode its
    // result later: scrolling can begin while the file is still in flight.
    var cached = false;
    // FileImage and ResizeImage return synchronous keys. Use the resolved key,
    // not the provider object, to reuse decoded/pending textures while flinging.
    provider.obtainKey(ImageConfiguration.empty).then((key) {
      cached = PaintingBinding.instance.imageCache.statusForKey(key).tracked;
    });
    // Warm images require neither decoding nor viewport transforms. A parent
    // rebuild used to walk every ancestor and multiply global transforms for
    // each already-decoded poster, even though it can be displayed immediately.
    if (cached) {
      if (_queuedImage == provider) _cancelDecode();
      return true;
    }
    if (!_enabled) return false;
    if (widget.loadWhileScrolling) {
      if (_failedImage == provider) return false;
      if (_queuedImage != provider) {
        _cancelDecode();
        _queuedImage = provider;
      }
      if (!_imageLoadingAllowed) {
        _loadArtwork();
        return false;
      }
      if (_decodeRequest?.isPending != true) {
        _decodeRequest = ArtworkDecodeQueue.instance.request(
          provider,
          canStart: () => mounted && _enabled,
          priority: () => _artworkPriority,
          onStart: () {
            if (mounted) setState(() {});
          },
          onError: (error, stack) {
            if (!mounted || _queuedImage != provider) return;
            _failedImage = provider;
            final file = (provider.imageProvider as FileImage).file;
            if (widget.poster.isNotEmpty && file.path != widget.thumbnail) {
              _repairPoster(widget.poster, file);
            } else {
              _reportFailure(error);
            }
            setState(() {});
          },
        );
        if (_decodeRequest == null && !_waitingForDecodeCapacity) {
          _waitingForDecodeCapacity = true;
          ArtworkDecodeQueue.instance.capacity.addListener(_loadArtwork);
        } else if (_decodeRequest != null && _waitingForDecodeCapacity) {
          ArtworkDecodeQueue.instance.capacity.removeListener(_loadArtwork);
          _waitingForDecodeCapacity = false;
        }
      }
      return false;
    }
    if (_imageLoadingAllowed && !_deferLoading && _visible) return true;
    _imageLoadingAllowed = false;
    _loadArtwork();
    return false;
  }

  ResizeImage _imageFor(File file, int edge) {
    final requested = artworkImage(file, edge);
    final warm = _warmArtworkImage(file, edge, widget.maxDecodeEdge);
    if (warm == null) return requested;
    if (warm.width! >= edge && warm.width! <= widget.maxDecodeEdge) {
      // A card's larger texture is already sharp enough for the detail header.
      // Sharing its exact provider avoids another disk read and decode.
      return warm;
    }
    // Present the resident texture on the first frame, including while the
    // route opens or scrolling is busy. Only then request a more suitable
    // decode; Image's gapless playback keeps the warm frame during that work.
    return _canLoadImage(requested) ? requested : warm;
  }

  @override
  void dispose() {
    _stopWaitingForPreviewCapacity();
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    _cancelDecode();
    widget.cache?.changes.removeListener(_cacheChanged);
    _cacheCapacity?.removeListener(_loadArtwork);
    _scrollActivity?.removeListener(_activityChanged);
    _routeEntrance?.removeStatusListener(_routeSettled);
    _routeTransition?.removeStatusListener(_routeSettled);
    for (final position in _scrollPositions) {
      position.removeListener(_scrollChanged);
      position.isScrollingNotifier.removeListener(_scrollChanged);
    }
    super.dispose();
  }

  void _repairPoster(String poster, File file) {
    final cache = widget.cache;
    if (_repairingPoster) return;
    if (_posterInvalidated || cache == null) {
      if (_posterFailed) return;
      // A replacement that still cannot decode is a real failure. Retry the
      // video fallback after layout, while preserving visibility/idle gates.
      _posterFailed = true;
      _loadArtwork();
      return;
    }
    _posterInvalidated = true;
    _repairingPoster = true;
    // A stale or corrupt disk entry must be evicted from both caches. Repair
    // once per mounted cover, after the error builder has finished its frame.
    scheduleMicrotask(() async {
      await _evictArtworkImages(file);
      await cache.invalidate(poster, failedFile: file, retryImmediately: true);
      if (!mounted || widget.poster != poster || widget.cache != cache) return;
      void repaired() {
        _cancelDecode();
        _failedImage = null;
        _poster = null;
        _repairingPoster = false;
        _posterFailed = false;
        _posterRevision++;
      }

      if (_enabled) {
        setState(repaired);
      } else {
        repaired();
      }
      _loadArtwork();
    });
  }

  void _reportFailure(Object error) {
    var message = error.toString();
    final thumbnail = widget.thumbnail;
    if (thumbnail != null && thumbnail.isNotEmpty) {
      message = message.replaceAll(thumbnail, '[封面路径]');
      message = message.replaceAll(Uri.file(thumbnail).toString(), '[封面路径]');
    }
    message = AppLog.instance.sanitize(message);
    if (_reportedFailure == message) return;
    _reportedFailure = message;
    scheduleMicrotask(() => AppLog.instance.warning('封面显示', message));
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.poster, thumbnail = widget.thumbnail;
    final fit = widget.fit;
    final colors = GlassPalette.of(context);
    final placeholder =
        widget.placeholder ??
        ColoredBox(
          color: colors.field,
          child: Center(
            child: Icon(
              Icons.play_circle_outline_rounded,
              color: LibraryStyles.of(context).placeholderIcon,
              size: LibraryStyles.iconPlaceholder,
            ),
          ),
        );
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    Widget frame(int decodeWidth, {bool load = true}) {
      if (thumbnail == null || thumbnail.isEmpty) return placeholder;
      final provider = load
          ? _imageFor(File(thumbnail), decodeWidth)
          : _warmArtworkImage(
              File(thumbnail),
              decodeWidth,
              widget.maxDecodeEdge,
            );
      if (provider == null) return placeholder;
      return !_canLoadImage(provider)
          ? placeholder
          : Image(
              image: provider,
              fit: fit,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              frameBuilder: (_, child, frame, synchronous) =>
                  frame != null || synchronous
                  ? child
                  : Stack(fit: StackFit.expand, children: [placeholder, child]),
              errorBuilder: (_, error, _) {
                _reportFailure(error);
                return placeholder;
              },
            );
    }

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Small source rows used to decode the same 640px texture as a large
          // poster. Use the larger layout edge for cropped covers, with 64px
          // buckets so nearby responsive sizes can share the image cache.
          final edge = constraints.hasBoundedWidth
              ? constraints.hasBoundedHeight
                    ? constraints.biggest.longestSide
                    : constraints.maxWidth
              : widget.maxDecodeEdge / pixelRatio;
          final decodeWidth =
              ((edge * pixelRatio * widget.decodeScale / 64).ceil() * 64).clamp(
                64,
                widget.maxDecodeEdge,
              );
          return poster.isNotEmpty
              ? FutureBuilder<File?>(
                  // The repaired file keeps its path. Replace the failed
                  // Image element as well as its decoded-cache entry so that
                  // FileImage's equal path key cannot retain the old error.
                  key: ValueKey((poster, widget.cache, _posterRevision)),
                  future: _poster,
                  initialData: widget.cache?.resolvedFile(poster),
                  builder: (_, snapshot) {
                    if (snapshot.data == null) return frame(decodeWidth);
                    final provider = _imageFor(snapshot.data!, decodeWidth);
                    return !_canLoadImage(provider)
                        ? frame(
                            decodeWidth,
                            load:
                                !widget.loadWhileScrolling ||
                                _failedImage == provider,
                          )
                        : Image(
                            image: provider,
                            fit: fit,
                            width: double.infinity,
                            height: double.infinity,
                            filterQuality: FilterQuality.low,
                            gaplessPlayback: true,
                            frameBuilder: (_, child, frame, synchronous) =>
                                frame != null || synchronous
                                ? child
                                : Stack(
                                    fit: StackFit.expand,
                                    children: [placeholder, child],
                                  ),
                            errorBuilder: (_, error, _) {
                              _repairPoster(poster, snapshot.data!);
                              return frame(decodeWidth);
                            },
                          );
                  },
                )
              : frame(decodeWidth);
        },
      ),
    );
  }
}

String mediaTime(double seconds) {
  if (!seconds.isFinite || seconds < 0) return '--:--';
  final total = seconds.floor();
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60 % 60).toString().padLeft(2, '0');
  final secs = (total % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
}

// This bounded index owns only providers/keys, never decoded images or stream
// listeners. Flutter's ImageCache remains responsible for texture residency
// and eviction. Index lookup is O(1), with at most 32 size variants per file.
final _artworkVariants = <(String, int), Map<int, ResizeImage>>{};

/// Use the same SDK provider/key for lookup and display, bounding both axes.
ResizeImage artworkImage(File file, int edge) {
  final revision = posterFileRevision(file);
  final identity = (file.path, revision);
  final variants = _artworkVariants.remove(identity) ?? <int, ResizeImage>{};
  _artworkVariants[identity] = variants;
  while (_artworkVariants.length > 512) {
    _artworkVariants.remove(_artworkVariants.keys.first);
  }
  final provider =
      variants.remove(edge) ??
      ResizeImage(
        _VersionedFileImage(file, revision),
        width: edge,
        height: edge,
        policy: ResizeImagePolicy.fit,
      );
  variants[edge] = provider;
  while (variants.length > 32) {
    variants.remove(variants.keys.first);
  }
  return provider;
}

ResizeImage? _warmArtworkImage(File file, int edge, int maxDecodeEdge) {
  ResizeImage? suitable, fallback;
  final variants = _artworkVariants[(file.path, posterFileRevision(file))];
  if (variants == null) return null;
  for (final provider in variants.values) {
    var decoded = false;
    // FileImage/ResizeImage keys resolve synchronously, without file access.
    provider.obtainKey(ImageConfiguration.empty).then((key) {
      final status = PaintingBinding.instance.imageCache.statusForKey(key);
      decoded = !status.pending && (status.keepAlive || status.live);
    });
    if (!decoded) continue;
    final size = provider.width!;
    if (size >= edge && size <= maxDecodeEdge) {
      if (suitable == null || size < suitable.width!) suitable = provider;
    } else if (fallback == null ||
        (size <= maxDecodeEdge &&
            (fallback.width! > maxDecodeEdge || size > fallback.width!))) {
      fallback = provider;
    }
  }
  return suitable ?? fallback;
}

Future<void> _evictArtworkImages(File file) async {
  final variants = _artworkVariants.remove((
    file.path,
    posterFileRevision(file),
  ));
  if (variants == null) return;
  await Future.wait(variants.values.map((provider) => provider.evict()));
}

class _VersionedFileImage extends FileImage {
  final int revision;

  const _VersionedFileImage(super.file, this.revision);

  @override
  bool operator ==(Object other) =>
      other is _VersionedFileImage &&
      other.revision == revision &&
      super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, revision);
}
