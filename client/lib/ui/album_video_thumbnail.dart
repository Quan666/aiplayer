import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/network.dart';
import '../data/app_model.dart';
import '../data/media_preview_persistence.dart';
import '../sources/source.dart';
import 'artwork_lifecycle.dart';
import 'artwork_scroll_scope.dart';
import 'media_artwork.dart';

/// Reuses the one-decoder preview queue without importing personal videos.
/// Only mounted, visible, idle cells request capture. Leaving the page or
/// starting a scroll releases their pending work immediately.
class AlbumVideoThumbnail extends StatefulWidget {
  final AppModel model;
  final String sourceId;
  final SourceEntry entry;
  final int edge;
  final bool firstFrame;
  final bool originalResolution;
  final BoxFit fit;
  final String? initialThumbnail;
  final ValueChanged<String?>? onThumbnailChanged;
  final bool active;
  final ValueListenable<bool>? activity;
  final Widget? placeholder;
  final VoidCallback? onVisibleIdle;
  final Object? visibleIdleRevision;
  const AlbumVideoThumbnail({
    super.key,
    required this.model,
    required this.sourceId,
    required this.entry,
    required this.edge,
    this.firstFrame = true,
    this.originalResolution = false,
    this.fit = BoxFit.cover,
    this.initialThumbnail,
    this.onThumbnailChanged,
    this.active = true,
    this.activity,
    this.placeholder,
    this.onVisibleIdle,
    this.visibleIdleRevision,
  });

  @override
  State<AlbumVideoThumbnail> createState() => _AlbumVideoThumbnailState();
}

class _AlbumVideoThumbnailState extends State<AlbumVideoThumbnail> {
  SourcePreviewBinding? _binding;
  late String? _thumbnail = widget.initialThumbnail;
  String? _thumbnailOwnerId;
  Object? _revision;
  bool _visible = true, _dirty = true, _requested = false, _reading = false;
  int _attempt = 0;
  String? _failedThumbnail;
  int _thumbnailRepairs = 0;
  int _thumbnailRevision = 0;
  bool _repairingThumbnail = false;
  CancelToken? _readCancel;
  ValueListenable<bool>? _scrolling;
  bool get _active =>
      widget.active &&
      widget.activity?.value != false &&
      _visible &&
      ArtworkLifecycle.instance.value;
  bool get _canRequest => _active && _scrolling?.value != true;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
    ArtworkLifecycle.instance.addListener(_activity);
    widget.activity?.addListener(_activity);
  }

  void _refresh() {
    if (!_canRequest || _repairingThumbnail) {
      _dirty = true;
      return;
    }
    final revision = widget.model.sourcePreviewRevision;
    if (revision == _revision && !_dirty) return;
    if (_reading) {
      _dirty = true;
      return;
    }
    _reading = true;
    _dirty = false;
    final token = _readCancel = CancelToken();
    final ticket = _attempt;
    final owner = widget.model;
    final entry = widget.entry, source = widget.sourceId;
    unawaited(() async {
      try {
        final binding = await owner.readSourceMediaPreview(
          source,
          entry,
          cancel: token,
          albumCover: widget.firstFrame,
          originalResolution: widget.originalResolution,
        );
        token.check();
        if (!mounted ||
            !_canRequest ||
            ticket != _attempt ||
            owner != widget.model) {
          return;
        }
        if (revision != owner.sourcePreviewRevision) {
          _dirty = true;
          return;
        }
        _revision = revision;
        _dirty = false;
        final previousThumbnail = _thumbnail;
        final validatingInitial =
            _binding == null &&
            widget.initialThumbnail != null &&
            _thumbnail == widget.initialThumbnail;
        setState(() {
          _binding = binding;
          if (validatingInitial &&
              binding.thumbnail != null &&
              _failedThumbnail == binding.thumbnail) {
            // The file may have been repaired while the initial binding was
            // pending. Let the image provider retry that same prepared path.
            _thumbnailRevision++;
          }
          // A cold upgrade or revision recheck keeps the prepared frame for
          // this identity until its replacement is available.
          if (binding.thumbnail != null) {
            _thumbnail = binding.thumbnail;
            _thumbnailOwnerId = binding.thumbnailId;
          } else if (!widget.originalResolution) {
            // A recycled grid seed is provisional. A completed lookup proving
            // it missing must revoke it (and the parent's seed), even when its
            // decoded pixels remain warm. The viewer may keep its small cover
            // while requesting an original-resolution upgrade.
            _thumbnail = null;
            _thumbnailOwnerId = null;
          }
        });
        // Revalidate a retained caller path too, so its revision can advance
        // without throwing away the same image on the next directory visit.
        if (binding.thumbnail != null || _thumbnail != previousThumbnail) {
          widget.onThumbnailChanged?.call(_thumbnail);
        }
      } on Cancelled {
        // Visibility/model changes revoke this lookup without new frames.
      } catch (_) {
        // Keep the prepared frame; retry on a later revision or visibility event.
        _revision = revision;
      } finally {
        _reading = false;
        if (identical(_readCancel, token)) _readCancel = null;
        if (mounted && _canRequest && _dirty) _refresh();
      }
    }());
  }

  void _changed() {
    final changedId = widget.model.sourcePreviewNotificationId;
    final binding = _binding;
    if (changedId != null &&
        binding != null &&
        changedId != binding.id &&
        changedId != binding.thumbnailId &&
        changedId != binding.browseId) {
      return;
    }
    if (!_active) {
      _dirty = true;
      return;
    }
    _refresh();
  }

  void _cancel() {
    _attempt++;
    _readCancel?.cancel();
    _dirty = true;
    if (_requested) {
      _requested = false;
      widget.model.cancelSourceMediaPreview(
        widget.sourceId,
        widget.entry.path,
        binding: _binding,
        albumCover: widget.firstFrame,
        originalResolution: widget.originalResolution,
      );
    }
  }

  void _activity() {
    if (!_canRequest) {
      _cancel();
    } else if (mounted) {
      _refresh();
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final scrolling = ArtworkScrollScope.maybeOf(context);
    if (_scrolling != scrolling) {
      _scrolling?.removeListener(_activity);
      _scrolling = scrolling;
      _scrolling?.addListener(_activity);
    }
    if (!_canRequest) {
      _cancel();
    } else {
      _refresh();
    }
  }

  @override
  void didUpdateWidget(AlbumVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity != widget.activity) {
      oldWidget.activity?.removeListener(_activity);
      widget.activity?.addListener(_activity);
    }
    final contentChanged =
        oldWidget.model != widget.model ||
        oldWidget.firstFrame != widget.firstFrame ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.entry.path != widget.entry.path ||
        oldWidget.entry.size != widget.entry.size ||
        oldWidget.entry.modified != widget.entry.modified;
    if (contentChanged ||
        oldWidget.originalResolution != widget.originalResolution) {
      _attempt++;
      _readCancel?.cancel();
      if (_requested) {
        oldWidget.model.cancelSourceMediaPreview(
          oldWidget.sourceId,
          oldWidget.entry.path,
          binding: _binding,
          albumCover: oldWidget.firstFrame,
          originalResolution: oldWidget.originalResolution,
        );
      }
      _requested = false;
      oldWidget.model.removeListener(_changed);
      widget.model.addListener(_changed);
      _binding = null;
      if (contentChanged) {
        _thumbnail = widget.initialThumbnail;
        _thumbnailOwnerId = null;
        _thumbnailRevision++;
      }
      _failedThumbnail = null;
      _thumbnailRepairs = 0;
      _repairingThumbnail = false;
      _revision = null;
      _dirty = true;
    }
    if (!contentChanged &&
        widget.initialThumbnail != null &&
        widget.initialThumbnail != oldWidget.initialThumbnail &&
        (_thumbnail == null || _thumbnail == oldWidget.initialThumbnail)) {
      // A neighbor lookup may finish after this element mounts. Accept that
      // prepared frame even when playback has suspended optional capture, but
      // never replace a newer binding with an older caller fallback.
      _thumbnail = widget.initialThumbnail;
      _thumbnailOwnerId = null;
    }
    if (!_canRequest) {
      _cancel();
    } else {
      _refresh();
    }
  }

  Future<bool> _request() async {
    final binding = _binding;
    if (!_canRequest || binding == null) return false;
    if (!binding.needsCapture) return true;
    final accepted = widget.model.tryEnsureSourceMediaPreview(
      widget.sourceId,
      widget.entry,
      binding: binding,
    );
    _requested |= accepted;
    return accepted;
  }

  void _thumbnailError(String path, Object error) {
    if (!mounted || path != _thumbnail || error is! FileSystemException) {
      return;
    }
    if (_failedThumbnail != path) {
      _failedThumbnail = path;
      _thumbnailRepairs = 0;
    }
    // A filesystem read failure can race a newer binding lookup or a cover
    // commit. Recheck existence through the existing worker before requesting
    // capture; never delete the source video or a newly published cache file.
    // A repeatedly disappearing cache gets two repairs per mounted identity.
    if (_thumbnailRepairs >= 2) return;
    _thumbnailRepairs++;
    final owner = widget.model;
    final binding = _binding;
    if (binding == null) return;
    final thumbnailId = _thumbnailOwnerId ?? binding.thumbnailId;
    final entry = widget.entry;
    final source = widget.sourceId;
    _repairingThumbnail = true;
    _attempt++;
    _readCancel?.cancel();
    _revision = null;
    _dirty = true;
    setState(() {
      _binding = null;
      _thumbnail = null;
    });
    widget.onThumbnailChanged?.call(null);
    unawaited(
      owner.retryMissingMediaPreview(thumbnailId, path, error).then((_) {
        if (!mounted ||
            owner != widget.model ||
            source != widget.sourceId ||
            entry.path != widget.entry.path ||
            entry.size != widget.entry.size ||
            entry.modified != widget.entry.modified) {
          return;
        }
        _repairingThumbnail = false;
        _thumbnailRevision++;
        _refresh();
      }),
    );
  }

  void _thumbnailReady(String path) {
    if (!mounted || path != _thumbnail) return;
    _failedThumbnail = null;
    _thumbnailRepairs = 0;
    final binding = _binding;
    if (binding != null) {
      widget.model.mediaPreviewReady(
        _thumbnailOwnerId ?? binding.thumbnailId,
        path,
      );
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    ArtworkLifecycle.instance.removeListener(_activity);
    widget.activity?.removeListener(_activity);
    _scrolling?.removeListener(_activity);
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaArtwork(
    thumbnail: _thumbnail,
    thumbnailRevision: _thumbnailRevision,
    fit: widget.fit,
    maxDecodeEdge: widget.edge,
    loadWhileScrolling: true,
    previewCapacity: widget.model.sourcePreviewCapacity,
    previewRevision: (
      _binding?.id,
      _binding?.needsCapture,
      _attempt,
      _thumbnailRevision,
      _canRequest,
    ),
    onThumbnailError: _thumbnailError,
    onThumbnailReady: _thumbnailReady,
    onVisibleIdle: widget.onVisibleIdle,
    visibleIdleRevision: widget.visibleIdleRevision,
    tryRequestPreview: _canRequest && _binding != null
        ? () => _request()
        : null,
    placeholder:
        widget.placeholder ??
        const ColoredBox(
          color: Colors.white,
          child: Center(
            child: Icon(
              Icons.play_circle_outline,
              color: Colors.black38,
              size: 36,
            ),
          ),
        ),
  );
}
