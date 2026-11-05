import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

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

  /// A previous file for the same immutable media, before a durable thumbnail
  /// was prepared. Reuse only its already decoded frame; never read or decode
  /// this path. The current thumbnail remains the disk-cache fallback.
  final String? thumbnailDecodedFallback;

  /// Disk LRU eviction does not invalidate pixels already held by this Image.
  /// The owner can retain that frame while preparing a replacement file.
  /// A changed media identity must still replace the owner's widget/key.
  final bool thumbnailFileAvailable;
  final PosterCache? cache;
  final Widget? placeholder;

  /// Used only while awaiting a path or native image frame, never on failure.
  final Widget? loadingPlaceholder;

  /// The prepared thumbnail failed to decode or disappeared from disk. Called
  /// once per failed path, after native cache eviction and outside build.
  /// The owner invalidates its prepared-path cache and bounds any retry work.
  final void Function(String path, Object error)? onThumbnailError;

  /// A real frame from the current thumbnail stream is ready. Owners can reset
  /// consecutive retry budgets here; prepared paths and held fallback frames
  /// do not prove a newly prepared file can decode.
  final ValueChanged<String>? onThumbnailReady;

  /// The current media has a usable frame, possibly from its equivalent warm
  /// fallback. Reports [thumbnail]; unlike [onThumbnailReady], this does not
  /// validate the current disk file or reset a file-repair retry budget.
  final ValueChanged<String>? onThumbnailFrame;

  /// Signals that the owner completed a bounded repair/probe at the same path.
  /// This explicitly replaces a failed Image stream; layout/preview revisions
  /// do not retry an unchanged broken file.
  final Object? thumbnailRevision;

  /// Observe repaired bytes even when a parent's prepared-row snapshot did not
  /// change. The getter must read only a cheap per-thumbnail revision scalar.
  final Listenable? thumbnailChanges;
  final Object? Function()? thumbnailRevisionOf;
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

  /// Allows a preview provider to serve cached paths for visible/nearby cells
  /// during scrolling. The provider must separately suspend cold source reads
  /// and image processing; video capture providers must leave this disabled.
  final bool previewWhileScrolling;

  /// Lets a bounded preview queue promote a nearby cell when it becomes visible.
  final ValueChanged<int>? onPreviewPriority;

  /// Runs after layout, when the surrounding scrollables allow expensive work.
  /// A later widget update retries a previously full preview queue.
  final VoidCallback? onRequestPreview;

  /// Returns false when the bounded preview queue is full. Only rejected
  /// artwork listens for capacity, and retries when visible and idle again.
  final FutureOr<bool> Function()? tryRequestPreview;
  final ValueListenable<int>? previewCapacity;

  /// Requests a new prepared path without replacing the resident Image state.
  final Object? previewRevision;

  /// Runs once per revision when this artwork is visible and scrolling is idle,
  /// including when a poster is already available. The owner bounds and
  /// cancels any asynchronous work started by this callback.
  final VoidCallback? onVisibleIdle;
  final Object? visibleIdleRevision;
  const MediaArtwork({
    super.key,
    this.poster = '',
    this.thumbnail,
    this.thumbnailDecodedFallback,
    this.thumbnailFileAvailable = true,
    this.cache,
    this.placeholder,
    this.loadingPlaceholder,
    this.onThumbnailError,
    this.onThumbnailReady,
    this.onThumbnailFrame,
    this.thumbnailRevision,
    this.thumbnailChanges,
    this.thumbnailRevisionOf,
    this.fit = BoxFit.cover,
    this.maxDecodeEdge = 1280,
    this.decodeScale = 1,
    this.loadWhileScrolling = false,
    this.previewWhileScrolling = false,
    this.onPreviewPriority,
    this.onRequestPreview,
    this.tryRequestPreview,
    this.previewCapacity,
    this.previewRevision,
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
  ResizeImage? _queuedImage, _failedImage, _displayedPosterImage;
  ResizeImage? _displayedThumbnailImage;
  ResizeImage? _readyThumbnailImage;
  _RetainedArtworkImage? _thumbnailStream, _posterStream;
  bool _thumbnailHasFrame = false, _posterHasFrame = false;
  int _thumbnailRevision = 0, _thumbnailImageRevision = 0;
  bool _thumbnailErrorReported = false;
  Object? _observedThumbnailRevision;
  bool _thumbnailSignalDirty = false;
  bool _waitingForDecodeCapacity = false;
  bool _posterWasNearby = false;
  int _geometryGeneration = -1, _geometryPriority = -1;
  int? _reportedPreviewPriority;
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
    _observedThumbnailRevision = _readThumbnailRevision();
    widget.thumbnailChanges?.addListener(_thumbnailChanged);
  }

  Object? _readThumbnailRevision() => widget.thumbnailRevisionOf != null
      ? widget.thumbnailRevisionOf!()
      : widget.thumbnailRevision;

  void _resetThumbnail({required bool repaired}) {
    _thumbnailRevision++;
    _thumbnailErrorReported = false;
    _readyThumbnailImage = null;
    if (_failedImage != null || repaired) {
      _thumbnailStream?.invalidate();
      _thumbnailStream?.release();
      _thumbnailStream = null;
      _thumbnailImageRevision++;
      _thumbnailHasFrame = false;
    }
    _cancelDecode();
    _failedImage = null;
    if (repaired) _imageLoadingAllowed = false;
  }

  void _thumbnailChanged() {
    if (!mounted) return;
    final revision = _readThumbnailRevision();
    if (revision == _observedThumbnailRevision) return;
    _observedThumbnailRevision = revision;
    _resetThumbnail(repaired: true);
    _thumbnailSignalDirty = true;
    if (!_enabled || _route?.isCurrent == false) return;
    _thumbnailSignalDirty = false;
    setState(() {});
    _loadArtwork();
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
      if (_thumbnailSignalDirty && _enabled && _route?.isCurrent != false) {
        _thumbnailSignalDirty = false;
        setState(() {});
      }
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
    if (change.retryOnly) {
      // Policy changes resume only missing requests or portable-source
      // upgrades. They must not throw away the resident Image element.
      if (!_posterHasFrame && _displayedPosterImage == null) _poster = null;
      _posterFailed = false;
      _loadArtwork();
      return;
    }
    void changed() {
      _cancelDecode();
      _failedImage = null;
      _posterFailed = false;
      _posterWasNearby = false;
      _poster = change.file == null ? null : SynchronousFuture(change.file);
      if (change.file == null) {
        _posterStream?.release();
        _posterStream = null;
        _displayedPosterImage = null;
        _posterHasFrame = false;
      }
      // A valid source upgrade keeps the Image element and its resident frame
      // even if Flutter's global cache evicted the old portable texture.
      if (!_posterHasFrame) _posterRevision++;
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
    if (_enabled && _route?.isCurrent != false) _thumbnailSignalDirty = false;
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
    if (mounted && _enabled && _previewAllowed) _loadArtwork();
  }

  bool get _previewAllowed => widget.previewWhileScrolling
      ? _artworkPriority >= 0
      : _visible && !_deferLoading;

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
      if (_previewAllowed) _loadArtwork();
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
        (_poster == null ||
            _posterWasNearby ||
            widget.cache?.needsSourceUpgrade(widget.poster) == true) &&
        widget.cache != null &&
        widget.poster.isNotEmpty;
    if (!_enabled ||
        _repairingPoster ||
        (_scrollActivity?.value == true && !widget.loadWhileScrolling) ||
        (!needsPoster &&
            _imageLoadingAllowed &&
            _queuedImage == null &&
            ((!_needsPreview &&
                    !_visibleIdlePending &&
                    (!_previewRequestRunning ||
                        widget.onPreviewPriority == null)) ||
                (_scrollActivity?.value == true &&
                    !widget.previewWhileScrolling))) ||
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
      if (priority != _reportedPreviewPriority) {
        _reportedPreviewPriority = priority;
        widget.onPreviewPriority?.call(priority);
      }
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
      if ((_poster == null ||
              ((_posterWasNearby ||
                      widget.cache?.needsSourceUpgrade(widget.poster) ==
                          true) &&
                  priority == 0)) &&
          widget.cache != null &&
          widget.poster.isNotEmpty) {
        final cache = widget.cache!;
        final requestedPoster = widget.poster;
        final poster = priority == 0
            ? cache.loadVisible(
                requestedPoster,
                canStart: () =>
                    mounted &&
                    widget.cache == cache &&
                    widget.poster == requestedPoster &&
                    _enabled &&
                    _artworkPriority == 0,
              )
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
          if (_poster == null || _posterWasNearby) {
            setState(() {
              _poster = poster;
              _posterWasNearby = priority > 0;
            });
          }
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
      if (_needsPreview && _previewAllowed) {
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
    if (oldWidget.thumbnailChanges != widget.thumbnailChanges) {
      oldWidget.thumbnailChanges?.removeListener(_thumbnailChanged);
      widget.thumbnailChanges?.addListener(_thumbnailChanged);
    }
    final revision = _readThumbnailRevision();
    final thumbnailRepaired =
        oldWidget.thumbnailChanges != widget.thumbnailChanges ||
        revision != _observedThumbnailRevision;
    _observedThumbnailRevision = revision;
    if (oldWidget.thumbnail != widget.thumbnail || thumbnailRepaired) {
      _resetThumbnail(repaired: thumbnailRepaired);
      if (!_enabled && thumbnailRepaired) _thumbnailSignalDirty = true;
    }
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
    if (oldWidget.thumbnail != widget.thumbnail) {
      _reportedFailure = null;
      if (widget.thumbnail == null || widget.thumbnail!.isEmpty) {
        _thumbnailStream?.release();
        _thumbnailStream = null;
        _displayedThumbnailImage = null;
        _thumbnailHasFrame = false;
      }
    }
    if (oldWidget.poster != widget.poster || oldWidget.cache != widget.cache) {
      _posterStream?.release();
      _posterStream = null;
      _reportedFailure = null;
      _posterInvalidated = false;
      _repairingPoster = false;
      _posterFailed = false;
      _cacheCapacity?.removeListener(_loadArtwork);
      _cacheCapacity = null;
      _poster = null;
      _displayedPosterImage = null;
      _posterHasFrame = false;
    }
    if (oldWidget.poster != widget.poster ||
        oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.previewCapacity != widget.previewCapacity ||
        oldWidget.previewRevision != widget.previewRevision ||
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
    // A retained Image owns its frame independently of ImageCache. Memory
    // pressure can evict that cache while a covered route has detached its
    // stream listener; keep the resident element instead of showing loading.
    if ((_thumbnailHasFrame && _displayedThumbnailImage == provider) ||
        (_posterHasFrame && _displayedPosterImage == provider)) {
      if (_queuedImage == provider) _cancelDecode();
      return true;
    }
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
    if (cached || _RetainedArtworkImage.hasFrame(provider)) {
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
              _thumbnailError(provider, error);
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

  ResizeImage _imageFor(
    File file,
    int edge,
    double? coverAspectRatio, {
    String? decodedFallback,
  }) {
    final requested = artworkImage(
      file,
      edge,
      coverAspectRatio: coverAspectRatio,
      maxDecodeEdge: widget.maxDecodeEdge,
    );
    var warm = _warmArtworkImage(
      file,
      edge,
      widget.maxDecodeEdge,
      coverAspectRatio,
    );
    if (decodedFallback != null &&
        (warm == null ||
            !_suitableArtwork(
              warm,
              edge,
              widget.maxDecodeEdge,
              coverAspectRatio,
            ))) {
      final previous = _warmArtworkImage(
        File(decodedFallback),
        edge,
        widget.maxDecodeEdge,
        coverAspectRatio,
      );
      if (previous != null &&
          (warm == null ||
              _suitableArtwork(
                previous,
                edge,
                widget.maxDecodeEdge,
                coverAspectRatio,
              ))) {
        warm = previous;
      }
    }
    if (warm == null) return requested;
    if (_suitableArtwork(warm, edge, widget.maxDecodeEdge, coverAspectRatio)) {
      // A card's larger texture is already sharp enough for the detail header.
      // Sharing its exact provider avoids another disk read and decode.
      return warm;
    }
    // Present the resident texture on the first frame, including while the
    // route opens or scrolling is busy. Only then request a more suitable
    // decode; Image's gapless playback keeps the warm frame during that work.
    return _canLoadImage(requested) ? requested : warm;
  }

  ResizeImage _retainStream(ResizeImage provider, {required bool poster}) {
    final previous = poster ? _posterStream : _thumbnailStream;
    if (previous?.source == provider) return previous!;
    previous?.release();
    final retained = _RetainedArtworkImage.acquire(provider);
    if (poster) {
      _posterStream = retained;
    } else {
      _thumbnailStream = retained;
    }
    return retained;
  }

  @override
  void dispose() {
    _thumbnailStream?.release();
    _posterStream?.release();
    _thumbnailStream = _posterStream = null;
    _stopWaitingForPreviewCapacity();
    ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    widget.thumbnailChanges?.removeListener(_thumbnailChanged);
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
    _posterStream?.invalidate();
    _posterStream?.release();
    _posterStream = null;
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

  void _thumbnailError(ResizeImage provider, Object error) {
    _thumbnailStream?.invalidate();
    _thumbnailStream?.release();
    _thumbnailStream = null;
    _failedImage = provider;
    _thumbnailHasFrame = false;
    _readyThumbnailImage = null;
    _reportFailure(error);
    final path = widget.thumbnail;
    if (path == null ||
        _thumbnailErrorReported ||
        widget.onThumbnailError == null) {
      return;
    }
    _thumbnailErrorReported = true;
    final revision = _thumbnailRevision;
    final file = (provider.imageProvider as FileImage).file;
    scheduleMicrotask(() async {
      await provider.evict();
      await _evictArtworkImages(file);
      if (!mounted ||
          revision != _thumbnailRevision ||
          widget.thumbnail != path) {
        return;
      }
      widget.onThumbnailError?.call(path, error);
    });
  }

  void _thumbnailReady(ResizeImage provider) {
    final path = widget.thumbnail;
    final displayedPath = (provider.imageProvider as FileImage).file.path;
    final currentFile = displayedPath == path;
    if (path == null ||
        (widget.onThumbnailReady == null && widget.onThumbnailFrame == null) ||
        _readyThumbnailImage == provider ||
        _failedImage != null ||
        (_queuedImage != null && _queuedImage != provider) ||
        (!currentFile && displayedPath != widget.thumbnailDecodedFallback)) {
      return;
    }
    _readyThumbnailImage = provider;
    final revision = _thumbnailRevision;
    scheduleMicrotask(() {
      if (!mounted ||
          revision != _thumbnailRevision ||
          widget.thumbnail != path ||
          _displayedThumbnailImage != provider ||
          _failedImage != null ||
          (_queuedImage != null && _queuedImage != provider) ||
          !_thumbnailHasFrame) {
        if (mounted &&
            revision == _thumbnailRevision &&
            _readyThumbnailImage == provider) {
          _readyThumbnailImage = null;
        }
        return;
      }
      widget.onThumbnailFrame?.call(path);
      if (currentFile) widget.onThumbnailReady?.call(path);
    });
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
    Widget frame(
      int decodeWidth,
      double? coverAspectRatio, {
      bool load = true,
    }) {
      final loading = widget.loadingPlaceholder ?? placeholder;
      if (thumbnail == null || thumbnail.isEmpty) return loading;
      final resident = _displayedThumbnailImage;
      var provider = !widget.thumbnailFileAvailable
          ? _thumbnailHasFrame &&
                    resident != null &&
                    ((resident.imageProvider as FileImage).file.path ==
                            thumbnail ||
                        (resident.imageProvider as FileImage).file.path ==
                            widget.thumbnailDecodedFallback)
                ? resident
                : null
          : load
          ? _imageFor(
              File(thumbnail),
              decodeWidth,
              coverAspectRatio,
              decodedFallback: widget.thumbnailDecodedFallback,
            )
          : _warmArtworkImage(
              File(thumbnail),
              decodeWidth,
              widget.maxDecodeEdge,
              coverAspectRatio,
            );
      if (provider == null) return loading;
      if (_failedImage == provider) {
        _thumbnailHasFrame = false;
        return placeholder;
      }
      if (!_canLoadImage(provider)) {
        final previous = _displayedThumbnailImage;
        if (previous == null ||
            (!_thumbnailHasFrame && !_decodedArtwork(previous))) {
          return loading;
        }
        // Generated RAW/other-format previews can change disk path on a size
        // upgrade. Keep the resident Image while the replacement waits for its
        // bounded decode slot, just as for a larger decode of the same JPEG.
        provider = previous;
      }
      _displayedThumbnailImage = provider;
      final image = Image(
        key: ValueKey(_thumbnailImageRevision),
        image: _retainStream(provider, poster: false),
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        frameBuilder: (_, child, frame, synchronous) {
          if (frame != null || synchronous) {
            _thumbnailHasFrame = true;
            _thumbnailStream?.markReady();
            _thumbnailReady(provider!);
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (!_thumbnailHasFrame) IgnorePointer(child: loading),
            ],
          );
        },
        errorBuilder: (_, error, _) {
          _thumbnailError(provider!, error);
          return placeholder;
        },
      );
      // Keep Image at the same element slot when a warm preview becomes the
      // completed decode. Replacing Stack with Image discarded its stream and
      // could expose a blank frame as the loading treatment disappeared.
      return Stack(fit: StackFit.expand, children: [image]);
    }

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Bucket physical dimensions so responsive layouts share textures.
          // Cover decodes also need the box aspect ratio: fitting a landscape
          // source into a square first would enlarge its cropped pixels later.
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
          final coverAspectRatio =
              fit == BoxFit.cover &&
                  constraints.hasBoundedWidth &&
                  constraints.hasBoundedHeight &&
                  !constraints.biggest.isEmpty
              ? (constraints.maxWidth * pixelRatio * widget.decodeScale / 64)
                        .ceil() /
                    (constraints.maxHeight *
                            pixelRatio *
                            widget.decodeScale /
                            64)
                        .ceil()
              : null;
          return poster.isNotEmpty
              ? FutureBuilder<File?>(
                  // The repaired file keeps its path. Replace the failed
                  // Image element as well as its decoded-cache entry so that
                  // FileImage's equal path key cannot retain the old error.
                  key: ValueKey((poster, widget.cache, _posterRevision)),
                  future: _poster,
                  initialData: widget.cache?.resolvedFile(poster),
                  builder: (_, snapshot) {
                    if (snapshot.data == null) {
                      return frame(decodeWidth, coverAspectRatio);
                    }
                    var provider = _imageFor(
                      snapshot.data!,
                      decodeWidth,
                      coverAspectRatio,
                    );
                    if (!_canLoadImage(provider)) {
                      final previous = _displayedPosterImage;
                      if (previous == null ||
                          (!_posterHasFrame && !_decodedArtwork(previous))) {
                        return frame(
                          decodeWidth,
                          coverAspectRatio,
                          load:
                              !widget.loadWhileScrolling ||
                              _failedImage == provider,
                        );
                      }
                      // Source upgrades have a new file/key. Keep the already
                      // decoded portable cover until its replacement is ready.
                      provider = previous;
                    }
                    _displayedPosterImage = provider;
                    return Image(
                      image: _retainStream(provider, poster: true),
                      fit: fit,
                      width: double.infinity,
                      height: double.infinity,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      frameBuilder: (_, child, frame, synchronous) {
                        if (frame != null || synchronous) {
                          _posterHasFrame = true;
                          _posterStream?.markReady();
                          // One failed replacement is bounded until a real
                          // frame succeeds. A later cache deletion is a new
                          // incident and must be eligible for repair again.
                          if (!_repairingPoster) _posterInvalidated = false;
                        }
                        return _posterHasFrame
                            ? child
                            : Stack(
                                fit: StackFit.expand,
                                children: [placeholder, child],
                              );
                      },
                      errorBuilder: (_, error, _) {
                        _posterHasFrame = false;
                        _repairPoster(poster, snapshot.data!);
                        return frame(decodeWidth, coverAspectRatio);
                      },
                    );
                  },
                )
              : frame(decodeWidth, coverAspectRatio);
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

/// Image re-resolves its provider when TickerMode changes, even when it still
/// owns the previous pixels. After a long viewer session the global cache can
/// have evicted that key, causing every returning wall cell to decode again.
/// A lease preserves the existing stream for a mounted thumbnail/poster slot,
/// including its thumbnail fallback; it does not copy decoded pixels.
/// Standard Image still detaches its listener while hidden (animations stop).
/// Only mounted artwork slots own leases; the last release removes the entry.
class _RetainedArtworkImage extends ResizeImage {
  static final _displayed = <ResizeImage, _RetainedArtworkImage>{};
  final ResizeImage source;
  final _state = _RetainedArtworkStream();

  _RetainedArtworkImage._(this.source)
    : super(
        source.imageProvider,
        width: source.width,
        height: source.height,
        policy: source.policy,
        allowUpscaling: source.allowUpscaling,
      );

  static _RetainedArtworkImage acquire(ResizeImage source) {
    final value = _displayed.putIfAbsent(
      source,
      () => _RetainedArtworkImage._(source),
    );
    value._state.leases++;
    return value;
  }

  static bool hasFrame(ResizeImage source) =>
      _displayed[source]?._state.ready == true;

  void markReady() => _state.ready = true;

  void invalidate() {
    if (identical(_displayed[source], this)) _displayed.remove(source);
  }

  void release() {
    assert(_state.leases > 0);
    if (--_state.leases != 0) return;
    invalidate();
    _state.handle?.dispose();
    _state.handle = null;
    _state.completer = null;
  }

  @override
  Future<ResizeImageKey> obtainKey(ImageConfiguration configuration) =>
      source.obtainKey(configuration);

  @override
  ImageStreamCompleter loadImage(
    ResizeImageKey key,
    ImageDecoderCallback decode,
  ) => source.loadImage(key, decode);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    ResizeImageKey key,
    ImageErrorListener handleError,
  ) {
    final retained = _state.completer;
    if (retained != null && _state.leases > 0) {
      stream.setCompleter(retained);
      return;
    }
    super.resolveStreamForKey(configuration, stream, key, handleError);
    if (_state.leases > 0 && stream.completer != null) {
      _state.completer = stream.completer;
      _state.handle = _state.completer!.keepAlive();
    }
  }
}

class _RetainedArtworkStream {
  ImageStreamCompleter? completer;
  ImageStreamCompleterHandle? handle;
  int leases = 0;
  bool ready = false;
}

// This bounded index owns only providers/keys, never decoded images or stream
// listeners. Flutter's ImageCache remains responsible for texture residency
// and eviction. Index lookup is O(1), with at most 32 size variants per file.
final _artworkVariants =
    <(String, int), Map<(int, double?, int?), ResizeImage>>{};

/// Native decoding with bounded dimensions, without upscaling small sources.
/// [coverAspectRatio] sizes the visible crop; null fits inside an edge square.
ResizeImage artworkImage(
  File file,
  int edge, {
  double? coverAspectRatio,
  int? maxDecodeEdge,
}) {
  final revision = posterFileRevision(file);
  final identity = (file.path, revision);
  final variants =
      _artworkVariants.remove(identity) ??
      <(int, double?, int?), ResizeImage>{};
  final limit = coverAspectRatio == null ? null : maxDecodeEdge ?? edge;
  final variant = (edge, coverAspectRatio, limit);
  _artworkVariants[identity] = variants;
  while (_artworkVariants.length > 512) {
    _artworkVariants.remove(_artworkVariants.keys.first);
  }
  final provider =
      variants.remove(variant) ??
      (coverAspectRatio == null
          ? ResizeImage(
              _VersionedFileImage(file, revision),
              width: edge,
              height: edge,
              policy: ResizeImagePolicy.fit,
            )
          : _CoverResizeImage(
              _VersionedFileImage(
                file,
                revision,
                coverAspectRatio: coverAspectRatio,
                maxDecodeEdge: limit,
              ),
              edge,
            ));
  variants[variant] = provider;
  while (variants.length > 32) {
    variants.remove(variants.keys.first);
  }
  return provider;
}

bool _decodedArtwork(ResizeImage provider) {
  if (_RetainedArtworkImage.hasFrame(provider)) return true;
  var decoded = false;
  // FileImage/ResizeImage keys resolve synchronously, without file access.
  provider.obtainKey(ImageConfiguration.empty).then((key) {
    final status = PaintingBinding.instance.imageCache.statusForKey(key);
    decoded = !status.pending && (status.keepAlive || status.live);
  });
  return decoded;
}

bool _suitableArtwork(
  ResizeImage provider,
  int edge,
  int maxDecodeEdge,
  double? coverAspectRatio,
) {
  final source = provider.imageProvider as _VersionedFileImage;
  return provider.width! >= edge &&
      provider.width! <= maxDecodeEdge &&
      source.coverAspectRatio == coverAspectRatio &&
      (coverAspectRatio == null || source.maxDecodeEdge == maxDecodeEdge);
}

ResizeImage? _warmArtworkImage(
  File file,
  int edge,
  int maxDecodeEdge,
  double? coverAspectRatio,
) {
  ResizeImage? suitable, fallback;
  final identity = (file.path, posterFileRevision(file));
  final variants = _artworkVariants[identity];
  if (variants == null) return null;
  for (final provider in variants.values) {
    if (!_decodedArtwork(provider)) continue;
    final size = provider.width!;
    if (_suitableArtwork(provider, edge, maxDecodeEdge, coverAspectRatio)) {
      if (suitable == null || size < suitable.width!) suitable = provider;
    } else if (fallback == null ||
        (size <= maxDecodeEdge &&
            (fallback.width! > maxDecodeEdge || size > fallback.width!))) {
      fallback = provider;
    }
  }
  final warm = suitable ?? fallback;
  if (warm != null) {
    // Warm-only aliases must age by use too, otherwise repeated returns keep
    // the texture alive while silently losing the bounded lookup for it.
    _artworkVariants.remove(identity);
    _artworkVariants[identity] = variants;
  }
  return warm;
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
  final double? coverAspectRatio;
  final int? maxDecodeEdge;

  const _VersionedFileImage(
    super.file,
    this.revision, {
    this.coverAspectRatio,
    this.maxDecodeEdge,
  });

  @override
  bool operator ==(Object other) =>
      other is _VersionedFileImage &&
      other.revision == revision &&
      other.coverAspectRatio == coverAspectRatio &&
      other.maxDecodeEdge == maxDecodeEdge &&
      super == other;

  @override
  int get hashCode =>
      Object.hash(super.hashCode, revision, coverAspectRatio, maxDecodeEdge);
}

/// Reuses the SDK's asynchronous file loading, key and error eviction. Only
/// target geometry changes; pixel work stays in the engine's native decoder.
class _CoverResizeImage extends ResizeImage {
  const _CoverResizeImage(super.imageProvider, int edge)
    : super(width: edge, height: edge, policy: ResizeImagePolicy.fit);

  @override
  ImageStreamCompleter loadImage(
    ResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    final source = imageProvider as _VersionedFileImage;
    final ratio = source.coverAspectRatio!;
    final boxWidth = ratio >= 1 ? width!.toDouble() : width! * ratio;
    final boxHeight = ratio >= 1 ? height! / ratio : height!.toDouble();
    return super.loadImage(
      key,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final scale = math.min(
            1.0,
            math.min(
              source.maxDecodeEdge! / math.max(intrinsicWidth, intrinsicHeight),
              math.max(boxWidth / intrinsicWidth, boxHeight / intrinsicHeight),
            ),
          );
          return ui.TargetImageSize(
            width: math.max(1, (intrinsicWidth * scale).ceil()),
            height: math.max(1, (intrinsicHeight * scale).ceil()),
          );
        },
      ),
    );
  }
}
