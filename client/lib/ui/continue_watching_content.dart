import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/network.dart';
import '../data/app_model.dart';
import '../data/continue_watching_presentation.dart';
import '../data/store.dart';
import 'artwork_scroll_scope.dart';

/// One prepared snapshot per history surface, never a database read per card.
class ContinueWatchingContent extends StatefulWidget {
  final AppModel model;
  final List<SyncRecord> items;
  final int? limit;
  final bool retainWhenOffscreen;
  final Widget Function(BuildContext, Map<String, ContinueWatchingPresentation>)
  builder;

  const ContinueWatchingContent({
    super.key,
    required this.model,
    required this.items,
    this.limit,
    this.retainWhenOffscreen = false,
    required this.builder,
  }) : assert(
         !retainWhenOffscreen || (limit != null && limit > 0 && limit <= 10),
       );

  @override
  State<ContinueWatchingContent> createState() =>
      _ContinueWatchingContentState();
}

class _ContinueWatchingContentState extends State<ContinueWatchingContent>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin<ContinueWatchingContent> {
  Map<String, ContinueWatchingPresentation> _views = const {};
  Object? _revision;
  Object? _requestedRevision;
  CancelToken? _cancel;
  ValueListenable<bool>? _activity;
  bool _active = false, _foreground = true, _dirty = true;
  bool _visibilityCheckScheduled = false;

  // Preserve only the small carousel, including its currently mounted Image
  // streams. The horizontal children and the poster wall remain lazy.
  @override
  bool get wantKeepAlive => widget.retainWhenOffscreen;

  bool get _inViewport {
    if (!widget.retainWhenOffscreen) return true;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    RenderObject? ancestor = box;
    while (ancestor != null) {
      final data = ancestor.parentData;
      // Kept-alive sliver children have no paint transform. Check this before
      // localToGlobal, which can otherwise produce nonfinite coordinates.
      if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) {
        return false;
      }
      ancestor = ancestor.parent;
    }
    var visible = box.localToGlobal(Offset.zero) & box.size;
    if (!visible.left.isFinite || !visible.top.isFinite) return false;
    final screen = MediaQuery.maybeSizeOf(context);
    if (screen != null) visible = visible.intersect(Offset.zero & screen);
    ancestor = box.parent;
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

  void _checkAfterLayout() {
    if (!widget.retainWhenOffscreen || _visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (mounted) _activityChanged();
    });
  }

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final activity = ArtworkScrollScope.maybeOf(context);
    if (_activity != activity) {
      _activity?.removeListener(_activityChanged);
      _activity = activity;
      _activity?.addListener(_activityChanged);
    }
    _activityChanged();
    _checkAfterLayout();
  }

  @override
  void didUpdateWidget(covariant ContinueWatchingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retainWhenOffscreen != widget.retainWhenOffscreen) {
      updateKeepAlive();
      _checkAfterLayout();
    }
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_changed);
      widget.model.addListener(_changed);
      _views = const {};
      _revision = null;
    }
    if (oldWidget.model != widget.model ||
        oldWidget.items != widget.items ||
        oldWidget.limit != widget.limit) {
      _cancel?.cancel();
      _cancel = null;
      _requestedRevision = null;
      _dirty = true;
      _activityChanged();
    }
  }

  bool get _canRead =>
      mounted &&
      _active &&
      _foreground &&
      _activity?.value != true &&
      _inViewport;

  void _changed() {
    if ((_requestedRevision ?? _revision) !=
        widget.model.continueWatchingPresentationRevision) {
      _dirty = true;
      _cancel?.cancel();
      _cancel = null;
      _requestedRevision = null;
    }
    _activityChanged();
  }

  void _activityChanged() {
    if (!_canRead) {
      _cancel?.cancel();
      _cancel = null;
      _requestedRevision = null;
      return;
    }
    if (_cancel == null &&
        (_dirty ||
            _revision != widget.model.continueWatchingPresentationRevision)) {
      unawaited(_read());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _activityChanged();
  }

  Future<void> _read() async {
    final cancel = _cancel = CancelToken();
    final model = widget.model;
    final revision = model.continueWatchingPresentationRevision;
    _requestedRevision = revision;
    final items = widget.limit == null
        ? widget.items
        : widget.items.take(widget.limit!).toList(growable: false);
    try {
      final views = await model.loadContinueWatchingPresentations(
        items,
        cancel: cancel,
      );
      if (!mounted || cancel.cancelled || _cancel != cancel) return;
      _cancel = null;
      _requestedRevision = null;
      if (!_canRead || revision != model.continueWatchingPresentationRevision) {
        _dirty = true;
        _activityChanged();
        return;
      }
      setState(() {
        _views = views;
        _revision = revision;
        _dirty = false;
      });
    } on Cancelled {
      // A hidden, scrolling or replaced surface keeps its last good snapshot.
    } catch (_) {
      // Keep navigation/playback usable if a source snapshot cannot be read.
      // Retry on the next model revision, instead of looping during builds.
      if (mounted && !cancel.cancelled && _cancel == cancel) {
        _revision = revision;
        _dirty = false;
      }
    } finally {
      if (_cancel == cancel) {
        _cancel = null;
        _requestedRevision = null;
      }
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    widget.model.removeListener(_changed);
    _activity?.removeListener(_activityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.builder(context, _views);
  }
}
