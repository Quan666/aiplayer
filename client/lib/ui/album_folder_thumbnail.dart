import 'package:flutter/material.dart';

import '../data/album_images.dart';
import '../data/app_model.dart';
import '../sources/source.dart';
import 'album_thumbnail.dart';
import 'album_video_thumbnail.dart';

/// Resolves a shallow cover on the existing image worker. A folder with no
/// usable still image and exactly one video shares that video's preview queue.
class AlbumFolderThumbnail extends StatefulWidget {
  final AppModel model;
  final AlbumImageService service;
  final String sourceId;
  final SourceEntry entry;
  final int edge;
  final bool active, hideHidden;
  final Set<String> extensions, excludedExtensions;
  final Widget? placeholder;
  final String? Function(SourceEntry)? preparedVideoCover;
  final void Function(SourceEntry, String?)? onVideoCoverChanged;
  const AlbumFolderThumbnail({
    super.key,
    required this.model,
    required this.service,
    required this.sourceId,
    required this.entry,
    required this.edge,
    this.active = true,
    this.hideHidden = true,
    this.extensions = const {},
    this.excludedExtensions = const {},
    this.placeholder,
    this.preparedVideoCover,
    this.onVideoCoverChanged,
  });

  @override
  State<AlbumFolderThumbnail> createState() => _AlbumFolderThumbnailState();
}

class _AlbumFolderThumbnailState extends State<AlbumFolderThumbnail> {
  SourceEntry? _video;
  late int _revision;
  late final ValueNotifier<bool> _videoActivity;

  @override
  void initState() {
    super.initState();
    _revision = widget.service.revision;
    _video = _preparedVideo();
    _videoActivity = ValueNotifier(widget.active && widget.service.active);
    widget.service.addListener(_serviceChanged);
  }

  void _serviceChanged() {
    if (!mounted) return;
    // A covered page may receive no further frame. Revoke native screenshot
    // work through the child's direct listener instead of waiting for build.
    _videoActivity.value = widget.active && widget.service.active;
    if (_revision == widget.service.revision) return;
    _revision = widget.service.revision;
    setState(() => _video = _preparedVideo());
  }

  @override
  void didUpdateWidget(covariant AlbumFolderThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_serviceChanged);
      widget.service.addListener(_serviceChanged);
    }
    _videoActivity.value = widget.active && widget.service.active;
    if (oldWidget.service != widget.service ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.entry.path != widget.entry.path ||
        oldWidget.entry.size != widget.entry.size ||
        oldWidget.entry.modified != widget.entry.modified ||
        oldWidget.hideHidden != widget.hideHidden ||
        !_same(oldWidget.extensions, widget.extensions) ||
        !_same(oldWidget.excludedExtensions, widget.excludedExtensions)) {
      _revision = widget.service.revision;
      _video = _preparedVideo();
    }
  }

  SourceEntry? _preparedVideo() {
    // A remounted folder can already have its shallow result in memory.
    // Reuse only the exact folder/filter identity, including hidden covers.
    final result = widget.service.peekPrepared(
      widget.entry,
      targetEdge: widget.edge,
      folder: true,
      hideHidden: widget.hideHidden,
      extensions: widget.extensions,
      excludedExtensions: widget.excludedExtensions,
    );
    return result != null &&
            !result.cancelled &&
            !result.deferred &&
            result.path == null
        ? result.singleVideo
        : null;
  }

  bool _same(Set<String> a, Set<String> b) =>
      identical(a, b) || a.length == b.length && a.containsAll(b);

  @override
  void dispose() {
    widget.service.removeListener(_serviceChanged);
    _videoActivity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    if (video != null) {
      return AlbumVideoThumbnail(
        model: widget.model,
        sourceId: widget.sourceId,
        entry: video,
        edge: widget.edge,
        active: widget.active,
        activity: _videoActivity,
        placeholder: widget.placeholder,
        initialThumbnail: widget.preparedVideoCover?.call(video),
        onThumbnailChanged: (path) =>
            widget.onVideoCoverChanged?.call(video, path),
      );
    }
    return AlbumThumbnail(
      service: widget.service,
      entry: widget.entry,
      edge: widget.edge,
      folder: true,
      hideHidden: widget.hideHidden,
      extensions: widget.extensions,
      excludedExtensions: widget.excludedExtensions,
      placeholder: widget.placeholder,
      onLoaded: (result) {
        if (mounted && result.path == null && result.singleVideo != null) {
          setState(() => _video = result.singleVideo);
        }
      },
    );
  }
}
