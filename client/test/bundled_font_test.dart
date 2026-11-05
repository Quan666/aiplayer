import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<double> _ink({double? weightAxis}) async {
  final recorder = ui.PictureRecorder();
  final painter = TextPainter(
    text: TextSpan(
      text: '相册 文件夹 播放 4K',
      style: TextStyle(
        fontFamily: 'BundledRegular',
        fontSize: 18,
        fontWeight: FontWeight.w400,
        color: Colors.white,
        fontVariations: weightAxis == null
            ? null
            : [ui.FontVariation('wght', weightAxis)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(Canvas(recorder), Offset.zero);
  final picture = recorder.endRecording();
  final image = await picture.toImage(450, 60);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  var ink = 0.0;
  for (var index = 3; index < bytes.length; index += 4) {
    ink += bytes[index] / 255;
  }
  image.dispose();
  picture.dispose();
  painter.dispose();
  return ink;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled Regular renders weight 400 and retains light/heavy variants',
    () async {
      await (FontLoader('BundledRegular')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load();
      final regular = await _ink();
      expect(regular, closeTo(await _ink(weightAxis: 400), .1));
      expect(regular, greaterThan(await _ink(weightAxis: 100) * 1.3));
      expect(await _ink(weightAxis: 900), greaterThan(regular * 1.3));
    },
  );
}
