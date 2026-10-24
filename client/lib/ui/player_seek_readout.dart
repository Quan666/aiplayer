import 'package:flutter/material.dart';

import 'player_theme.dart';

/// A single, centered line for the target and the distance from drag start.
class PlayerSeekReadout extends StatelessWidget {
  final String time;
  final Duration target, origin;
  final double maxWidth;

  const PlayerSeekReadout({
    super.key,
    required this.time,
    required this.target,
    required this.origin,
    required this.maxWidth,
  });

  // Match the displayed time labels, which each omit fractional seconds.
  // Subtracting before truncation would turn 1:30.7 -> 2:00 into +0:29.
  int get _deltaSeconds => target.inSeconds - origin.inSeconds;

  String get _difference {
    final total = _deltaSeconds.abs();
    final seconds = (total % 60).toString().padLeft(2, '0');
    final minutes = total ~/ 60;
    final duration = total >= 3600
        ? '${total ~/ 3600}:${(minutes % 60).toString().padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
    return '${_deltaSeconds < 0 ? '-' : '+'}$duration';
  }

  @override
  Widget build(BuildContext context) {
    final style = PlayerTheme.of(context).seekTimeStyle.copyWith(height: 1);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          textDirection: TextDirection.ltr,
          children: [
            Text(
              time,
              key: const ValueKey('seek-preview-time'),
              maxLines: 1,
              softWrap: false,
              textDirection: TextDirection.ltr,
              style: style,
            ),
            const SizedBox(width: 10),
            Text(
              _deltaSeconds < 0 ? '<<' : '>>',
              key: const ValueKey('seek-preview-direction'),
              maxLines: 1,
              softWrap: false,
              textDirection: TextDirection.ltr,
              style: style.copyWith(fontSize: 24),
            ),
            const SizedBox(width: 10),
            Text(
              _difference,
              key: const ValueKey('seek-preview-difference'),
              maxLines: 1,
              softWrap: false,
              textDirection: TextDirection.ltr,
              style: style.copyWith(fontSize: 24),
            ),
          ],
        ),
      ),
    );
  }
}
