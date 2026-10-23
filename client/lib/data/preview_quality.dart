import 'dart:math' as math;
import 'dart:typed_data';

/// Conservative rejection of blank decoder output and black/white transitions.
/// This does not rank the aesthetics of a scene or compare successive frames:
/// a still anime shot is a perfectly useful cover.
class PreviewQuality {
  final bool usable;
  final double meanLuma, deviation, blackFraction, whiteFraction;
  const PreviewQuality({
    required this.usable,
    required this.meanLuma,
    required this.deviation,
    required this.blackFraction,
    required this.whiteFraction,
  });
}

/// Examine at most 4,096 samples from already downscaled RGBA pixels. Sampling
/// the entire frame also rejects black frames containing a tiny timestamp or
/// subtitle, while allowing letterboxed material and detailed night scenes.
PreviewQuality inspectPreviewRgba(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    throw ArgumentError('Invalid preview pixel buffer');
  }
  final columns = math.min(width, 64), rows = math.min(height, 64);
  var samples = 0, transparent = 0, black = 0, white = 0;
  var sum = 0.0, squared = 0.0;
  final low = [255, 255, 255], high = [0, 0, 0];
  for (var row = 0; row < rows; row++) {
    final y = ((row + .5) * height / rows).floor();
    for (var column = 0; column < columns; column++) {
      final x = ((column + .5) * width / columns).floor();
      final index = (y * width + x) * 4;
      samples++;
      if (rgba[index + 3] < 128) transparent++;
      final r = rgba[index], g = rgba[index + 1], b = rgba[index + 2];
      final luma = .2126 * r + .7152 * g + .0722 * b;
      sum += luma;
      squared += luma * luma;
      if (math.max(r, math.max(g, b)) <= 16) black++;
      if (math.min(r, math.min(g, b)) >= 242) white++;
      for (var channel = 0; channel < 3; channel++) {
        final value = rgba[index + channel];
        low[channel] = math.min(low[channel], value);
        high[channel] = math.max(high[channel], value);
      }
    }
  }
  final mean = sum / samples;
  final deviation = math.sqrt(math.max(0, squared / samples - mean * mean));
  final blackFraction = black / samples, whiteFraction = white / samples;
  final channelRange = List.generate(
    3,
    (i) => high[i] - low[i],
  ).reduce(math.max);
  return PreviewQuality(
    usable:
        transparent / samples < .95 &&
        blackFraction < .97 &&
        whiteFraction < .97 &&
        // A flat gray/colored decoder surface has no image content. Do not
        // reject flat-luma artwork when its chroma still contains detail.
        !(deviation < 1.5 && channelRange < 8),
    meanLuma: mean,
    deviation: deviation,
    blackFraction: blackFraction,
    whiteFraction: whiteFraction,
  );
}

/// With progress, never substitute a distant chapter for the last viewed
/// scene. Without progress, try a bounded set of early/middle scenes instead
/// of repeatedly capturing an opening logo or the same black frame.
List<double> previewCapturePositions(double duration, {double? position}) {
  final end = duration.isFinite && duration > 0
      ? math.max(0.0, duration - .15)
      : double.infinity;
  final result = <double>[];
  void add(double value) {
    final target = value.clamp(0.0, end).toDouble();
    if (!result.any((other) => (other - target).abs() < .05)) {
      result.add(target);
    }
  }

  if (position != null && position.isFinite && position >= 0) {
    for (final offset in [0.0, -.5, .5, -1.5, 1.5]) {
      add(position + offset);
    }
  } else if (duration.isFinite && duration > 0) {
    add(math.min(180, duration * .12));
    add(duration * .25);
    add(duration * .4);
    add(duration * .6);
  } else {
    for (final target in [3.0, 8.0, 15.0, 0.0]) {
      add(target);
    }
  }
  return result;
}
