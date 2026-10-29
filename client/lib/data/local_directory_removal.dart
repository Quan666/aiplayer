import 'dart:convert';

import 'package:path/path.dart' as p;

import '../core/network.dart';

/// A bounded worker-owned plan. Only this summary crosses to the UI.
class LocalDirectoryRemovalPlan {
  final String token, path, name;
  final int downloads, managed, linked;
  const LocalDirectoryRemovalPlan({
    required this.token,
    required this.path,
    required this.name,
    required this.downloads,
    required this.managed,
    required this.linked,
  });
  int get count => downloads + managed + linked;
}

class LocalDirectoryRemovalResult {
  final int removed, skipped, failed;
  final bool cancelled;
  final String error;
  const LocalDirectoryRemovalResult({
    this.removed = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
    this.error = '',
  });
}

/// Mirrors the opaque directory identities in LibrarySnapshot's local index.
/// Source and selected-root boundaries are decoded before comparing paths.
class LocalDirectoryRemovalScope {
  final String path, source, relative;
  final String? selected;
  const LocalDirectoryRemovalScope._(
    this.path,
    this.source,
    this.relative,
    this.selected,
  );

  factory LocalDirectoryRemovalScope.parse(String path) {
    if (path.isEmpty) {
      return const LocalDirectoryRemovalScope._('', '', '', null);
    }
    final selection = path.startsWith('download-selection:');
    final prefix = selection ? 'download-selection:' : 'download-directory:';
    if (!path.startsWith(prefix)) throw const AppFailure('本地文件夹已改变，请刷新后重试。');
    try {
      final parts = jsonDecode(path.substring(prefix.length));
      if (parts is! List ||
          parts.length != (selection ? 3 : 2) ||
          parts.any((value) => value is! String) ||
          (parts.first as String).isEmpty) {
        throw const FormatException();
      }
      final relative = parts.last as String;
      if (relative.startsWith('/') ||
          relative.contains('\\') ||
          relative.split('/').any((part) => part == '.' || part == '..')) {
        throw const FormatException();
      }
      return LocalDirectoryRemovalScope._(
        path,
        parts.first as String,
        relative,
        selection ? parts[1] as String : null,
      );
    } on FormatException {
      throw const AppFailure('本地文件夹已改变，请刷新后重试。');
    }
  }

  bool containsDownload(Map<String, dynamic> row) {
    if (path.isEmpty) return true;
    if (row['sourceId'] != source) return false;
    final hasSelection =
        row['downloadRoot'] is String && row['downloadRelativePath'] is String;
    if (selected == null ? hasSelection : row['downloadRoot'] != selected) {
      return false;
    }
    final file = hasSelection
        ? row['downloadRelativePath'] as String
        : row['remotePath'] as String;
    final normalized = p.posix.normalize(file.replaceAll('\\', '/'));
    final parents = p.posix
        .split(p.posix.dirname(normalized))
        .where((part) => part.isNotEmpty && part != '/' && part != '.')
        .toList();
    final parent = parents.contains('..') ? '' : parents.join('/');
    return relative.isEmpty ||
        parent == relative ||
        parent.startsWith('$relative/');
  }
}
