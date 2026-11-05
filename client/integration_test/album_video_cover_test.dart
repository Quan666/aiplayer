import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixtures = String.fromEnvironment('ALBUM_VIDEO_FIXTURES');
  const artifacts = String.fromEnvironment('ALBUM_VIDEO_COVER_ARTIFACT_DIR');
  testWidgets('paused native capture returns the actual first frame', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    final results = <Map<String, Object?>>[];
    if (artifacts.isNotEmpty) {
      await Directory(artifacts).create(recursive: true);
    }
    expect(fixtures, isNotEmpty, reason: 'Provide ALBUM_VIDEO_FIXTURES');
    // Fixture first.mp4 starts red, then turns blue; black.mp4 remains black.
    // Neither source is opened by the foreground player before capture.
    for (final name in ['first', 'black']) {
      final path = '$fixtures/$name.mp4';
      expect(await File(path).exists(), isTrue);
      if (name == 'black') {
        // The film-cover policy rejects this valid source at every sampled
        // position. Album capture must not inherit that failure policy.
        await expectLater(
          captureMediaPreview(path, CancelToken()),
          throwsA(
            isA<AppFailure>().having(
              (error) => error.message,
              'message',
              contains('黑场'),
            ),
          ),
        );
      }
      final preview = await captureMediaPreview(
        path,
        CancelToken(),
        firstFrame: true,
      ).timeout(const Duration(seconds: 30));
      expect(preview.capturedPosition, closeTo(0, .1));
      expect(preview.width, 360);
      expect(preview.height, 640);
      final codec = await ui.instantiateImageCodec(preview.bytes);
      final frame = (await codec.getNextFrame()).image;
      try {
        expect(frame.width, 270);
        expect(frame.height, 480);
        final pixels = (await frame.toByteData())!;
        final offset =
            (frame.width * (frame.height ~/ 2) + frame.width ~/ 2) * 4;
        if (name == 'first') {
          expect(pixels.getUint8(offset), greaterThan(200));
          expect(pixels.getUint8(offset + 2), lessThan(20));
        } else {
          expect(pixels.getUint8(offset), lessThan(20));
          expect(pixels.getUint8(offset + 2), lessThan(20));
        }
      } finally {
        frame.dispose();
        codec.dispose();
      }
    }
    // scripts/generate_album_video_fixture.py creates both display-matrix
    // directions and an already upright encoded portrait, with corner colors.
    for (final name in [
      'first',
      'orientation-unrotated',
      'orientation',
      'orientation-270',
      'portrait',
    ]) {
      for (final original in [false, true]) {
        final preview = await captureMediaPreview(
          '$fixtures/$name.mp4',
          CancelToken(),
          firstFrame: true,
          originalResolution: original,
        ).timeout(const Duration(seconds: 30));
        expect(preview.capturedPosition, closeTo(0, .1));
        final codec = await ui.instantiateImageCodec(preview.bytes);
        final frame = (await codec.getNextFrame()).image;
        ui.Codec? referenceCodec;
        ui.Image? reference;
        try {
          final originalWidth = name == 'first'
              ? 360
              : name == 'orientation-unrotated'
              ? 1920
              : 1080;
          final originalHeight = name == 'first'
              ? 640
              : name == 'orientation-unrotated'
              ? 1080
              : 1920;
          expect(preview.width, originalWidth, reason: '$name source width');
          expect(preview.height, originalHeight, reason: '$name source height');
          expect(
            frame.width,
            original
                ? originalWidth
                : originalWidth > originalHeight
                ? 480
                : 270,
          );
          expect(
            frame.height,
            original
                ? originalHeight
                : originalWidth > originalHeight
                ? 270
                : 480,
          );
          final file = '$name-${original ? 'original' : 'grid'}.jpg';
          results.add({
            'fixture': name,
            'originalResolution': original,
            'width': frame.width,
            'height': frame.height,
            'capturedPosition': preview.capturedPosition,
            'bytes': preview.bytes.length,
            'file': file,
          });
          if (artifacts.isNotEmpty) {
            await File('$artifacts/$file').writeAsBytes(preview.bytes);
          }
          if (name != 'first') {
            referenceCodec = await ui.instantiateImageCodec(
              await File('$fixtures/$name-reference.png').readAsBytes(),
            );
            reference = (await referenceCodec.getNextFrame()).image;
            final expected = (await reference.toByteData())!;
            final actual = (await frame.toByteData())!;
            for (final x in [.25, .75]) {
              for (final y in [.25, .75]) {
                final a =
                    ((y * frame.height).floor() * frame.width +
                        (x * frame.width).floor()) *
                    4;
                final e =
                    ((y * reference.height).floor() * reference.width +
                        (x * reference.width).floor()) *
                    4;
                for (var channel = 0; channel < 3; channel++) {
                  expect(
                    actual.getUint8(a + channel),
                    // mpv and ffmpeg use different defaults for an untagged
                    // YUV fixture; the four corners must retain their colors.
                    closeTo(expected.getUint8(e + channel), 40),
                    reason: '$name rotation pixel $x,$y channel $channel',
                  );
                }
              }
            }
          }
        } finally {
          reference?.dispose();
          referenceCodec?.dispose();
          frame.dispose();
          codec.dispose();
        }
      }
    }
    if (artifacts.isNotEmpty) {
      await File('$artifacts/results.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    }
  });
}
