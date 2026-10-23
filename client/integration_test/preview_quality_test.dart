import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixtureDirectory = String.fromEnvironment(
    'PREVIEW_FIXTURE_DIR',
    defaultValue: '/tmp/aiplayer-preview-051',
  );
  const artifactDirectory = String.fromEnvironment(
    'PREVIEW_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  testWidgets('real MKV seeks skip blank frames and preserve resume accuracy', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    final artifacts = Directory(artifactDirectory)..createSync(recursive: true);
    final results = <Map<String, Object?>>[];
    for (final codec in ['h264', 'hevc10']) {
      final fixture = '$fixtureDirectory/$codec.mkv';
      expect(File(fixture).existsSync(), true);
      for (final request in [
        ('default', null),
        ('exact', 20.0),
        ('near-transition', 14.2),
      ]) {
        final started = DateTime.now();
        final preview = await captureMediaPreview(
          fixture,
          CancelToken(),
          position: request.$2,
        ).timeout(const Duration(seconds: 30));
        final captured = preview.capturedPosition!;
        if (request.$2 == null) {
          // 12% is black and 25% is white. Only the third candidate is usable.
          expect(captured, closeTo(12, .2));
        } else if (request.$1 == 'exact') {
          expect(captured, closeTo(20, .15));
        } else {
          expect(captured, inInclusiveRange(12.7, 14.0));
        }
        expect(await encodeUsablePreviewImage(preview.bytes), isNotNull);
        final file = 'preview-051-$codec-${request.$1}.jpg';
        await File('${artifacts.path}/$file').writeAsBytes(preview.bytes);
        results.add({
          'codec': codec,
          'request': request.$1,
          'requestedPosition': request.$2,
          'capturedPosition': captured,
          'elapsedMs': DateTime.now().difference(started).inMilliseconds,
          'bytes': preview.bytes.length,
          'file': file,
        });
      }
      // There is usable content at 12 and 20, but a resume at 16 must never be
      // substituted with those distant scenes. Queue callers keep their cache.
      await expectLater(
        captureMediaPreview(fixture, CancelToken(), position: 16),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('保留已有封面'),
          ),
        ),
      );
    }
    final cancelled = CancelToken()..cancel();
    await expectLater(
      captureMediaPreview('$fixtureDirectory/h264.mkv', cancelled),
      throwsA(isA<Cancelled>()),
    );
    await File(
      '${artifacts.path}/preview-quality-051.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
