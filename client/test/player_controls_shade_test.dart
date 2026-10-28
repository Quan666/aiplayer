import 'dart:ui' as ui;

import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/player_controls_shade.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _view(
  GlobalKey boundary, {
  required bool visible,
  required Size size,
  bool motion = true,
  VoidCallback? onTap,
}) => MaterialApp(
  home: MotionScope(
    enabled: motion,
    child: PlayerTheme.surface(
      Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: onTap,
                  child: const ColoredBox(color: Colors.white),
                ),
                PlayerControlsShade(visible: visible),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<(int, int, int)> _edgePixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int redAt(int y) =>
            bytes.getUint8((y * image.width + image.width ~/ 2) * 4);
        return (redAt(0), redAt(image.height ~/ 2), redAt(image.height - 1));
      } finally {
        image.dispose();
      }
    }))!;

void _expectEdgesShaded((int, int, int) pixels) {
  expect(pixels.$1, lessThan(255), reason: 'top edge stays covered');
  expect(pixels.$2, 255, reason: 'middle stays clear');
  expect(pixels.$3, lessThan(255), reason: 'bottom edge stays covered');
}

void main() {
  for (final size in [const Size(480, 240), const Size(240, 480)]) {
    testWidgets('shade covers both edges through fade and reversal at $size', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(_view(boundary, visible: true, size: size));
      final shown = await _edgePixels(tester, boundary);
      _expectEdgesShaded(shown);

      await tester.pumpWidget(_view(boundary, visible: false, size: size));
      await tester.pump(const Duration(milliseconds: 40));
      final hiding = await _edgePixels(tester, boundary);
      _expectEdgesShaded(hiding);
      expect(hiding.$1, greaterThan(shown.$1));
      expect(hiding.$3, greaterThan(shown.$3));

      // Reversing an in-flight hide must not move either edge or jump opacity.
      await tester.pumpWidget(_view(boundary, visible: true, size: size));
      expect(await _edgePixels(tester, boundary), hiding);
      await tester.pump(const Duration(milliseconds: 40));
      final reversing = await _edgePixels(tester, boundary);
      _expectEdgesShaded(reversing);
      expect(reversing.$1, lessThan(hiding.$1));
      expect(reversing.$3, lessThan(hiding.$3));
      await tester.pumpAndSettle();
      expect(await _edgePixels(tester, boundary), shown);

      await tester.pumpWidget(_view(boundary, visible: false, size: size));
      await tester.pumpAndSettle();
      expect(await _edgePixels(tester, boundary), (255, 255, 255));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_view(boundary, visible: true, size: size));
      await tester.pump(const Duration(milliseconds: 40));
      _expectEdgesShaded(await _edgePixels(tester, boundary));
      await tester.pumpAndSettle();
      expect(await _edgePixels(tester, boundary), shown);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('shade leaves taps to video and respects disabled animation', (
    tester,
  ) async {
    final boundary = GlobalKey();
    var taps = 0;
    for (final visible in [true, false, true]) {
      await tester.pumpWidget(
        _view(
          boundary,
          visible: visible,
          size: const Size(480, 240),
          motion: false,
          onTap: () => taps++,
        ),
      );
      final pixels = await _edgePixels(tester, boundary);
      if (visible) {
        _expectEdgesShaded(pixels);
      } else {
        expect(pixels, (255, 255, 255));
      }
      await tester.tap(find.byKey(boundary));
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(taps, 3);
  });
}
