import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';

/// The video overlay part of an app theme. It remains dark by default so the
/// library can change brightness without reducing contrast over the video.
@immutable
class PlayerTokens extends ThemeExtension<PlayerTokens> {
  final Color foreground, tint, highlight, shade, shadow, videoBackground;
  final double opacity, controlRadius, glassRadius, panelRadius;

  const PlayerTokens({
    this.foreground = Colors.white,
    this.tint = const Color(0xff101419),
    this.highlight = const Color(0xff161a20),
    this.shade = const Color(0xff080b10),
    this.shadow = Colors.black,
    this.videoBackground = Colors.black,
    this.opacity = 1,
    this.controlRadius = 16,
    this.glassRadius = 18,
    this.panelRadius = 24,
  }) : assert(opacity >= 0 && opacity <= 1),
       assert(controlRadius >= 0 && glassRadius >= 0 && panelRadius >= 0);

  static const standard = PlayerTokens();

  @override
  PlayerTokens copyWith({
    Color? foreground,
    Color? tint,
    Color? highlight,
    Color? shade,
    Color? shadow,
    Color? videoBackground,
    double? opacity,
    double? controlRadius,
    double? glassRadius,
    double? panelRadius,
  }) => PlayerTokens(
    foreground: foreground ?? this.foreground,
    tint: tint ?? this.tint,
    highlight: highlight ?? this.highlight,
    shade: shade ?? this.shade,
    shadow: shadow ?? this.shadow,
    videoBackground: videoBackground ?? this.videoBackground,
    opacity: opacity ?? this.opacity,
    controlRadius: controlRadius ?? this.controlRadius,
    glassRadius: glassRadius ?? this.glassRadius,
    panelRadius: panelRadius ?? this.panelRadius,
  );

  @override
  PlayerTokens lerp(covariant PlayerTokens? other, double t) => other == null
      ? this
      : PlayerTokens(
          foreground: Color.lerp(foreground, other.foreground, t)!,
          tint: Color.lerp(tint, other.tint, t)!,
          highlight: Color.lerp(highlight, other.highlight, t)!,
          shade: Color.lerp(shade, other.shade, t)!,
          shadow: Color.lerp(shadow, other.shadow, t)!,
          videoBackground: Color.lerp(
            videoBackground,
            other.videoBackground,
            t,
          )!,
          opacity: lerpDouble(opacity, other.opacity, t)!,
          controlRadius: lerpDouble(controlRadius, other.controlRadius, t)!,
          glassRadius: lerpDouble(glassRadius, other.glassRadius, t)!,
          panelRadius: lerpDouble(panelRadius, other.panelRadius, t)!,
        );
}
