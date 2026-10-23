import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Comment colors, size and opacity belong to the media/user settings. Font
/// family and the outline treatment follow the active application theme.
@immutable
class DanmakuStyle {
  final String? fontFamily;
  final Color shadow;
  const DanmakuStyle({required this.fontFamily, required this.shadow});

  factory DanmakuStyle.of(BuildContext context) => DanmakuStyle(
    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    shadow:
        (Theme.of(context).extension<PlayerTokens>() ?? PlayerTokens.standard)
            .shadow,
  );

  TextStyle comment({
    required int color,
    required double size,
    required double opacity,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    color: Color(0xff000000 | color).withValues(alpha: opacity),
    fontWeight: FontWeight.w600,
    shadows: [Shadow(blurRadius: 3, color: shadow, offset: const Offset(1, 1))],
  );

  @override
  bool operator ==(Object other) =>
      other is DanmakuStyle &&
      fontFamily == other.fontFamily &&
      shadow == other.shadow;

  @override
  int get hashCode => Object.hash(fontFamily, shadow);
}
