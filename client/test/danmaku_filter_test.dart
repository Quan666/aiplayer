import 'dart:math';

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/filter.dart';
import 'package:aiplayer/danmaku/filter_preset.dart';
import 'package:aiplayer/danmaku/layout.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every imported keyword matches, including mixed case and emoji', () {
    expect(danmakuPresetKeywords, hasLength(2251));
    expect(danmakuPresetPatterns, hasLength(1));
    for (final word in danmakuPresetKeywords) {
      expect(
        matchesDanmakuPreset('prefix${word.toUpperCase()}suffix'),
        isTrue,
        reason: word,
      );
    }
    expect(matchesDanmakuPreset('这个镜头很漂亮'), isFalse);
    expect(matchesDanmakuPreset('music is wonderful'), isFalse);
  });

  test(
    'preset regex retains anchors, escapes and case insensitive matching',
    () {
      for (final text in ['2026年10月21', 'AV1234567', 'S.B', '前面穿蓝衣服的', '哈']) {
        expect(matchesDanmakuPreset(text), isTrue, reason: text);
      }
      expect(matchesDanmakuPreset('music is wonderful'), isFalse);
    },
  );

  test('keyword fallback and overlaps agree with literal substring matching', () {
    final random = Random(54);
    final keywords = danmakuPresetKeywords
        .map((word) => word.toLowerCase())
        .toList();
    final patterns = [
      for (final pattern in danmakuPresetPatterns)
        RegExp(pattern, caseSensitive: false),
    ];
    for (var i = 0; i < 1000; i++) {
      final word =
          danmakuPresetKeywords[random.nextInt(danmakuPresetKeywords.length)];
      final text =
          'music${word.substring(0, random.nextInt(word.length + 1))}镜头${word.toUpperCase().substring(random.nextInt(word.length + 1))}nice';
      final expected =
          keywords.any(text.toLowerCase().contains) ||
          patterns.any((pattern) => pattern.hasMatch(text));
      expect(matchesDanmakuPreset(text), expected, reason: 'sample $i');
    }
  });

  test(
    'preset filters before lane assignment and can be disabled independently',
    () {
      const comments = [
        DanmakuComment(0, 'example.COM', 0xffffff, 0),
        DanmakuComment(0, 'AV1234567', 0xffffff, 1),
        DanmakuComment(0, '自定义内容', 0xffffff, 2),
        DanmakuComment(0, '这个镜头很漂亮', 0xffffff, 0),
      ];
      expect(assignLanes(comments, 1, blockedWords: '自定义').single.index, 3);
      expect(
        assignLanes(
          comments,
          4,
          presetFilter: false,
          blockedWords: '自定义',
        ).map((item) => item.index),
        [0, 1, 3],
      );
      expect(AppPreferences({}).danmuPresetFilter, isTrue);
      final prefs = AppPreferences({'danmuBlockedWords': '保留我'});
      final patch = prefs.checkedPatch({'danmuPresetFilter': false});
      expect(AppPreferences(patch).danmuPresetFilter, isFalse);
      expect(prefs.danmuBlockedWords, '保留我');
    },
  );
}
