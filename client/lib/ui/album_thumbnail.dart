import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/album_images.dart';
import '../sources/source.dart';
import 'artwork_lifecycle.dart';
import 'glass.dart';
import 'media_artwork.dart';

/// Shares artwork's visible/idle admission and bounded native image decoding.
/// The worker returns compressed disk paths; native decoding stays bounded by
/// the requested display size and never transfers pixel buffers to Dart.
class AlbumThumbnail extends StatefulWidget {
  final AlbumImageService service;
  final SourceEntry entry;
  final int edge;
  final bool folder, hideHidden;
  final Set<String> extensions, excludedExtensions;
  final Widget? placeholder;
  final Widget? loadingPlaceholder;
  final BoxFit fit;
  final ValueChanged<AlbumImageResult>? onLoaded;
  final SourceEntry? cover;

  /// A prepared result for this entry, such as the wall's resident preview.
  final AlbumImageResult? initialResult;

  /// The full-screen viewer opts in. Wall cells keep static placeholders.
  final bool showLoading;

  const AlbumThumbnail({
    super.key,
    required this.service,
    required this.entry,
    this.edge = 512,
    this.folder = false,
    this.hideHidden = true,
    this.extensions = const {},
    this.excludedExtensions = const {},
    this.placeholder,
    this.loadingPlaceholder,
    this.fit = BoxFit.cover,
    this.onLoaded,
    this.cover,
    this.initialResult,
    this.showLoading = false,
  });

  @override
  State<AlbumThumbnail> createState() => _AlbumThumbnailState();
}

class _AlbumThumbnailState extends State<AlbumThumbnail> {
  AlbumImageHandle? _request;
  AlbumImageResult? _result, _reportedResult;
  String? _residentPath;
  int _residentEdge = 0;
  bool _retainingEvictedFile = false;
  int _generation = 0;
  int _identityRevision = 0;
  int _serviceRevision = 0;
  int _priority = 0;
  int _resolvedEdge = 0;
  int _retryCount = 0;
  bool _retryWaiting = false, _routeCurrent = true;
  Timer? _retryTimer;
  ValueListenable<TickerModeData>? _tickerMode;

  void _previewPriority(int value) {
    if (value < 0) return;
    _priority = value;
    _request?.updatePriority?.call(value);
  }

  @override
  void initState() {
    super.initState();
    _serviceRevision = widget.service.revision;
    _result = _preparedResult();
    widget.service.addListener(_serviceChanged);
    ArtworkLifecycle.instance.addListener(_retryActivity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode?.removeListener(_retryActivity);
    _tickerMode = TickerMode.getValuesNotifier(context)
      ..addListener(_retryActivity);
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _retryActivity();
  }

  void _retryActivity() {
    final active =
        mounted &&
        ArtworkLifecycle.instance.value &&
        widget.service.active &&
        (_tickerMode?.value.enabled ?? false) &&
        _routeCurrent;
    if (!active) {
      _retryTimer?.cancel();
      _retryTimer = null;
    } else if (_retryWaiting && _retryTimer == null) {
      _retryTimer = Timer(
        Duration(milliseconds: _retryCount <= 1 ? 250 : 1000),
        () {
          _retryTimer = null;
          if (!mounted || !_retryWaiting) return;
          setState(() {
            _retryWaiting = false;
            // The new artwork first passes its usual visible/scroll admission
            // before requesting any source or native decode work.
            _identityRevision++;
          });
        },
      );
    }
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryWaiting = false;
    _retryCount = 0;
  }

  void _imageFailed(String path, Object error) {
    if (!mounted || _result?.path != path) return;
    _retry(path);
  }

  void _imageFrame(String path) {
    if (mounted && _result?.path == path) {
      _residentPath = path;
      _residentEdge = widget.edge;
    }
  }

  void _imageReady(String path) {
    if (mounted && _result?.path == path) {
      _resetRetry();
    }
  }

  void _retry(String? failedPath) {
    if (_retryWaiting || _retryCount >= 2) return;
    _retryCount++;
    widget.service.invalidatePrepared(
      widget.entry,
      failedPath: failedPath,
      targetEdge: widget.edge,
      folder: widget.folder,
      extensions: widget.extensions,
      excludedExtensions: widget.excludedExtensions,
      hideHidden: widget.hideHidden,
      cover: widget.cover,
    );
    setState(() {
      _retryWaiting = true;
      _result = null;
      _residentPath = null;
      _residentEdge = 0;
      _retainingEvictedFile = false;
      _reportedResult = null;
      _resolvedEdge = 0;
      _identityRevision++;
    });
    _retryActivity();
  }

  AlbumImageResult? _preparedResult() {
    AlbumImageResult? ready(AlbumImageResult? result) =>
        result?.path != null && !widget.service.wasEvicted(result!.path!)
        ? result
        : null;
    // An evicted caller preview must not hide a newer prepared result.
    return ready(widget.initialResult) ??
        ready(
          widget.service.peekPrepared(
            widget.entry,
            targetEdge: widget.edge,
            folder: widget.folder,
            extensions: widget.extensions,
            excludedExtensions: widget.excludedExtensions,
            hideHidden: widget.hideHidden,
            cover: widget.cover,
          ),
        ) ??
        (widget.folder || widget.entry.directory
            ? null
            : ready(widget.service.peek(widget.entry)));
  }

  void _serviceChanged() {
    _retryActivity();
    if (!mounted || !widget.service.active) return;
    final invalidated =
        _result?.path != null && widget.service.wasEvicted(_result!.path!);
    if (widget.service.revision == _serviceRevision) {
      if (!invalidated) {
        // Eviction bookkeeping is bounded. Forgetting an old marker is not
        // evidence that the file has been restored; our next prepared result
        // releases this retained-frame state after an explicit size upgrade.
        return;
      }
      if (_result?.path == _residentPath) {
        // Evicting a disk cache entry does not change this media. Replacing
        // MediaArtwork here discarded its live Image and caused the visible
        // wall to reread the evicted source, often evicting another live cell.
        if (!_retainingEvictedFile) {
          setState(() => _retainingEvictedFile = true);
        }
        return;
      }
    }
    _resetRetry();
    _serviceRevision = widget.service.revision;
    _generation++;
    _identityRevision++;
    _request?.cancel();
    _request = null;
    _reportedResult = null;
    _residentPath = null;
    _residentEdge = 0;
    _retainingEvictedFile = false;
    setState(() => _result = null);
  }

  @override
  void didUpdateWidget(covariant AlbumThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_serviceChanged);
      _serviceRevision = widget.service.revision;
      widget.service.addListener(_serviceChanged);
    }
    if (oldWidget.service != widget.service ||
        oldWidget.entry.path != widget.entry.path ||
        oldWidget.entry.size != widget.entry.size ||
        oldWidget.entry.modified != widget.entry.modified ||
        oldWidget.folder != widget.folder ||
        oldWidget.hideHidden != widget.hideHidden ||
        oldWidget.cover?.path != widget.cover?.path ||
        oldWidget.cover?.size != widget.cover?.size ||
        oldWidget.cover?.modified != widget.cover?.modified ||
        !_same(oldWidget.extensions, widget.extensions) ||
        !_same(oldWidget.excludedExtensions, widget.excludedExtensions)) {
      _generation++;
      _resetRetry();
      _identityRevision++;
      _request?.cancel();
      _request = null;
      _reportedResult = null;
      _residentPath = null;
      _residentEdge = 0;
      _retainingEvictedFile = false;
      _result = _preparedResult();
      _resolvedEdge = 0;
    } else if (oldWidget.edge != widget.edge) {
      _generation++;
      _request?.cancel();
      _request = null;
    } else if (oldWidget.initialResult != widget.initialResult &&
        widget.initialResult?.path != null &&
        !widget.service.wasEvicted(widget.initialResult!.path!)) {
      _result = widget.initialResult;
    }
  }

  bool _same(Set<String> a, Set<String> b) =>
      identical(a, b) || a.length == b.length && a.containsAll(b);

  Future<bool> _load() async {
    if (_retryWaiting) return false;
    if (_request != null) return true;
    if (_result != null &&
        (_retainingEvictedFile
            ? widget.edge <= _residentEdge
            : _result!.encodedSource || _resolvedEdge >= widget.edge)) {
      _reportLoaded(_result!);
      return true;
    }
    final generation = _generation;
    final edge = widget.edge;
    final request = _request = widget.service.load(
      widget.entry,
      targetEdge: edge,
      folder: widget.folder,
      extensions: widget.extensions,
      excludedExtensions: widget.excludedExtensions,
      hideHidden: widget.hideHidden,
      cover: widget.cover,
      priority: _priority,
    );
    final result = await request.future;
    if (!mounted || generation != _generation) return true;
    _request = null;
    if (result.deferred) return false;
    if (result.cancelled) return false;
    setState(() {
      _resolvedEdge = edge;
      if (result.path != null || _result?.path == null) {
        _result = result;
        _retainingEvictedFile =
            result.path != null &&
            result.path == _residentPath &&
            widget.service.wasEvicted(result.path!);
      }
    });
    _reportLoaded(result);
    if (result.error != null) _retry(null);
    return true;
  }

  void _reportLoaded(AlbumImageResult result) {
    if (identical(_reportedResult, result)) return;
    _reportedResult = result;
    widget.onLoaded?.call(result);
  }

  @override
  void dispose() {
    _generation++;
    _request?.cancel();
    _retryTimer?.cancel();
    _tickerMode?.removeListener(_retryActivity);
    ArtworkLifecycle.instance.removeListener(_retryActivity);
    widget.service.removeListener(_serviceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaArtwork(
    key: ValueKey(_identityRevision),
    thumbnail: _result?.path,
    thumbnailDecodedFallback: _result?.decodedFallbackPath,
    thumbnailFileAvailable: !_retainingEvictedFile,
    fit: widget.fit,
    maxDecodeEdge: widget.edge.clamp(64, 4096),
    loadWhileScrolling: true,
    previewWhileScrolling: true,
    onPreviewPriority: _result == null ? _previewPriority : null,
    placeholder:
        widget.placeholder ??
        ColoredBox(
          color: Colors.white,
          child: Center(
            child: Icon(
              widget.folder || widget.entry.directory
                  ? Icons.folder_outlined
                  : Icons.image_outlined,
              color: Colors.black26,
            ),
          ),
        ),
    tryRequestPreview: _load,
    previewCapacity: widget.service.capacity,
    previewRevision: widget.edge,
    onThumbnailError: _imageFailed,
    onThumbnailReady: _imageReady,
    onThumbnailFrame: _imageFrame,
    loadingPlaceholder: widget.showLoading && _result?.error == null
        ? Stack(
            fit: StackFit.expand,
            children: [
              ?widget.loadingPlaceholder,
              _AlbumLoading(service: widget.service),
            ],
          )
        : null,
  );
}

/// One ticker for the visible viewer, including its native decode wait. The
/// lifecycle listener stops it synchronously even if Android draws no frame.
class _AlbumLoading extends StatefulWidget {
  final AlbumImageService service;
  const _AlbumLoading({required this.service});

  @override
  State<_AlbumLoading> createState() => _AlbumLoadingState();
}

class _AlbumLoadingState extends State<_AlbumLoading>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  ValueListenable<TickerModeData>? _tickerMode;
  Timer? _delay;
  bool _visible = false, _motion = true;

  @override
  void initState() {
    super.initState();
    ArtworkLifecycle.instance.addListener(_activityChanged);
    widget.service.addListener(_activityChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode?.removeListener(_activityChanged);
    _tickerMode = TickerMode.getValuesNotifier(context)
      ..addListener(_activityChanged);
    _motion = MotionScope.enabledOf(context);
    _activityChanged();
  }

  @override
  void didUpdateWidget(covariant _AlbumLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_activityChanged);
      widget.service.addListener(_activityChanged);
    }
    _activityChanged();
  }

  void _activityChanged() {
    final active =
        ArtworkLifecycle.instance.value &&
        widget.service.active &&
        (_tickerMode?.value.enabled ?? false);
    if (!active) {
      _delay?.cancel();
      _delay = null;
      _animation.stop();
      return;
    }
    if (!_visible) {
      _delay ??= Timer(const Duration(milliseconds: 180), () {
        _delay = null;
        if (!mounted ||
            !ArtworkLifecycle.instance.value ||
            !widget.service.active ||
            _tickerMode?.value.enabled != true) {
          return;
        }
        setState(() => _visible = true);
        _activityChanged();
      });
      return;
    }
    if (_motion && !_animation.isAnimating) _animation.repeat();
    if (!_motion) _animation.stop();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _tickerMode?.removeListener(_activityChanged);
    ArtworkLifecycle.instance.removeListener(_activityChanged);
    widget.service.removeListener(_activityChanged);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : Center(
          child: RepaintBoundary(
            child: Semantics(
              label: '正在加载图片',
              child: SizedBox.square(
                dimension: 28,
                child: RotationTransition(
                  key: const ValueKey('album-image-loading'),
                  turns: _animation,
                  child: const CircularProgressIndicator(
                    value: .7,
                    strokeWidth: 2.5,
                    color: Color(0xff888888),
                  ),
                ),
              ),
            ),
          ),
        );
}
