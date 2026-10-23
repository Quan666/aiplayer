import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../playback/session.dart';
import '../playback/fullscreen_transition.dart';
import '../ui/theme/danmaku_style.dart';
import 'layout.dart';

class DanmakuOverlay extends StatefulWidget {
  final PlaybackSession session;
  final double fontSize, opacity, area, density, speed;
  final bool scroll, top, bottom, presetFilter;
  final String blockedWords;
  const DanmakuOverlay({
    super.key,
    required this.session,
    this.fontSize = 22,
    this.opacity = .8,
    this.area = .65,
    this.density = .7,
    this.speed = 1,
    this.scroll = true,
    this.top = true,
    this.bottom = true,
    this.presetFilter = true,
    this.blockedWords = '',
  });
  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  final cache = _LayoutCache();
  final _wake = ValueNotifier(0);
  Timer? _wakeTimer;
  bool _visible = true;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = !playbackIsBackgrounded(
      WidgetsBinding.instance.lifecycleState,
    );
    widget.session.addListener(_playState);
    widget.session.position.addListener(_playState);
    _playState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _playState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = !playbackIsBackgrounded(state);
    if (foreground == _foreground) return;
    _foreground = foreground;
    _playState();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.setDanmakuPresentationActive(false);
      oldWidget.session.removeListener(_playState);
      oldWidget.session.position.removeListener(_playState);
      cache.clear();
      widget.session.addListener(_playState);
      widget.session.position.addListener(_playState);
    }
    _playState();
  }

  void _playState() {
    widget.session.setDanmakuPresentationActive(_visible && _foreground);
    _wakeTimer?.cancel();
    _wakeTimer = null;
    if (!_playing) ticker.stop();
    if (!_visible || !_foreground) return;
    // A seek, refresh or native clock correction must be painted before
    // deciding whether the new layout needs continuous animation.
    _wakeFrame();
  }

  void _wakeFrame() => _wake.value++;

  bool get _playing {
    final s = widget.session;
    return _visible &&
        _foreground &&
        !s.closed &&
        s.player.state.playing &&
        !s.player.state.buffering &&
        s.danmaku?.visible == true;
  }

  void _scheduleFrame(bool moving, double? nextChange, double now) {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    final animate = _playing && moving;
    if (animate && !ticker.isAnimating) ticker.repeat();
    if (!animate && ticker.isAnimating) ticker.stop();
    if (!_playing || animate || nextChange == null) return;
    final rate = widget.session.player.state.rate;
    if (!rate.isFinite || rate <= 0) return;
    // Static comments only change on arrival/expiry. Empty spans only change
    // on the next arrival. Keep that timing at every playback rate, without
    // relying on the less frequent native position events to reveal comments.
    _wakeTimer = Timer(
      Duration(
        microseconds: max(1, ((nextChange - now) / rate * 1000000).ceil()),
      ),
      _wakeFrame,
    );
  }

  @override
  void dispose() {
    widget.session.setDanmakuPresentationActive(false);
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_playState);
    widget.session.position.removeListener(_playState);
    _wakeTimer?.cancel();
    ticker.dispose();
    _wake.dispose();
    cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.session.closed
      ? const SizedBox.expand()
      : IgnorePointer(
          child: RepaintBoundary(
            child: ClipRect(
              child: CustomPaint(
                size: Size.infinite,
                painter: _Painter(
                  widget.session,
                  cache,
                  widget.fontSize,
                  widget.opacity,
                  widget.area,
                  widget.density,
                  widget.speed,
                  widget.scroll,
                  widget.top,
                  widget.bottom,
                  widget.presetFilter,
                  widget.blockedWords,
                  DanmakuStyle.of(context),
                  Listenable.merge([ticker, _wake]),
                  _scheduleFrame,
                ),
              ),
            ),
          ),
        );
}

class _LayoutCache {
  final layout = DanmakuLayout();
  double font = 0, opacity = 0;
  DanmakuStyle? style;
  final text = <ScheduledComment, TextPainter>{};
  void clear() {
    layout.clear();
    clearText();
  }

  void clearText() {
    for (final p in text.values) {
      p.dispose();
    }
    text.clear();
  }

  void ensureStyle(double size, double alpha, DanmakuStyle currentStyle) {
    if (font != size || opacity != alpha || style != currentStyle) {
      clearText();
      font = size;
      opacity = alpha;
      style = currentStyle;
    }
  }
}

class _Painter extends CustomPainter {
  final PlaybackSession session;
  final _LayoutCache cache;
  final double fontSize, opacity, area, density, speed;
  final bool scroll, top, bottom, presetFilter;
  final String blockedWords;
  final DanmakuStyle style;
  final void Function(bool, double?, double) scheduleFrame;
  _Painter(
    this.session,
    this.cache,
    this.fontSize,
    this.opacity,
    this.area,
    this.density,
    this.speed,
    this.scroll,
    this.top,
    this.bottom,
    this.presetFilter,
    this.blockedWords,
    this.style,
    Listenable ticker,
    this.scheduleFrame,
  ) : super(repaint: ticker);
  @override
  void paint(Canvas canvas, Size size) {
    final state = session.danmaku;
    if (state == null || !state.visible) {
      cache.clear();
      scheduleFrame(false, null, 0);
      return;
    }
    final now = session.seconds - state.shift - state.offset,
        laneHeight = fontSize * 1.5;
    final count = max(
      1,
      ((size.height * area - 30) / laneHeight * density).floor(),
    );
    cache.ensureStyle(fontSize, opacity, style);
    cache.layout.update(
      state.comments,
      count,
      now: now,
      position: session.position.value,
      contextKey: (
        session,
        session.timelineRevision,
        state,
        state.episodeId,
        state.shift,
        state.offset,
        size,
        fontSize,
      ),
      speed: speed,
      scroll: scroll,
      top: top,
      bottom: bottom,
      presetFilter: presetFilter,
      blockedWords: blockedWords,
    );
    final visible = cache.layout.visibleAt(now).toSet();
    var moving = false;
    var nextChange = cache.layout.nextStartAfter(now);
    for (final item in visible) {
      final age = now - item.start;
      final c = item.comment;
      if (c.mode == 0) {
        moving = true;
      } else {
        final end = item.start + item.duration;
        nextChange = nextChange == null ? end : min(nextChange, end);
      }
      final tp = cache.text.putIfAbsent(
        item,
        () => TextPainter(
          text: TextSpan(
            text: c.text,
            style: style.comment(
              color: c.color,
              size: fontSize,
              opacity: opacity,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(),
      );
      final x = c.mode == 0
          ? size.width - (size.width + tp.width) * age / item.duration
          : (size.width - tp.width) / 2;
      tp.paint(canvas, Offset(x, 12 + item.lane * laneHeight));
    }
    for (final key
        in cache.text.keys.where((k) => !visible.contains(k)).toList()) {
      cache.text.remove(key)!.dispose();
    }
    scheduleFrame(moving, nextChange, now);
  }

  @override
  bool shouldRepaint(covariant _Painter oldDelegate) => true;
}
