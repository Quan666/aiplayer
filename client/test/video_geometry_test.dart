import 'package:aiplayer/playback/input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'display aspect remains stable independently of native texture allocation',
    () {
      expect(videoAspectRatio(), isNull);
      expect(videoAspectRatio(width: 0, height: 1080), isNull);
      expect(videoAspectRatio(width: 1920, height: -1), isNull);
      expect(
        videoAspectRatio(width: 1920, height: 1080),
        closeTo(16 / 9, .001),
      );
      for (final rotation in [90, -90, 270]) {
        expect(
          videoAspectRatio(width: 1920, height: 1080, rotation: rotation),
          closeTo(9 / 16, .001),
        );
      }
      expect(
        videoAspectRatio(width: 1920, height: 1080, rotation: 180),
        closeTo(16 / 9, .001),
      );
      expect(videoAspectRatio(width: 1440, height: 1080), closeTo(4 / 3, .001));
    },
  );
}
