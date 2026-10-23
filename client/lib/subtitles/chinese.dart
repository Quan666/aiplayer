import 'package:flutter/services.dart';
import 'document.dart';

class _Node {
  final children = <int, _Node>{};
  String? value;
}

/// OpenCC 1.1.9 t2s dictionary, longest phrases before individual characters.
/// Data and Apache 2.0 license are included under assets/opencc/.
class ChineseConverter {
  final _root = _Node();
  ChineseConverter.fromDictionaries(Iterable<String> dictionaries) {
    for (final dictionary in dictionaries) {
      for (final line in dictionary.split('\n')) {
        if (line.startsWith('#')) continue;
        final fields = line.trim().split('\t');
        if (fields.length != 2 || fields.first.isEmpty) continue;
        var node = _root;
        for (final rune in fields.first.runes) {
          node = node.children.putIfAbsent(rune, _Node.new);
        }
        node.value = fields.last.split(' ').first;
      }
    }
  }
  static Future<ChineseConverter>? _shared;
  static Future<ChineseConverter> load() => _shared ??= () async {
    return ChineseConverter.fromDictionaries(
      await Future.wait(
        [
          'TSCharacters.txt',
          'TSPhrases.txt',
        ].map((f) => rootBundle.loadString('assets/opencc/$f')),
      ),
    );
  }();
  String convert(String text) {
    final runes = text.runes.toList(), out = StringBuffer();
    for (var offset = 0; offset < runes.length;) {
      var node = _root, end = offset;
      String? replacement;
      for (var i = offset; i < runes.length; i++) {
        final next = node.children[runes[i]];
        if (next == null) break;
        node = next;
        if (node.value != null) {
          replacement = node.value;
          end = i + 1;
        }
      }
      if (replacement == null) {
        out.writeCharCode(runes[offset++]);
      } else {
        out.write(replacement);
        offset = end;
      }
    }
    return out.toString();
  }

  String document(SubtitleDocument document) => document.render({
    for (final cue in document.cues) cue.id: convert(cue.text),
  });
}
