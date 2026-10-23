import 'dart:typed_data';

import 'package:aiplayer/data/preview_quality.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pixels(
  int width,
  int height,
  List<int> Function(int x, int y) color,
) {
  final result = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      result.setRange(
        (y * width + x) * 4,
        (y * width + x + 1) * 4,
        color(x, y),
      );
    }
  }
  return result;
}

void main() {
  test(
    'black, white, flat gray and transparent decoder surfaces are rejected',
    () {
      for (final color in [
        [0, 0, 0, 255],
        [12, 12, 12, 255],
        [255, 255, 255, 255],
        [245, 245, 245, 255],
        [128, 128, 128, 255],
        [0, 120, 255, 255],
        [110, 60, 90, 0],
      ]) {
        expect(
          inspectPreviewRgba(pixels(80, 40, (_, _) => color), 80, 40).usable,
          false,
          reason: '$color',
        );
      }
    },
  );

  test('a tiny caption does not make a black transition a useful cover', () {
    final frame = pixels(
      160,
      90,
      (x, y) =>
          x > 65 && x < 95 && y > 85 ? [255, 255, 255, 255] : [0, 0, 0, 255],
    );
    expect(inspectPreviewRgba(frame, 160, 90).usable, false);
  });

  test('letterboxed artwork and detailed dark scenes remain usable', () {
    final letterboxed = pixels(
      160,
      90,
      (x, y) =>
          y < 12 || y > 77 ? [0, 0, 0, 255] : [x, 30 + y, 40 + (x % 90), 255],
    );
    final night = pixels(160, 90, (x, y) => [5 + x % 25, 7 + y % 28, 18, 255]);
    for (final frame in [letterboxed, night]) {
      expect(inspectPreviewRgba(frame, 160, 90).usable, true);
    }
  });

  test('default candidates are finite, bounded and spread beyond opening', () {
    expect(previewCapturePositions(30), [closeTo(3.6, .001), 7.5, 12, 18]);
    expect(previewCapturePositions(1440).first, closeTo(172.8, .001));
    expect(previewCapturePositions(7200).first, 180);
    expect(previewCapturePositions(0), [3, 8, 15, 0]);
    expect(previewCapturePositions(double.nan), [3, 8, 15, 0]);
    expect(previewCapturePositions(.1), [0]);
  });

  test(
    'resume candidates stay within 1.5 seconds and prefer exact progress',
    () {
      expect(previewCapturePositions(100, position: 50), [
        50,
        49.5,
        50.5,
        48.5,
        51.5,
      ]);
      expect(previewCapturePositions(100, position: 0), [0, .5, 1.5]);
      expect(previewCapturePositions(10, position: 12), [9.85]);
      expect(previewCapturePositions(0, position: 60).first, 60);
    },
  );
}
