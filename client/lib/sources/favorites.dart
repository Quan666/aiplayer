import 'package:path/path.dart' as p;
import '../data/store.dart';

/// Folder shortcuts refer to a source identity and a relative directory.
/// SyncProfile includes remote favorites; local-file shortcuts stay on device.
class SourceFavorite {
  final String sourceId, path, name;
  const SourceFavorite({
    required this.sourceId,
    required this.path,
    required this.name,
  });

  String get key => '$sourceId\u0000${_normalized(path)}';
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'path': path,
    'name': name,
  };

  static String _normalized(String path) {
    if (path.isEmpty) return '';
    final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
    return normalized == '.' ? '' : normalized;
  }
}

class SourceFavorites {
  final AppStore store;
  const SourceFavorites(this.store);
  static const storageKey = 'sourceFavorites';

  List<SourceFavorite> get all {
    final rows = store.local(storageKey);
    if (rows is! List) return const [];
    final unique = <String, SourceFavorite>{};
    for (final row in rows.whereType<Map>()) {
      if (row['sourceId'] is! String ||
          row['path'] is! String ||
          row['name'] is! String ||
          (row['sourceId'] as String).isEmpty) {
        continue;
      }
      final value = SourceFavorite(
        sourceId: row['sourceId'],
        path: row['path'],
        name: row['name'],
      );
      unique.putIfAbsent(value.key, () => value);
    }
    return unique.values.toList();
  }

  List<SourceFavorite> available(Iterable<String> sourceIds) {
    final ids = sourceIds.toSet();
    return all.where((value) => ids.contains(value.sourceId)).toList();
  }

  bool contains(String sourceId, String path) {
    final key = SourceFavorite(sourceId: sourceId, path: path, name: '').key;
    return all.any((item) => item.key == key);
  }

  /// Returns true when the folder was added, false when it was removed.
  bool toggle(SourceFavorite value) {
    final values = all.toList();
    final exists = values.any((item) => item.key == value.key);
    if (exists) {
      values.removeWhere((item) => item.key == value.key);
    } else {
      values.add(value);
    }
    store.setLocal(storageKey, values.map((item) => item.toJson()).toList());
    return !exists;
  }

  void removeSource(String sourceId) {
    store.setLocal(storageKey, [
      for (final item in all)
        if (item.sourceId != sourceId) item.toJson(),
    ]);
  }
}
