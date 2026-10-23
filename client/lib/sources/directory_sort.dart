import 'package:path/path.dart' as p;
import 'source.dart';

class DirectorySort {
  final String field;
  final bool descending, showSubtitles;
  const DirectorySort({
    this.field = 'name',
    this.descending = false,
    this.showSubtitles = false,
  });
  factory DirectorySort.fromJson(dynamic value) {
    final map = value is Map ? value : const {};
    final field = map['field'];
    return DirectorySort(
      field: ['name', 'modified', 'size', 'type'].contains(field)
          ? field
          : 'name',
      descending: map['descending'] == true,
      showSubtitles: map['showSubtitles'] == true,
    );
  }
  Map<String, dynamic> toJson() => {
    'field': field,
    'descending': descending,
    'showSubtitles': showSubtitles,
  };
  DirectorySort copyWith({
    String? field,
    bool? descending,
    bool? showSubtitles,
  }) => DirectorySort(
    field: field ?? this.field,
    descending: descending ?? this.descending,
    showSubtitles: showSubtitles ?? this.showSubtitles,
  );
  List<SourceEntry> apply(
    Iterable<SourceEntry> entries, {
    bool hideHiddenFiles = true,
  }) {
    final result = entries
        .where(
          (entry) =>
              (!hideHiddenFiles || !isHiddenEntry(entry)) &&
              (showSubtitles || entry.directory || !isSubtitle(entry.name)),
        )
        .toList();
    // Parse each name only once per listing. Comparisons otherwise allocate
    // regex matches and digit chunks O(n log n) times on the UI isolate.
    final names = <String, _NaturalName>{};
    final extensions = <String, String>{};
    int compareNames(String a, String b) => names
        .putIfAbsent(a, () => _NaturalName(a))
        .compareTo(names.putIfAbsent(b, () => _NaturalName(b)));
    String extension(String name) =>
        extensions.putIfAbsent(name, () => p.extension(name).toLowerCase());
    result.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      final compared = switch (field) {
        'modified' => a.modified.compareTo(b.modified),
        'size' => a.size.compareTo(b.size),
        'type' => extension(a.name).compareTo(extension(b.name)),
        _ => compareNames(a.name, b.name),
      };
      final tied = compared == 0 ? compareNames(a.name, b.name) : compared;
      return descending ? -tied : tied;
    });
    return result;
  }
}

bool isHiddenEntry(SourceEntry entry) {
  final name = entry.name.toLowerCase();
  return entry.hidden ||
      name.startsWith('.') ||
      const {
        'system volume information',
        '\$recycle.bin',
        'recycler',
        'recycled',
        'desktop.ini',
        'thumbs.db',
        '@eadir',
        '#recycle',
      }.contains(name);
}

int naturalNameCompare(String a, String b) =>
    _NaturalName(a).compareTo(_NaturalName(b));

class _NaturalName {
  static final _chunks = RegExp(r'\d+|\D+');
  final String original;
  final List<({String text, String? number})> parts;

  _NaturalName(this.original)
    : parts = _chunks.allMatches(original.toLowerCase()).map((match) {
        final text = match[0]!;
        final first = text.codeUnitAt(0);
        String? number;
        if (first >= 48 && first <= 57) {
          var start = 0;
          while (start < text.length && text.codeUnitAt(start) == 48) {
            start++;
          }
          number = text.substring(start);
        }
        return (text: text, number: number);
      }).toList();

  int compareTo(_NaturalName other) {
    for (var i = 0; i < parts.length && i < other.parts.length; i++) {
      final x = parts[i], y = other.parts[i];
      final nx = x.number, ny = y.number;
      final result = nx != null && ny != null
          ? nx.length == ny.length
                ? nx.compareTo(ny)
                : nx.length.compareTo(ny.length)
          : x.text.compareTo(y.text);
      if (result != 0) return result;
    }
    final length = parts.length.compareTo(other.parts.length);
    return length != 0 ? length : original.compareTo(other.original);
  }
}
