import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../playback/fullscreen_transition.dart';
import 'glass.dart';
import 'player_theme.dart';

/// A paint-only loading ring occupying the central transport button's slot.
class PlayerLoading extends StatefulWidget {
  const PlayerLoading({super.key});

  @override
  State<PlayerLoading> createState() => _PlayerLoadingState();
}

class _PlayerLoadingState extends State<PlayerLoading>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );
  bool _foreground = true;
  bool _motion = false;

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
    _motion =
        TickerMode.valuesOf(context).enabled && MotionScope.enabledOf(context);
    _updateAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = !playbackIsBackgrounded(state);
    // Android may stop delivering frames immediately after paused/hidden.
    // Stop the ticker here instead of waiting for a TickerMode rebuild.
    _updateAnimation();
  }

  void _updateAnimation() {
    if (_foreground && _motion) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = PlayerTheme.of(context);
    return Semantics(
      label: '正在加载视频',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: 76,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    style.tokens.shade.withValues(alpha: .68),
                    style.tokens.shade.withValues(alpha: .36),
                  ],
                ),
                border: Border.all(
                  color: style.foreground.withValues(alpha: .08),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CustomPaint(
                  size: const Size.square(40),
                  painter: _LoadingRing(_rotation, style.foreground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingRing extends CustomPainter {
  final Animation<double> rotation;
  final Color color;

  _LoadingRing(this.rotation, this.color) : super(repaint: rotation);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.6;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: .1),
    );
    canvas.rotate(rotation.value * math.pi * 2);
    const sweep = math.pi * 1.6;
    canvas.drawArc(
      rect,
      0,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          endAngle: sweep,
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .4),
            color,
          ],
          stops: const [0, .5, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LoadingRing oldDelegate) =>
      oldDelegate.color != color || oldDelegate.rotation != rotation;
}
