import 'filter_preset.dart';

// Build the keyword automaton once. Scanning every keyword or one huge regex
// stalls lane allocation on large snapshots; failure links keep scanning linear.
final _presetKeywords = _KeywordMatcher(danmakuPresetKeywords);
final _presetExpressions = [
  for (final pattern in danmakuPresetPatterns)
    RegExp(pattern, caseSensitive: false),
];

bool matchesDanmakuPreset(String text) =>
    _presetKeywords.matches(text) ||
    _presetExpressions.any((expression) => expression.hasMatch(text));

class _KeywordNode {
  final next = <int, _KeywordNode>{};
  late _KeywordNode fallback;
  bool terminal = false;
}

class _KeywordMatcher {
  final root = _KeywordNode();

  _KeywordMatcher(Iterable<String> words) {
    root.fallback = root;
    for (final word in words) {
      if (word.isEmpty) continue;
      var node = root;
      for (final unit in word.toLowerCase().codeUnits) {
        node = node.next.putIfAbsent(unit, _KeywordNode.new);
      }
      node.terminal = true;
    }
    final pending = root.next.values.toList();
    for (final node in pending) {
      node.fallback = root;
    }
    for (var i = 0; i < pending.length; i++) {
      final node = pending[i];
      for (final edge in node.next.entries) {
        var fallback = node.fallback;
        while (!identical(fallback, root) &&
            !fallback.next.containsKey(edge.key)) {
          fallback = fallback.fallback;
        }
        final child = edge.value;
        child.fallback = fallback.next[edge.key] ?? root;
        child.terminal = child.terminal || child.fallback.terminal;
        pending.add(child);
      }
    }
  }

  bool matches(String text) {
    var node = root;
    for (final unit in text.toLowerCase().codeUnits) {
      while (!identical(node, root) && !node.next.containsKey(unit)) {
        node = node.fallback;
      }
      node = node.next[unit] ?? root;
      if (node.terminal) return true;
    }
    return false;
  }
}
