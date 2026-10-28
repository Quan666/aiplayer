import 'package:flutter/material.dart';

import 'glass.dart';
import 'player_theme.dart';

/// Keep the edge shading anchored to the viewport while controls slide.
class PlayerControlsShade extends StatelessWidget {
  const PlayerControlsShade({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: MotionScope.duration(context, 200),
      curve: Curves.easeOutCubic,
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: PlayerTheme.of(context).shadeDecoration,
        ),
      ),
    ),
  );
}
