import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/subtitles/choice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Generate the default fixture with scripts/make_pgs_fixture.py. To exercise a
// real local MKV instead, pass --dart-define=PGS_FIXTURE=/path/to/movie.mkv and
// --dart-define=PGS_POSITION_SECONDS=22 (a time when both tracks have a cue).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment(
    'PGS_FIXTURE',
    defaultValue: '/tmp/aiplayer-pgs-fixture.mkv',
  );
  final position = Duration(
    milliseconds:
        (double.parse(
                  const String.fromEnvironment(
                    'PGS_POSITION_SECONDS',
                    defaultValue: '2',
                  ),
                ) *
                1000)
            .round(),
  );

  for (final preference in ['zh-Hans', 'zh-Hant']) {
    testWidgets(
      'native PGS renders with $preference preference and automatic simplification enabled',
      (tester) async {
        MediaKit.ensureInitialized();
        FlutterSecureStorage.setMockInitialValues({});
        expect(
          await File(fixture).exists(),
          true,
          reason: 'Run python3 scripts/make_pgs_fixture.py before this test.',
        );
        final root = await Directory.systemTemp.createTemp('aiplayer-pgs-');
        final model = AppModel(AppStore('${root.path}/library.db'), root);
        final id = await model.importFile(fixture);
        await model.updatePreferences({
          'autoPlay': false,
          'hardwareDecoding': false,
          'subtitleSimplify': true,
          'subtitleLanguage': preference,
          'subtitlesEnabled': true,
          'autoLoadExternalSubtitles': false,
          'enterFullscreen': false,
          'danmuVisible': false,
        });
        final session = PlaybackSession(model, model.store.get('media', id)!);
        final taskErrors = <String>[];
        var attemptedTextTransformation = false;
        void observeSubtitleWork() {
          attemptedTextTransformation |= session.subtitleTaskBusy;
          if (session.subtitleTaskError.isNotEmpty) {
            taskErrors.add(session.subtitleTaskError);
          }
        }

        session.addListener(observeSubtitleWork);

        Future<void> waitFor(bool Function() condition, String reason) async {
          for (var i = 0; i < 100 && !condition(); i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(condition(), true, reason: reason);
        }

        Future<int> subtitlePixelDifference() async {
          final withSub = image.decodeJpg(await session.captureScreenshot())!;
          final withoutSub = image.decodeJpg(
            await session.captureScreenshot(includeSubtitles: false),
          )!;
          expect(withSub.width, withoutSub.width);
          expect(withSub.height, withoutSub.height);
          var different = 0;
          for (var y = withSub.height ~/ 2; y < withSub.height; y++) {
            for (var x = 0; x < withSub.width; x++) {
              final a = withSub.getPixel(x, y);
              final b = withoutSub.getPixel(x, y);
              if ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs() >
                  100) {
                different++;
              }
            }
          }
          return different;
        }

        Future<void> expectVisible(String reason) async {
          var different = 0;
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            different = await subtitlePixelDifference();
            if (different > 150) break;
          }
          expect(different, greaterThan(150), reason: reason);
          expect(session.selectedSubtitleIsImage, true);
          expect(session.hasSubtitleForTools, false);
          expect(session.subtitleTransformed, false);
          expect(session.subtitleTaskError, isEmpty);
          expect(taskErrors, isEmpty);
          expect(attemptedTextTransformation, false);
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Video(
                  controller: session.video,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                  controls: NoVideoControls,
                ),
              ),
            ),
          );
          final native = session.player.platform as NativePlayer;
          await native.setProperty('ao', 'null');
          await session.open();
          expect(session.ready, true, reason: session.error);
          expect(session.player.state.playing, false);
          await session.video.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 20),
          );
          final wantedTitle = preference == 'zh-Hans'
              ? 'Japanese-CHS[NEST]'
              : 'Japanese-CHT[NEST]';
          await waitFor(
            () => session.player.state.tracks.subtitle.any(
              (track) =>
                  track.title == wantedTitle &&
                  track.id == session.player.state.track.subtitle.id,
            ),
            'The $preference preference must select $wantedTitle.',
          );
          final tracks = session.player.state.tracks.subtitle
              .where(
                (track) =>
                    isImageSubtitle(image: track.image, codec: track.codec),
              )
              .toList();
          expect(tracks.length, greaterThanOrEqualTo(2));
          final original = tracks.firstWhere((t) => t.title == wantedTitle);
          final other = tracks.firstWhere(
            (t) =>
                t.title ==
                (preference == 'zh-Hans'
                    ? 'Japanese-CHT[NEST]'
                    : 'Japanese-CHS[NEST]'),
          );
          expect(original.language, anyOf('chi', 'zh', 'zho'));
          await session.player.seek(position);
          await expectVisible('PGS must render while initially paused.');

          // Seek away and back so the bitmap decoder must recover its state.
          await session.player.seek(Duration.zero);
          await tester.pump(const Duration(milliseconds: 200));
          await session.player.seek(position);
          await expectVisible('PGS must render again after seeking.');

          await session.selectSubtitle(other);
          await session.player.seek(position);
          await waitFor(
            () => session.player.state.track.subtitle.id == other.id,
            'The other PGS track must become selected.',
          );
          await expectVisible('Switching scripts must keep bitmap rendering.');

          await session.selectSubtitle(SubtitleTrack.no());
          await waitFor(
            () => session.player.state.track.subtitle.id == 'no',
            'Selecting no subtitles must disable the PGS track.',
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(await subtitlePixelDifference(), 0);
          await session.selectSubtitle(original);
          await session.player.seek(position);
          await expectVisible('PGS must return after disabling and restoring.');

          await session.updateSettings({'subtitlesEnabled': false});
          await tester.pump(const Duration(milliseconds: 300));
          expect(await subtitlePixelDifference(), 0);
          await session.updateSettings({'subtitlesEnabled': true});
          await expectVisible('The visibility setting must restore PGS.');
          expect(session.player.state.playing, false);
          expect(session.error, isEmpty);
        } finally {
          session.removeListener(observeSubtitleWork);
          await session.close();
          await tester.pumpWidget(const SizedBox.shrink());
          model.dispose();
          model.store.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
