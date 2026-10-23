import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/logger.dart';
import '../data/poster_cache.dart';
import 'glass.dart';
import 'theme/library_styles.dart';

/// Decode only a cover-sized image; scrolling never loads a full-resolution poster.
class MediaArtwork extends StatefulWidget {
  final String poster;
  final String? thumbnail;
  final PosterCache? cache;
  final Widget? placeholder;
  final BoxFit fit;

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
    this.onRequestPreview,
  });
  @override
  State<MediaArtwork> createState() => _MediaArtworkState();
}

class _MediaArtworkState extends State<MediaArtwork> {
  String? _reportedFailure;
  bool _posterInvalidated = false;
  Future<File?>? _poster;
  Timer? _posterRetry;
  bool _previewPending = false, _previewFrameScheduled = false;
  bool _imageLoadingAllowed = false;
  final _scrollPositions = <ScrollPosition>{};
  ModalRoute<dynamic>? _route;
  Animation<double>? _routeTransition;

  @override
  void initState() {
    super.initState();
    _previewPending = widget.onRequestPreview != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final transition = _route?.secondaryAnimation;
    if (transition != _routeTransition) {
      _routeTransition?.removeStatusListener(_routeSettled);
      _routeTransition = transition;
      _routeTransition?.addStatusListener(_routeSettled);
    }
    final positions = <ScrollPosition>{};
    for (final axis in Axis.values) {
      final position = Scrollable.maybeOf(context, axis: axis)?.position;
      if (position != null) positions.add(position);
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
      Scrollable.recommendDeferredLoadingForContext(
        context,
        axis: Axis.vertical,
      ) ||
      Scrollable.recommendDeferredLoadingForContext(
        context,
        axis: Axis.horizontal,
      );

  void _retryLoading() {
    _posterRetry ??= Timer(const Duration(milliseconds: 80), () {
      _posterRetry = null;
      if (!mounted) return;
      _loadArtwork();
    });
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
    if ((!needsPoster && !_previewPending && _imageLoadingAllowed) ||
        _previewFrameScheduled) {
      return;
    }
    _previewFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _previewFrameScheduled = false;
      if (!mounted || !_visible) return;
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
        final poster = widget.cache!.load(widget.poster);
        setState(() {
          _poster = poster;
        });
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
    if (oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.poster != widget.poster) {
      _imageLoadingAllowed = false;
    }
    if (oldWidget.thumbnail != widget.thumbnail) _reportedFailure = null;
    if (oldWidget.poster != widget.poster || oldWidget.cache != widget.cache) {
      _reportedFailure = null;
      _posterInvalidated = false;
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

  bool _canLoadImage(File file, int width) {
    if (_imageLoadingAllowed) return true;
    var cached = false;
    // FileImage and ResizeImage return synchronous keys. Use the resolved key,
    // not the provider object, to reuse decoded/pending textures while flinging.
    ResizeImage(
      FileImage(file),
      width: width,
    ).obtainKey(ImageConfiguration.empty).then((key) {
      cached = PaintingBinding.instance.imageCache.statusForKey(key).tracked;
    });
    return cached;
  }

  @override
  void dispose() {
    _posterRetry?.cancel();
    _routeTransition?.removeStatusListener(_routeSettled);
    for (final position in _scrollPositions) {
      position.removeListener(_scrollChanged);
      position.isScrollingNotifier.removeListener(_scrollChanged);
    }
    super.dispose();
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
    Widget frame(int decodeWidth) =>
        thumbnail == null ||
            thumbnail.isEmpty ||
            !_canLoadImage(File(thumbnail), decodeWidth)
        ? placeholder
        : Image.file(
            File(thumbnail),
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: decodeWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, error, _) {
              _reportFailure(error);
              return placeholder;
            },
          );
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
              : 640 / pixelRatio;
          final decodeWidth = ((edge * pixelRatio / 64).ceil() * 64).clamp(
            64,
            640,
          );
          return poster.isNotEmpty
              ? FutureBuilder<File?>(
                  key: ValueKey(poster),
                  future: _poster,
                  initialData: widget.cache?.resolvedFile(poster),
                  builder: (_, snapshot) =>
                      snapshot.data == null ||
                          !_canLoadImage(snapshot.data!, decodeWidth)
                      ? frame(decodeWidth)
                      : Image.file(
                          snapshot.data!,
                          fit: fit,
                          width: double.infinity,
                          height: double.infinity,
                          cacheWidth: decodeWidth,
                          filterQuality: FilterQuality.low,
                          gaplessPlayback: true,
                          errorBuilder: (_, error, _) {
                            if (!_posterInvalidated) {
                              _posterInvalidated = true;
                              unawaited(widget.cache?.invalidate(poster));
                            }
                            return frame(decodeWidth);
                          },
                        ),
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
