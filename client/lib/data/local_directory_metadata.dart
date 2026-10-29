import 'package:path/path.dart' as p;

import '../sources/source.dart';
import 'library_catalog.dart';

/// A read-only presentation donor, decoded and indexed once per directory on
/// the snapshot worker. It never discovers, imports, or writes media records.
class CachedLocalDirectoryMetadata {
  final String _parent;
  final DirectoryCollection _collection;
  final Map<String, SourceEntry> _members;
  final Map<String, String> _identityPaths;
  final Map<String, dynamic> _subject;

  CachedLocalDirectoryMetadata._(
    this._parent,
    this._collection,
    this._members,
    this._identityPaths,
    this._subject,
  );

  /// The caller reads this value by [directoryPreviewStorageKey], together
  /// with current epochs/configuration in the same read transaction. An
  /// envelope or obsolete/incomplete format cannot establish membership.
  static CachedLocalDirectoryMetadata? decode(
    Object? raw, {
    required String sourceId,
    required String parentPath,
    required int cacheEpoch,
    required int sourceEpoch,
    required String context,
  }) {
    if (raw is! Map || raw['sourceId'] != sourceId) return null;
    final parent = _path(parentPath, directory: true);
    final preview = decodeDirectoryPreview(raw);
    final collection = preview?.collection;
    if (parent == null ||
        preview == null ||
        !preview.complete ||
        preview.cacheEpoch != cacheEpoch ||
        preview.sourceEpoch != sourceEpoch ||
        preview.context != context ||
        collection?.subject == null) {
      return null;
    }
    final subject = collection!.subject!;
    final id = subject['id'];
    if (id == null || '$id'.trim().isEmpty || '$id' == 'null') return null;
    Map<String, dynamic> facts;
    try {
      facts = _freeze(subjectMediaFields(subject)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final members = <String, SourceEntry>{};
    final identityPaths = <String, String>{};
    final ambiguous = <String>{};
    for (final entry in collection.videos) {
      final path = _path(entry.path);
      if (path == null ||
          p.posix.dirname(path) != parent ||
          entry.directory ||
          !isVideo(entry.name) ||
          !collection.identities.containsKey(entry.path)) {
        continue;
      }
      if (members.containsKey(path)) ambiguous.add(path);
      members[path] = entry;
      identityPaths[path] = entry.path;
    }
    for (final path in ambiguous) {
      members.remove(path);
      identityPaths.remove(path);
    }
    if (members.isEmpty) return null;
    return CachedLocalDirectoryMetadata._(
      parent,
      collection,
      Map.unmodifiable(members),
      Map.unmodifiable(identityPaths),
      facts,
    );
  }

  /// Returns only the matched file's fields. Existing manual/identified media
  /// and the current download binding remain authoritative at the caller.
  Map<String, dynamic>? fieldsFor({
    required String path,
    required int size,
    required int modified,
  }) {
    final normalized = _path(path);
    if (normalized == null || p.posix.dirname(normalized) != _parent) {
      return null;
    }
    final entry = _members[normalized];
    if (entry == null || entry.size != size || entry.modified != modified) {
      return null;
    }
    final original = _identityPaths[normalized]!;
    final identity = _collection.identities[original]!;
    final episodeTitle = _collection.episodeTitle(original);
    return Map.unmodifiable({
      ..._subject,
      'series': identity.anime,
      'season': identity.season,
      'episode': identity.episode,
      if (episodeTitle.isNotEmpty) 'episodeTitle': episodeTitle,
    });
  }
}

String? _path(String value, {bool directory = false}) {
  final path = value.replaceAll('\\', '/');
  if (path.split('/').contains('..') || path.contains('\u0000')) return null;
  final normalized = p.posix.normalize(path);
  if (!directory && (path.isEmpty || normalized == '.' || normalized == '/')) {
    return null;
  }
  return normalized;
}

dynamic _freeze(dynamic value) => switch (value) {
  Map() => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freeze(entry.value),
  }),
  List() => List<dynamic>.unmodifiable(value.map(_freeze)),
  _ => value,
};
