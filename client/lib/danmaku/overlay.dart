import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../playback/session.dart';
import '../playback/fullscreen_transition.dart';
import '../ui/theme/danmaku_style.dart';
import 'layout.dart';
import 'layout_worker.dart';
import 'presentation_clock.dart';

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
  late final cache = _LayoutCache(_layoutChanged);
  final _clock = DanmakuPresentationClock();
  final _wake = ValueNotifier(0);
  Timer? _wakeTimer;
  Size? _size;
  bool _visible = true;
  bool _foreground = true;

  @visibleForTesting
  Future<void> get debugLayoutReady => cache.layout.ready;

  @visibleForTesting
  DanmakuLayoutWorker get debugLayoutWorker => cache.layout.worker;

  @visibleForTesting
  int get debugTextLayouts => cache.textLayouts;

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
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible != visible) _clock.reset();
    _visible = visible;
    _playState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = !playbackIsBackgrounded(state);
    if (foreground == _foreground) return;
    _foreground = foreground;
    _clock.reset();
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
      _clock.reset();
      widget.session.addListener(_playState);
      widget.session.position.addListener(_playState);
    }
    _playState();
  }

  void _playState() {
    widget.session.setDanmakuPresentationActive(_visible && _foreground);
    _wakeTimer?.cancel();
    _wakeTimer = null;
    cache.layout.setSuspended(!_visible || !_foreground);
    if (!_playing) ticker.stop();
    if (!_visible || !_foreground) return;
    _prepareLayout();
    _wakeFrame();
  }

  void _layoutChanged() {
    if (mounted && _visible && _foreground) _wakeFrame();
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

  Object get _timelineContext {
    final s = widget.session, state = s.danmaku;
    return (
      s,
      s.timelineRevision,
      state,
      state?.episodeId,
      state?.shift,
      state?.offset,
    );
  }

  void _prepareLayout([Size? size]) {
    if (size != null) _size = size;
    if (!_visible || !_foreground) return;
    final state = widget.session.danmaku, viewport = _size;
    if (state == null || !state.visible || widget.session.closed) {
      cache.clear();
      return;
    }
    if (viewport == null || viewport.isEmpty) return;
    final count = max(
      1,
      ((viewport.height * widget.area - 30) /
              (widget.fontSize * 1.5) *
              widget.density)
          .floor(),
    );
    // The widget/layout path only compares revisions and enqueues work. The
    // worker owns full-snapshot filtering and lane allocation, never paint.
    cache.layout.update(
      state.comments,
      DanmakuLayoutOptions(
        count: count,
        speed: widget.speed,
        scroll: widget.scroll,
        top: widget.top,
        bottom: widget.bottom,
        presetFilter: widget.presetFilter,
        blockedWords: widget.blockedWords,
      ),
      now: _presentationTime(),
      position: widget.session.position.value,
      contextKey: _timelineContext,
    );
  }

  double _presentationTime() {
    final s = widget.session, state = s.danmaku;
    return _clock.sample(
      position: s.seconds - (state?.shift ?? 0) - (state?.offset ?? 0),
      // Vsync timestamps avoid work-time jitter and cover single arrival/
      // expiry frames after idle gaps without an extra wall-clock timer.
      elapsed: SchedulerBinding.instance.currentSystemFrameTimeStamp,
      playing: _playing,
      rate: s.player.state.rate,
      contextKey: _timelineContext,
      timelineRevision: s.timelineRevision,
      nativePosition: s.position.value,
    );
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
    cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.session.closed) return const SizedBox.expand();
    cache.ensureStyle(
      widget.fontSize,
      widget.opacity,
      DanmakuStyle.of(context),
    );
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _prepareLayout(constraints.biggest);
              return CustomPaint(
                size: Size.infinite,
                painter: _Painter(
                  widget.session,
                  cache,
                  widget.fontSize,
                  () => _visible && _foreground,
                  _presentationTime,
                  Listenable.merge([ticker, _wake]),
                  _scheduleFrame,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LayoutCache {
  final AsyncDanmakuLayout layout;
  _LayoutCache(void Function() onChanged)
    : layout = AsyncDanmakuLayout(onChanged);
  double font = 0, opacity = 0;
  DanmakuStyle? style;
  final text = <ScheduledComment, TextPainter>{};
  int textLayouts = 0;
  DanmakuSchedule? _prepared;
  List<ScheduledComment> _visible = const [];
  double _lastTime = double.negativeInfinity;
  double? nextChange;
  bool moving = false;

  void clear() {
    layout.clear();
    clearText();
    _prepared = null;
    _visible = const [];
  }

  void dispose() {
    layout.dispose();
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

  TextPainter textFor(ScheduledComment item) => text.putIfAbsent(item, () {
    textLayouts++;
    return TextPainter(
      text: TextSpan(
        text: item.comment.text,
        style: style!.comment(
          color: item.comment.color,
          size: font,
          opacity: opacity,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  });

  List<ScheduledComment> visibleAt(double now) {
    final prepared = layout.schedule;
    if (identical(prepared, _prepared) &&
        now >= _lastTime &&
        (nextChange == null || now < nextChange!)) {
      _lastTime = now;
      return _visible;
    }
    _prepared = prepared;
    _lastTime = now;
    _visible = prepared.visibleAt(now).toList(growable: false);
    nextChange = prepared.nextStartAfter(now);
    moving = false;
    for (final item in _visible) {
      moving = moving || item.comment.mode == 0;
      final end = item.start + item.duration;
      nextChange = nextChange == null ? end : min(nextChange!, end);
    }
    // Membership changes only on arrival, expiry, seek or snapshot replacement.
    // Keep glyph layouts and avoid allocating/scanning sets on every vsync.
    final active = _visible.toSet();
    text.removeWhere((item, painter) {
      if (active.contains(item)) return false;
      painter.dispose();
      return true;
    });
    return _visible;
  }
}

class _Painter extends CustomPainter {
  final PlaybackSession session;
  final _LayoutCache cache;
  final double fontSize;
  final bool Function() presentationActive;
  final double Function() presentationTime;
  final void Function(bool, double?, double) scheduleFrame;
  _Painter(
    this.session,
    this.cache,
    this.fontSize,
    this.presentationActive,
    this.presentationTime,
    Listenable ticker,
    this.scheduleFrame,
  ) : super(repaint: ticker);
  @override
  void paint(Canvas canvas, Size size) {
    final state = session.danmaku;
    if (!presentationActive() ||
        state == null ||
        !state.visible ||
        session.closed) {
      scheduleFrame(false, null, 0);
      return;
    }
    final now = presentationTime(), laneHeight = fontSize * 1.5;
    final visible = cache.visibleAt(now);
    for (final item in visible) {
      final age = now - item.start;
      final c = item.comment;
      final tp = cache.textFor(item);
      final x = c.mode == 0
          ? size.width - (size.width + tp.width) * age / item.duration
          : (size.width - tp.width) / 2;
      tp.paint(canvas, Offset(x, 12 + item.lane * laneHeight));
    }
    scheduleFrame(cache.moving, cache.nextChange, now);
  }

  @override
  bool shouldRepaint(covariant _Painter oldDelegate) => true;
}
