import 'dart:io';

import 'package:aiplayer/data/media_previews.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String library;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('album-screenshot-');
    library = '${directory.path}/fixture.so';
    final result = await Process.run('cc', [
      '-std=c11',
      '-shared',
      '-fPIC',
      'test/fixtures/album_screenshot_fixture.c',
      '-o',
      library,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
  tearDownAll(() => directory.delete(recursive: true));

  for (final original in [false, true]) {
    for (final (kind, label) in [
      (1, 'already upright native screenshot'),
      (2, 'output with 90 degrees still pending'),
      (3, 'output with 270 degrees still pending'),
    ]) {
      test('$label keeps upright pixels (original=$original)', () async {
        final result = await captureNativeAlbumJpeg(
          library,
          kind,
          originalResolution: original,
        );
        expect(result, isNotNull);
        expect((result!.$2, result.$3), (48, 80));
        final frame = images.decodeJpg(result.$1)!;
        expect((frame.width, frame.height), (48, 80));
        for (final (x, y, expected) in [
          (12, 20, [255, 0, 0]),
          (36, 20, [0, 255, 0]),
          (12, 60, [0, 0, 255]),
          (36, 60, [255, 255, 0]),
        ]) {
          final pixel = frame.getPixel(x, y);
          final actual = [pixel.r, pixel.g, pixel.b];
          for (var channel = 0; channel < 3; channel++) {
            expect(actual[channel], closeTo(expected[channel], 10));
          }
        }
      });
    }
  }
}
