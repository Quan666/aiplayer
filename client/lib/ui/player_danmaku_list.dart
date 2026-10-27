import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderSliverList, ScrollDirection, SliverMultiBoxAdaptorParentData;

import '../danmaku/api.dart';
import '../playback/fullscreen_transition.dart';
import 'player_theme.dart';

/// Uses the already ordered snapshot and the player's existing position events.
/// Only crossing a comment timestamp changes the selected rows or scroll offset.
class PlayerDanmakuList extends StatefulWidget {
  final ValueListenable<Duration> position;
  final List<DanmakuComment> comments;
  final double shift;
  final int timelineRevision;
  final Object? sourceKey;

  const PlayerDanmakuList({
    super.key,
    required this.position,
    required this.comments,
    required this.shift,
    this.timelineRevision = 0,
    this.sourceKey,
  });

  @override
  State<PlayerDanmakuList> createState() => _PlayerDanmakuListState();
}

class _PlayerDanmakuListState extends State<PlayerDanmakuList>
    with WidgetsBindingObserver {
  ScrollController? _scroll;
  final _centerKey = GlobalKey();
  bool _foreground = true, _visible = false, _listening = false;
  bool _centerPending = false, _jumping = false;
  bool _following = true;
  int _anchorIndex = 0;
  (int, int) _current = (-1, -1);

  bool get _active => _foreground && _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = !playbackIsBackgrounded(
      WidgetsBinding.instance.lifecycleState,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _updateListening();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = !playbackIsBackgrounded(state);
    // Android can stop producing frames at this point. Detach immediately and
    // finish a ballistic scroll before its ticker is suspended.
    _updateListening();
  }

  @override
  void didUpdateWidget(PlayerDanmakuList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = !identical(oldWidget.position, widget.position);
    final snapshotChanged = !identical(oldWidget.comments, widget.comments);
    final relocate =
        sourceChanged ||
        oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.timelineRevision != widget.timelineRevision ||
        oldWidget.shift != widget.shift;
    if (sourceChanged) {
      if (_listening) oldWidget.position.removeListener(_positionChanged);
      _listening = false;
    }
    if (relocate) _following = true;
    _updateListening();
    if (relocate || snapshotChanged) {
      if (_active) _current = _findCurrent();
      if (_following) {
        _resetAnchor(
          _active
              ? math.max(0, _current.$1)
              : math.min(_anchorIndex, widget.comments.length),
        );
      } else if (_anchorIndex >= widget.comments.length ||
          widget.comments.length < oldWidget.comments.length &&
              _browsingWindowRemoved()) {
        // If all laid-out rows were removed, keep browsing at the new end.
        // Retaining a large offset would make the sliver measure its prefix.
        _resetAnchor(math.max(0, widget.comments.length - 1));
      }
    }
  }

  bool _browsingWindowRemoved() {
    final sliver = _centerKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliverList) return false;
    final data = sliver.firstChild?.parentData;
    return data is SliverMultiBoxAdaptorParentData &&
        data.index != null &&
        data.index! >= widget.comments.length - _anchorIndex;
  }

  void _pauseFollowing() {
    if (!_active || !_following || _jumping) return;
    setState(() => _following = false);
  }

  void _followCurrent() {
    if (!_active) return;
    setState(() {
      _following = true;
      _current = _findCurrent();
      _resetAnchor(math.max(0, _current.$1));
    });
  }

  bool _scrollChanged(ScrollNotification notification) {
    if (notification.depth != 0 || _jumping) return false;
    if (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle ||
        notification is ScrollStartNotification) {
      _pauseFollowing();
    }
    return false;
  }

  void _resetAnchor(int anchor) {
    // Replacing the snapshot/offset must not lay out the new slivers using a
    // large offset retained from the previous snapshot, even while hidden.
    _jumping = true;
    try {
      final position = (_scroll?.hasClients ?? false)
          ? _scroll!.position
          : null;
      if (position is ScrollPositionWithSingleContext) position.goIdle();
      _anchorIndex = anchor;
      if (position != null && position.pixels != 0) _scroll!.jumpTo(0);
    } finally {
      _jumping = false;
    }
  }

  void _updateListening() {
    if (_active == _listening) return;
    _listening = _active;
    if (_listening) {
      widget.position.addListener(_positionChanged);
      _positionChanged(force: true);
    } else {
      widget.position.removeListener(_positionChanged);
      if (_scroll?.hasClients ?? false) {
        final position = _scroll!.position;
        if (position is ScrollPositionWithSingleContext) position.goIdle();
      }
    }
  }

  (int, int) _findCurrent() {
    final comments = widget.comments;
    final seconds =
        widget.position.value.inMicroseconds / 1000000 - widget.shift;
    var low = 0, high = comments.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (comments[middle].time <= seconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final end = low;
    if (end == 0) return (-1, -1);
    // Equal-time comments form a single selection; anchor its first row so a
    // busy timestamp does not hide the beginning of that group below the view.
    final time = comments[end - 1].time;
    low = 0;
    high = end;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (comments[middle].time < time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return (low, end);
  }

  void _positionChanged({bool force = false}) {
    if (!_active) return;
    final current = _findCurrent();
    if (!force && current == _current) return;
    setState(() => _current = current);
    _center();
  }

  void _center() {
    if (!_active || !_following) return;
    final position = (_scroll?.hasClients ?? false) ? _scroll!.position : null;
    // Manual browsing owns its scroll offset until explicitly resumed.
    if (position?.isScrollingNotifier.value ?? false) return;
    final anchor = math.max(0, _current.$1);
    if (_anchorIndex != anchor) setState(() => _anchorIndex = anchor);
    if (position == null || position.pixels.abs() < .5) return;
    _jumping = true;
    try {
      _scroll!.jumpTo(0);
    } finally {
      _jumping = false;
    }
  }

  void _scheduleCenter() {
    if (!_active || !_following || _centerPending) return;
    _centerPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerPending = false;
      if (mounted && _active) _center();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_listening) widget.position.removeListener(_positionChanged);
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = PlayerTheme.of(context);
    final textStyle = TextStyle(
      fontSize: 13,
      height: 1.2,
      color: style.foreground,
    );
    final scaled = MediaQuery.textScalerOf(context).scale(13);
    final minimumHeight = math.max(24.0, scaled * 1.2 + 6);
    final anchor = _anchorIndex;
    if (widget.comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('暂无弹幕', style: style.mutedStyle),
      );
    }
    Widget row(BuildContext context, int index) {
      final comment = widget.comments[index];
      final selected = index >= _current.$1 && index < _current.$2;
      final time = _clock(comment.time + widget.shift);
      return Semantics(
        key: ValueKey('danmaku-comment-$index'),
        selected: selected,
        child: ColoredBox(
          color: selected ? style.selectedColor : Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minimumHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: textStyle.copyWith(
                      color: style.secondaryForeground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(comment.text, style: textStyle)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 480.0;
        // Reserve only space that preceding rows can fill. Their minimum
        // height avoids measuring history while keeping early comments at
        // the top instead of leaving a gap above a fixed 30% anchor.
        final viewportAnchor = height > 0
            ? math.min(.3, anchor * minimumHeight / height)
            : 0.0;
        _scroll ??= ScrollController(keepScrollOffset: false);
        return SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  _scheduleCenter();
                  return false;
                },
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scrollChanged,
                  child: CustomScrollView(
                    key: const ValueKey('danmaku-time-list'),
                    controller: _scroll,
                    primary: false,
                    center: _centerKey,
                    anchor: viewportAnchor,
                    // Split at the current timestamp: variable-height rows seek
                    // without measuring the preceding history or keeping it alive.
                    slivers: [
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => row(context, anchor - index - 1),
                          childCount: anchor,
                        ),
                      ),
                      SliverList(
                        key: _centerKey,
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => row(context, anchor + index),
                          childCount: widget.comments.length - anchor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!_following)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('danmaku-follow-current'),
                    onPressed: _followCurrent,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.my_location, size: 14),
                    label: const Text('回到当前'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String _clock(double seconds) {
  final total = math.max(0, seconds.floor());
  return '${total >= 3600 ? '${total ~/ 3600}:' : ''}'
      '${(total ~/ 60 % 60).toString().padLeft(2, '0')}:'
      '${(total % 60).toString().padLeft(2, '0')}';
}
