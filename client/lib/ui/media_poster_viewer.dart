import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/poster_cache.dart';
import '../data/poster_url.dart';
import 'media_artwork.dart';

Future<void> showMediaPosterViewer(
  BuildContext context, {
  required PosterCache cache,
  required String poster,
  required String title,
}) => showGeneralDialog<void>(
  context: context,
  barrierColor: Colors.black,
  transitionDuration: const Duration(milliseconds: 160),
  pageBuilder: (_, _, _) =>
      _PosterViewer(cache: cache, poster: poster, title: title),
);

class _PosterViewer extends StatefulWidget {
  final PosterCache cache;
  final String poster, title;

  const _PosterViewer({
    required this.cache,
    required this.poster,
    required this.title,
  });

  @override
  State<_PosterViewer> createState() => _PosterViewerState();
}

class _PosterViewerState extends State<_PosterViewer> {
  final _transform = TransformationController();
  late final _originalPoster = originalPosterUrl(widget.poster);
  Offset _doubleTapPosition = Offset.zero;
  double _decodeScale = 1;

  void _updateDecodeScale() {
    // Keep the sharpest requested texture when zooming back out. Integer
    // magnification buckets bound variants and avoid work during the gesture.
    final scale = _transform.value
        .getMaxScaleOnAxis()
        .clamp(1.0, 5.0)
        .ceilToDouble();
    if (scale > _decodeScale) setState(() => _decodeScale = scale);
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        _doubleTapPosition.dx * (1 - scale),
        _doubleTapPosition.dy * (1 - scale),
        0,
      );
    _updateDecodeScale();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).pop(),
    },
    child: Focus(
      autofocus: true,
      child: Material(
        key: const ValueKey('media-poster-viewer'),
        color: Colors.black,
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Semantics(
                label: '${widget.title}封面',
                image: true,
                child: GestureDetector(
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: _toggleZoom,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: 5,
                    onInteractionEnd: (_) => _updateDecodeScale(),
                    child: SizedBox.expand(
                      child: MediaArtwork(
                        cache: widget.cache,
                        poster: _originalPoster,
                        fit: BoxFit.contain,
                        maxDecodeEdge: 4096,
                        decodeScale: _decodeScale,
                        loadWhileScrolling: true,
                        placeholder: _originalPoster == widget.poster
                            ? _placeholder
                            : MediaArtwork(
                                cache: widget.cache,
                                poster: widget.poster,
                                fit: BoxFit.contain,
                                loadWhileScrolling: true,
                                placeholder: _placeholder,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  tooltip: '关闭封面',
                  color: Colors.white,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

const _placeholder = Center(
  child: Icon(Icons.image_outlined, color: Colors.white54, size: 48),
);
