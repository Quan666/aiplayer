import 'dart:io';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:image/image.dart' as image;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment(
    'MEDIA_FIXTURE',
    defaultValue: '/tmp/aiplayer-media-fixture/Example S01E01.mkv',
  );
  testWidgets(
    'real external and indexed MKV subtitles render Chinese and convert without losing ASS styles',
    (tester) async {
      MediaKit.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('aiplayer-subtitles-');
      final movie = await File(fixture).copy('${root.path}/動畫 01.mkv');
      final external = File('${root.path}/動畫 01.ass');
      await external.writeAsString(
        '[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Noto Sans SC,32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:30.00,Default,,0,0,0,,{\\c&H00FFFF&}繁體字幕 · 臺灣與龍貓\n',
      );
      await File('${root.path}/動畫 01.en.srt').writeAsString(
        '1\n00:00:00,000 --> 00:00:30,000\nWrong English candidate\n',
      );
      final plainChinese = File('${root.path}/動畫 01.zh-Hans.srt');
      await plainChinese.writeAsString(
        '1\n00:00:00,000 --> 00:00:30,000\n中文字幕 · Android 字体测试\n',
      );
      await File(
        '${root.path}/動畫 010.chs.srt',
      ).writeAsString('1\n00:00:00,000 --> 00:00:30,000\n错误集数\n');
      final model = AppModel(AppStore('${root.path}/library.db'), root);
      final id = await model.importFile(movie.path),
          media = model.store.get('media', id)!;
      await model.updatePreferences({
        'autoPlay': false,
        'hardwareDecoding': false,
        'subtitleSimplify': false,
        'autoLoadExternalSubtitles': true,
        'enterFullscreen': false,
      });
      final session = PlaybackSession(model, media);
      Future<List<int>> expectVisibleSubtitle(String reason) async {
        final withSub = await session.captureScreenshot(),
            withoutSub = await session.captureScreenshot(
              includeSubtitles: false,
            );
        final a = image.decodeJpg(withSub)!, b = image.decodeJpg(withoutSub)!;
        var different = 0;
        for (var y = a.height ~/ 2; y < a.height; y++) {
          for (var x = 0; x < a.width; x++) {
            final p = a.getPixel(x, y), q = b.getPixel(x, y);
            if ((p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs() >
                100) {
              different++;
            }
          }
        }
        expect(different, greaterThan(150), reason: reason);
        return withSub;
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
        await session.video.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
        for (
          var i = 0;
          i < 100 && session.subtitleTaskStatus != '外挂字幕已加载';
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          session.subtitleTaskStatus,
          '外挂字幕已加载',
          reason: session.subtitleTaskError,
        );
        expect(session.externalSubtitles.first.name, '動畫 01.ass');
        // Recreate the subtitle decoder under Android's font conditions.
        // System fallback and the MKV's attached font must not hide a broken
        // bundled-font family. SRT also exercises its default Arial style.
        await native.setProperty('sub-font-provider', 'none');
        await native.setProperty('embeddedfonts', 'no');
        await session.loadSubtitle(await LocalSource().stat(plainChinese.path));
        await session.player.seek(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-font-provider'), 'none');
        expect(await native.getProperty('embeddedfonts'), 'no');
        expect(await native.getProperty('sub-text'), contains('中文字幕'));
        final fallbackScreenshot = await expectVisibleSubtitle(
          'Bundled fonts must render SRT without system or attached fonts.',
        );
        final artifacts = Directory('/root/aiplayer/artifacts');
        await artifacts.create(recursive: true);
        await File(
          '${artifacts.path}/subtitles_chinese_fallback.jpg',
        ).writeAsBytes(fallbackScreenshot);
        await session.loadSubtitle(await LocalSource().stat(external.path));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('繁體字幕'));
        await session.simplifySubtitle();
        expect(session.subtitleTaskError, isEmpty);
        expect(session.subtitleTransformed, true);
        await session.player.seek(const Duration(seconds: 3));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('繁体字幕'));
        expect(await native.getProperty('sub-text'), contains('台湾与龙猫'));
        final withSub = await expectVisibleSubtitle(
          'Styled ASS must render with the bundled fallback font.',
        );
        await File(
          '${artifacts.path}/subtitles_chinese_simplified.jpg',
        ).writeAsBytes(withSub);
        await session.restoreOriginalSubtitle();
        await session.player.seek(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('繁體字幕'));
        // The original embedded ASS remains available alongside external tracks.
        await native.setProperty('embeddedfonts', 'yes');
        final embedded = session.player.state.tracks.subtitle.firstWhere(
          (t) => t.id == '1',
        );
        await session.selectSubtitle(embedded);
        await tester.pump(const Duration(milliseconds: 300));
        await expectVisibleSubtitle(
          'Re-enabling font attachments must preserve embedded ASS rendering.',
        );
        await session.simplifySubtitle();
        expect(
          session.subtitleTaskError,
          isEmpty,
          reason: 'Real indexed MKV extraction should succeed.',
        );
        expect(session.subtitleTransformed, true);
        await session.player.seek(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('字幕样式验证'));
        await session.loadSubtitle(await LocalSource().stat(external.path));
        final converting = session.simplifySubtitle();
        session.cancelSubtitleTask();
        await converting;
        expect(session.subtitleTaskBusy, false);
      } finally {
        final closing = session.close();
        expect(
          identical(closing, session.close()),
          true,
          reason: 'Replacement and route disposal must share native teardown.',
        );
        await closing;
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        model.store.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
