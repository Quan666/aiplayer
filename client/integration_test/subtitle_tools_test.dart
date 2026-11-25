import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/range_bridge.dart';
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
    'native player loads, simplifies and translates large WebDAV ASS',
    (tester) async {
      MediaKit.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({
        'aiSubtitleToken': 'mock-key',
      });
      final movie = File(fixture);
      final size = await movie.length();
      final root = await Directory.systemTemp.createTemp(
        'aiplayer-webdav-ass-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subtitleRequests = <(String, String?)>[];
      final aiRequests = <Object?>[];
      final padding = utf8.encode((';${' ' * 1022}\n') * 1024);
      server.listen((request) async {
        final response = request.response;
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (request.method == 'POST' &&
            request.uri.path == '/v1/chat/completions') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final message = (body['messages'] as List).last as Map;
          aiRequests.add(jsonDecode(message['content'] as String));
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content': jsonEncode([
                      {'id': 0, 'text': '⟦S0⟧模拟翻译弹幕'},
                    ]),
                  },
                },
              ],
            }),
          );
        } else if (request.method == 'PROPFIND') {
          response.statusCode = 207;
          response.write(
            '<d:multistatus xmlns:d="DAV:"><d:response>'
            '<d:href>/dav/Episode.ass</d:href></d:response></d:multistatus>',
          );
        } else if (request.uri.path == '/dav/Episode.ass') {
          subtitleRequests.add((request.method, rangeHeader));
          if (request.method != 'GET' || rangeHeader != null) {
            response.statusCode = HttpStatus.methodNotAllowed;
          } else {
            response.add(
              utf8.encode(
                '[Script Info]\nScriptType: v4.00+\n'
                '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, '
                'MarginR, MarginV, Effect, Text\n'
                'Dialogue: 0,0:00:00.00,0:00:29.00,Default,,0,0,0,,'
                '{\\move(640,50,0,50)}外掛彈幕回歸\n',
              ),
            );
            await response.addStream(
              Stream.fromIterable(List.filled(17, padding)),
            );
          }
        } else if (request.uri.path == '/dav/Episode.mkv') {
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          if (request.method == 'HEAD') {
            response.contentLength = size;
          } else {
            final range = ByteRange.parse(rangeHeader, size)!;
            response.statusCode = HttpStatus.partialContent;
            response.contentLength = range.length;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes ${range.start}-${range.end}/$size',
            );
            await response.addStream(
              movie.openRead(range.start, range.end + 1),
            );
          }
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final store = AppStore('${root.path}/library.db');
      final model = AppModel(store, root, backgroundWork: false);
      store.setLocal('sources', [
        {
          'id': 'dav',
          'kind': 'webdav',
          'url': 'http://127.0.0.1:${server.port}/dav/',
        },
      ]);
      await model.updatePreferences({
        'autoPlay': false,
        'hardwareDecoding': false,
        'subtitleSimplify': false,
        'autoLoadExternalSubtitles': true,
      });
      await model.setSettings({
        'aiSubtitleOrigin': 'http://127.0.0.1:${server.port}/v1',
        'aiSubtitleModel': 'mock',
      });
      final media = await model.prepareSourceMediaForPlayback(
        'dav',
        SourceEntry(name: 'Episode.mkv', path: 'Episode.mkv', size: size),
      );
      final session = PlaybackSession(model, media);
      try {
        await tester.pumpWidget(
          MaterialApp(home: Video(controller: session.video)),
        );
        final native = session.player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await session.open();
        expect(session.ready, true, reason: session.error);
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
        await session.player.seek(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('外掛彈幕回歸'));
        await session.simplifySubtitle();
        expect(
          session.subtitleTaskStatus,
          '已转换为简体',
          reason: session.subtitleTaskError,
        );
        await session.player.seek(const Duration(seconds: 3));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('外挂弹幕回归'));
        await session.translateSubtitle();
        expect(
          session.subtitleTaskStatus,
          '翻译完成',
          reason: session.subtitleTaskError,
        );
        await session.player.seek(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await native.getProperty('sub-text'), contains('模拟翻译弹幕'));
        expect(aiRequests.single, {
          'targetLanguage': '简体中文',
          'previousContext': [],
          'cues': [
            {'id': 0, 'text': '⟦S0⟧外掛彈幕回歸'},
          ],
        });
        final outputs = Directory('${root.path}/subtitle-cache').list();
        await for (final entity in outputs) {
          expect(
            await (entity as File).length(),
            greaterThan(16 * 1024 * 1024),
          );
        }
        expect(subtitleRequests, [('GET', null)]);
      } finally {
        await session.close();
        await model.flushPlaybackPreviews();
        await tester.pumpWidget(const SizedBox.shrink());
        await server.close(force: true);
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
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
