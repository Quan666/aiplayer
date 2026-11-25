import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/subtitles/chinese.dart';
import 'package:aiplayer/subtitles/choice.dart';
import 'package:aiplayer/subtitles/document.dart';
import 'package:aiplayer/subtitles/io.dart';
import 'package:aiplayer/subtitles/mkv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large WebDAV subtitles download with a plain GET across redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final directory = await Directory.systemTemp.createTemp('webdav-ass-');
      final file = File('${directory.path}/episode.ass');
      final requests = <(String, String, String?)>[];
      final padding = Uint8List(1024 * 1024);
      final subtitle = utf8.encode(
        '[Events]\nFormat: Start, End, Text\n'
        'Dialogue: 0:00:00.00,0:00:05.00,{\\move(640,50,0,50)}弹幕\n',
      );
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        requests.add((request.method, request.uri.pathSegments.last, range));
        final response = request.response;
        if (request.method != 'GET' || range != null) {
          response.statusCode = HttpStatus.methodNotAllowed;
        } else if (request.uri.pathSegments.first == 'dav') {
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            '/download?key=a%2Bb',
          );
        } else if (request.uri.query == 'key=a%2Bb') {
          response.add(subtitle);
          await response.addStream(
            Stream.fromIterable(List.filled(17, padding)),
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/dav/',
        webdav: true,
      );
      try {
        await downloadExternalSubtitle(
          source,
          '作品 01.ass',
          file,
          CancelToken(),
        );
        expect(await file.length(), subtitle.length + 17 * padding.length);
        final input = await file.open();
        try {
          expect(await input.read(subtitle.length), subtitle);
        } finally {
          await input.close();
        }
        expect(requests, [
          ('GET', '作品 01.ass', null),
          ('GET', 'download', null),
        ]);
      } finally {
        await source.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'a cancelled subtitle download stops waiting for the response body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final directory = await Directory.systemTemp.createTemp('cancel-ass-');
      final file = File('${directory.path}/episode.ass');
      server.listen((request) async {
        final response = request.response..bufferOutput = false;
        response.add(utf8.encode('[Script Info]'));
        await response.flush();
        // Leave the body open while the client waits for the rest.
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/');
      final cancel = CancelToken();
      try {
        final transfer = expectLater(
          downloadExternalSubtitle(source, 'episode.ass', file, cancel),
          throwsA(isA<Cancelled>()),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!await file.exists() || await file.length() == 0) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Subtitle bytes did not arrive.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        cancel.cancel();
        await transfer.timeout(const Duration(seconds: 5));
      } finally {
        cancel.cancel();
        await source.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );

  test('Chinese preference includes scripts, ISO codes and Chinese names', () {
    expect(chineseVariant('zho', null), 'zh');
    expect(chineseVariant('zh-TW', null), 'zh-Hant');
    expect(chineseVariant(null, 'CHS'), 'zh-Hans');
    expect(chineseVariant('eng', '繁體中文'), 'zh-Hant');
    expect(
      subtitleLanguageRank('zh-Hans', null, 'zh-Hans'),
      greaterThan(
        subtitleLanguageRank('eng', null, 'zh-Hans', isDefault: true),
      ),
    );
    expect(
      subtitleLanguageRank('zh-Hans', null, 'zh-Hans'),
      greaterThan(
        subtitleLanguageRank('chi', null, 'zh-Hans', isDefault: true),
      ),
    );
    expect(mpvSubtitleLanguages('zh-Hans'), contains('chi'));
  });
  test('bracketed CHS and CHT tags identify and rank Chinese scripts', () {
    for (final prefix in ['Japanese-', 'Mandarin-']) {
      final simplified = '${prefix}CHS[NEST]';
      final traditional = '${prefix}CHT[NEST]';
      expect(chineseVariant('chi', simplified), 'zh-Hans');
      expect(chineseVariant('chi', traditional), 'zh-Hant');
      expect(shouldAutomaticallySimplifySubtitle('chi', simplified), false);
      expect(shouldAutomaticallySimplifySubtitle('chi', traditional), true);
      expect(
        subtitleLanguageRank('chi', traditional, 'zh-Hant'),
        greaterThan(
          subtitleLanguageRank('chi', simplified, 'zh-Hant', isDefault: true),
        ),
      );
    }
    for (final tag in ['[CHS]', '(chs)', 'CHS[NEST]']) {
      expect(chineseVariant(null, tag), 'zh-Hans', reason: tag);
    }
    for (final tag in ['[CHT]', '(cht)', 'CHT[NEST]']) {
      expect(chineseVariant(null, tag), 'zh-Hant', reason: tag);
    }
    for (final word in ['CHSimple', 'CHTraditional', 'OrCHStra', 'CHS2']) {
      expect(chineseVariant(null, word), isNull, reason: word);
    }
  });
  test('image subtitles are detected from either metadata or codec', () {
    expect(isImageSubtitle(image: true), true);
    for (final codec in [
      'hdmv_pgs_subtitle',
      'PGS',
      'dvd_subtitle',
      'dvb_subtitle',
      'S_HDMV/PGS',
    ]) {
      expect(isImageSubtitle(codec: codec), true, reason: codec);
      expect(isImageSubtitle(image: false, codec: codec), true, reason: codec);
    }
    for (final codec in ['ass', 'ssa', 'subrip', 'webvtt', 'S_TEXT/UTF8']) {
      expect(isImageSubtitle(codec: codec), false, reason: codec);
      expect(isImageSubtitle(image: true, codec: codec), true, reason: codec);
    }
    expect(isImageSubtitle(), false);
    expect(isImageSubtitle(image: false), false);
  });
  test(
    'automatic simplification leaves Japanese and English tracks intact',
    () {
      expect(shouldAutomaticallySimplifySubtitle('jpn', 'Japanese'), false);
      expect(shouldAutomaticallySimplifySubtitle('eng', 'English'), false);
      expect(shouldAutomaticallySimplifySubtitle(null, '作品 01.ja.ass'), false);
      expect(shouldAutomaticallySimplifySubtitle('zh-Hans', '简体字幕'), false);
      expect(shouldAutomaticallySimplifySubtitle('zh-Hant', '繁體字幕'), true);
      expect(shouldAutomaticallySimplifySubtitle(null, '作品 01.ass'), true);
    },
  );
  test(
    'external exact stem wins; language suffixes do not match another episode',
    () {
      expect(
        externalSubtitleRank('作品 01.mkv', '作品 01.ass', 'zh-Hans'),
        greaterThan(
          externalSubtitleRank('作品 01.mkv', '作品 01.chs.ass', 'zh-Hans'),
        ),
      );
      expect(
        externalSubtitleRank('作品 01.mkv', '作品 010.chs.ass', 'zh-Hans'),
        -1,
      );
      expect(
        externalSubtitleRank('作品 01.mkv', '作品 01 2.chs.ass', 'zh-Hans'),
        -1,
      );
      expect(
        externalSubtitleRank('作品 01.mkv', '作品 01.zh-Hans.ass', 'zh-Hans'),
        greaterThan(100),
      );
      expect(
        externalSubtitleRank('作品 01.mkv', '作品 01.chs&eng.ass', 'zh-Hans'),
        greaterThan(100),
      );
    },
  );
  const ass =
      '[Script Info]\r\nTitle: 原始\r\n[V4+ Styles]\r\nStyle: Default,字體,40\r\n[Events]\r\nFormat: Layer, Start, End, Style, Text\r\nDialogue: 0,0:00:01.00,0:00:02.00,Default,{\\pos(20,30)}繁體\\N字幕\r\nComment: 0,0:00:01.00,0:00:02.00,Default,不要修改\r\nDialogue: 1,0:00:01.00,0:00:02.00,Default,{\\p1}m 0 0 l 10 10{\\p0}圖畫\r\n';
  test(
    'ASS transformations preserve timing, styles, drawing commands and line endings',
    () {
      final document = SubtitleDocument(ass, 'ass');
      expect(document.cues.length, 2);
      expect(document.cues.first.text, '⟦S0⟧繁體⟦S1⟧字幕');
      final output = document.render({
        0: '⟦S0⟧简体⟦S1⟧字幕',
        1: document.cues[1].text.replaceAll('圖畫', '图画'),
      });
      expect(output, ass.replaceAll('繁體', '简体').replaceAll('圖畫', '图画'));
      expect(() => document.render({0: '丢失标记'}), throwsA(isA<AppFailure>()));
      expect(
        () => document.render({0: '⟦S0⟧恶意{\\p1}⟦S1⟧'}),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => document.render({0: '⟦S1⟧乱序⟦S0⟧'}),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test(
    'SRT and VTT preserve cue identifiers, inline tags, settings and metadata',
    () {
      const vtt =
          'WEBVTT\n\nNOTE 原始\n备注\n\nSTYLE\n::cue {color: lime}\n\nscene-1\n00:01.000 --> 00:02.000 align:start line:90%\n<i>繁體</i>\n第二行\n\n';
      final document = SubtitleDocument(vtt, 'vtt');
      expect(document.cues.length, 1);
      final output = document.render({
        0: document.cues.first.text.replaceAll('繁體', '简体'),
      });
      expect(output, vtt.replaceAll('繁體', '简体'));
      final srt = SubtitleDocument(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\n第一行\r\n第二行\r\n',
        'srt',
      );
      expect(
        srt.render({0: srt.cues.first.text.replaceAll('第一行', 'changed')}),
        contains('changed\r\n第二行'),
      );
    },
  );
  test(
    'Unicode decoding and malformed text reject without replacement characters',
    () {
      expect(decodeSubtitle(Uint8List.fromList([255, 254, 0x2d, 0x4e])), '中');
      expect(decodeSubtitle(Uint8List.fromList([254, 255, 0x4e, 0x2d])), '中');
      expect(
        () => decodeSubtitle(Uint8List.fromList([0xc0, 0x80])),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => SubtitleDocument('<html>login</html>', 'srt'),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('actual OpenCC data applies longest phrases only to dialogue', () async {
    final converter = ChineseConverter.fromDictionaries([
      await File('assets/opencc/TSCharacters.txt').readAsString(),
      await File('assets/opencc/TSPhrases.txt').readAsString(),
    ]);
    expect(converter.convert('繁體字幕，臺灣與龍貓'), '繁体字幕，台湾与龙猫');
    final converted = converter.document(SubtitleDocument(ass, 'ass'));
    expect(converted, contains('Style: Default,字體,40'));
    expect(converted, contains(r'{\pos(20,30)}繁体\N字幕'));
    expect(converted, contains(r'{\p1}m 0 0 l 10 10{\p0}图画'));
  });

  final fixtures =
      jsonDecode(File('test/fixtures/mkv_subtitles.json').readAsStringSync())
          as Map;
  Future<MkvSubtitle> extract(
    String name, {
    CancelToken? token,
    List<(int, int)>? requests,
  }) async {
    final f = fixtures[name] as Map, data = base64Decode(f['bytes'] as String);
    final gap = f['gap'] as int, cluster = f['cluster'] as int;
    return extractMkvSubtitle(
      fileSize: data.length + gap,
      subtitleIndex: 0,
      cancel: token ?? CancelToken(),
      read: (offset, length) async {
        requests?.add((offset, length));
        return Uint8List.fromList(
          List.generate(length, (i) {
            final p = offset + i;
            return gap == 0 || p < cluster - gap
                ? data[p]
                : p >= cluster
                ? data[p - gap]
                : 0;
          }),
        );
      },
    );
  }

  test(
    'indexed ASS keeps comma text, layer, styles and original ReadOrder',
    () async {
      final output = await extract('ass');
      expect(output.text, contains('Style: Default,Example,48'));
      expect(
        output.text.indexOf(',first'),
        lessThan(output.text.indexOf(',late,comma')),
      );
      expect(output.text, contains('Dialogue: 2,0:00:00.50,0:00:02.70'));
      expect(output.text, contains('Dialogue: 0,0:00:01.25,0:00:03.45'));
      expect(SubtitleDocument(output.text, output.format).cues.length, 2);
    },
  );
  test('indexed UTF-8 becomes VTT with precise timings', () async {
    final output = await extract('utf8');
    expect(output.format, 'vtt');
    expect(output.text, contains('00:00:00.500 --> 00:00:02.700\n繁體文字'));
  });
  test(
    'unknown lengths, duplicate cues, wide track and simple blocks work',
    () async {
      for (final kind in ['unknown', 'duplicate', 'wide_track', 'simple']) {
        final output = await extract(kind);
        expect(
          SubtitleDocument(output.text, output.format).cues.length,
          2,
          reason: kind,
        );
      }
    },
  );
  test('5 GiB file is extracted through bounded indexed ranges', () async {
    final requests = <(int, int)>[];
    final output = await extract('sparse', requests: requests);
    expect(output.text, contains('late,comma'));
    expect(requests.any((r) => r.$1 > 0xffffffff), true);
    expect(requests.fold<int>(0, (sum, r) => sum + r.$2), lessThan(10000));
  });
  test('track scale and codec delay are applied once', () async {
    final output = await extract('scale');
    expect(output.text, contains('0:00:01.40,0:00:05.80'));
  });
  for (final kind in [
    'no_index',
    'no_relative',
    'compressed',
    'lacing',
    'pgs',
    'truncated_duration',
  ]) {
    test(
      'unsupported $kind returns actionable error instead of reading movie',
      () async {
        await expectLater(extract(kind), throwsA(isA<AppFailure>()));
      },
    );
  }
  test('cancelled MKV extraction makes no range requests', () async {
    final token = CancelToken()..cancel(), requests = <(int, int)>[];
    await expectLater(
      extract('ass', token: token, requests: requests),
      throwsA(isA<Cancelled>()),
    );
    expect(requests, isEmpty);
  });
}
