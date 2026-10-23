import 'dart:async';
import 'dart:convert';

import 'package:aiplayer/core/json_work.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('large JSON yields to event processing and preserves its payload', () async {
    final expected = {'rows': List.generate(12000, (i) => {'id': i, 'text': '弹幕 $i'})};
    final encoded = jsonEncode(expected);
    var eventRan = false;
    Timer.run(() => eventRan = true);
    final value = await decodeJson(encoded);
    expect(eventRan, isTrue);
    expect(value, expected);
    await expectLater(decodeJson('${List.filled(64 * 1024, ' ').join()}{broken'), throwsFormatException);
    expect(await decodeJson('{"ok":true}'), {'ok': true});
  });

  test('large comment normalization and disk roundtrip preserve stable order', () async {
    final input = [
      for (var i = 0; i < 12000; i++)
        {'time': (i % 41) / 2, 'text': ' 第 $i 条\n弹幕 ', 'color': '#FF8800', 'mode': i % 3, 'userId': 'user-$i'},
      {'time': -1, 'text': 'invalid'},
      {'time': 1, 'text': ''},
    ];
    final expected = normalizeComments(input);
    final comments = await normalizeCommentsAsync(input);
    expect(comments, expected);
    final encoded = await encodeComments(comments);
    expect(await decodeCachedComments(encoded), expected);
    expect(await decodeCachedComments('[]'), isNull);
    expect(await decodeCachedComments('{}'), isNull);
    await expectLater(decodeCachedComments('{broken'), throwsFormatException);
  });
}
