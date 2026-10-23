import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/logger.dart';
import '../data/poster_cache.dart';
import 'artwork_scroll_scope.dart';
import 'glass.dart';
import 'theme/library_styles.dart';

/// Decode only a cover-sized image; scrolling never loads a full-resolution poster.
class MediaArtwork extends StatefulWidget {
  final String poster;
  final String? thumbnail;
  final PosterCache? cache;
  final Widget? placeholder;
  final BoxFit fit;

  /// Bounds decoding in physical pixels. Fullscreen viewers can opt into a
  /// larger image while their first frame reuses the already visible cover.
  final int maxDecodeEdge;

  /// Runs after layout, when the surrounding scrollables allow expensive work.
  /// A later widget update retries a previously full preview queue.
  final VoidCallback? onRequestPreview;
  const MediaArtwork({
    super.key,
    this.poster = '',
    this.thumbnail,
    this.cache,
    this.placeholder,
    this.fit = BoxFit.cover,
    this.maxDecodeEdge = 640,
    this.onRequestPreview,
  }) : assert(maxDecodeEdge >= 64);
  @override
  State<MediaArtwork> createState() => _MediaArtworkState();
}

class _MediaArtworkState extends State<MediaArtwork> {
  String? _reportedFailure;
  bool _posterInvalidated = false;
  bool _repairingPoster = false;
  int _posterRevision = 0;
  Listenable? _cacheCapacity;
  Future<File?>? _poster;
  Timer? _posterRetry;
  bool _previewPending = false, _previewFrameScheduled = false;
  bool _imageLoadingAllowed = false;
  bool _active = true;
  ValueListenable<bool>? _scrollActivity;
  final _scrollPositions = <ScrollPosition>{};
  ModalRoute<dynamic>? _route;
  Animation<double>? _routeTransition;

  @override
  void initState() {
    super.initState();
    _previewPending = widget.onRequestPreview != null;
    widget.cache?.changes.addListener(_cacheChanged);
  }

  void _cacheChanged() {
    final change = widget.cache?.changes.value;
    if (!mounted || change == null || change.url != widget.poster) return;
    void changed() {
      _poster = change.file == null ? null : SynchronousFuture(change.file);
      _posterRevision++;
    }

    if (_active) {
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
    _active = TickerMode.valuesOf(context).enabled;
    if (!_active) {
      _posterRetry?.cancel();
      _posterRetry = null;
    }
    _route = ModalRoute.of(context);
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

  void _retryLoading() {
    // The shared scope will wake every pending cover once when the region is
    // idle. Avoid a timer per card while wheel/trackpad events keep arriving.
    if (!_active || _scrollActivity?.value == true) return;
    _posterRetry ??= Timer(const Duration(milliseconds: 80), () {
      _posterRetry = null;
      if (!mounted) return;
      _loadArtwork();
    });
  }

  void _activityChanged() {
    if (_scrollActivity?.value == true) {
      _posterRetry?.cancel();
      _posterRetry = null;
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
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      _loadArtwork();
    }
  }

  bool get _visible {
    if (_route?.isCurrent == false) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var visible = box.localToGlobal(Offset.zero) & box.size;
    final screen = MediaQuery.maybeSizeOf(context);
    if (screen != null && !screen.isEmpty) {
      visible = visible.intersect(Offset.zero & screen);
    }
    RenderObject? ancestor = box.parent;
    while (!visible.isEmpty && ancestor != null) {
      if (ancestor is RenderAbstractViewport) {
        visible = visible.intersect(
          MatrixUtils.transformRect(
            ancestor.getTransformTo(null),
            ancestor.paintBounds,
          ),
        );
      }
      ancestor = ancestor.parent;
    }
    return !visible.isEmpty;
  }

  void _loadArtwork() {
    final needsPoster =
        _poster == null && widget.cache != null && widget.poster.isNotEmpty;
    if (!_active ||
        _repairingPoster ||
        _scrollActivity?.value == true ||
        (!needsPoster && !_previewPending && _imageLoadingAllowed) ||
        _previewFrameScheduled) {
      return;
    }
    _previewFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _previewFrameScheduled = false;
      if (!mounted || !_active || _scrollActivity?.value == true || !_visible) {
        return;
      }
      // Cached sliver children are laid out before they enter the viewport.
      // Request expensive artwork only for the cards the user can see.
      if (_deferLoading) {
        _retryLoading();
        return;
      }
      _posterRetry?.cancel();
      _posterRetry = null;
      if (!_imageLoadingAllowed) setState(() => _imageLoadingAllowed = true);
      if (_poster == null && widget.cache != null && widget.poster.isNotEmpty) {
        final cache = widget.cache!;
        final poster = cache.loadVisible(widget.poster);
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
          });
        }
      }
      if (_previewPending) {
        _previewPending = false;
        widget.onRequestPreview?.call();
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
        oldWidget.poster != widget.poster) {
      _imageLoadingAllowed = false;
    }
    if (oldWidget.thumbnail != widget.thumbnail) _reportedFailure = null;
    if (oldWidget.poster != widget.poster || oldWidget.cache != widget.cache) {
      _reportedFailure = null;
      _posterInvalidated = false;
      _repairingPoster = false;
      _cacheCapacity?.removeListener(_loadArtwork);
      _cacheCapacity = null;
      _posterRetry?.cancel();
      _posterRetry = null;
      _poster = null;
    }
    if (oldWidget.poster != widget.poster ||
        oldWidget.thumbnail != widget.thumbnail ||
        (widget.thumbnail == null &&
            oldWidget.onRequestPreview != widget.onRequestPreview)) {
      _previewPending = widget.onRequestPreview != null;
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
    if (cached) return true;
    if (!_active) return false;
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
    _posterRetry?.cancel();
    widget.cache?.changes.removeListener(_cacheChanged);
    _cacheCapacity?.removeListener(_loadArtwork);
    _scrollActivity?.removeListener(_activityChanged);
    _routeTransition?.removeStatusListener(_routeSettled);
    for (final position in _scrollPositions) {
      position.removeListener(_scrollChanged);
      position.isScrollingNotifier.removeListener(_scrollChanged);
    }
    super.dispose();
  }

  void _repairPoster(String poster, File file) {
    final cache = widget.cache;
    if (_posterInvalidated || cache == null) return;
    _posterInvalidated = true;
    _repairingPoster = true;
    // A stale or corrupt disk entry must be evicted from both caches. Repair
    // once per mounted cover, after the error builder has finished its frame.
    scheduleMicrotask(() async {
      await _evictArtworkImages(file);
      await cache.invalidate(poster, failedFile: file, retryImmediately: true);
      if (!mounted || widget.poster != poster || widget.cache != cache) return;
      setState(() {
        _poster = null;
        _repairingPoster = false;
        _posterRevision++;
      });
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
    Widget frame(int decodeWidth) {
      if (thumbnail == null || thumbnail.isEmpty) return placeholder;
      final provider = _imageFor(File(thumbnail), decodeWidth);
      return !_canLoadImage(provider)
          ? placeholder
          : Image(
              image: provider,
              fit: fit,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
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
          final decodeWidth = ((edge * pixelRatio / 64).ceil() * 64).clamp(
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
                        ? frame(decodeWidth)
                        : Image(
                            image: provider,
                            fit: fit,
                            width: double.infinity,
                            height: double.infinity,
                            filterQuality: FilterQuality.low,
                            gaplessPlayback: true,
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
