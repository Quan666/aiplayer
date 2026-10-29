import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import 'store.dart';

bool sameLocalVideoBinding(Map? expected, dynamic current) => expected == null
    ? current == null
    : current is Map &&
          current['source'] == expected['source'] &&
          current['path'] == expected['path'] &&
          (current['previewRevision'] ?? '') ==
              (expected['previewRevision'] ?? '');

/// Called only by background workers in production. Binding validation,
/// deletion and tombstones share a write transaction so a queued deletion cannot
/// remove a replacement file or overwrite a later rebind.
bool removeLocalVideo(
  AppStore store,
  String documentsPath,
  String id,
  Map<String, dynamic> expected, {
  bool Function()? guard,
}) {
  var changed = false;
  store.transaction(() {
    final record = store.get('media', id);
    if (record == null || record.deleted) return;
    final location = store.local('location:$id');
    if (expected['source'] != 'local' ||
        !sameLocalVideoBinding(expected, location) ||
        guard?.call() == false) {
      throw const Cancelled();
    }
    final path = location['path'] as String;
    final owned = managedLocalVideoFile(documentsPath, path);
    final size = location['size'] ?? record.data['size'] ?? 0;
    final excluded = sha256.convert(utf8.encode(jsonEncode(['local', path])));
    store.setLocal('automatic-import-excluded:$excluded', true);
    store.save('media', id, record.data, deleted: true);
    final progress = store.get('progress', '$id:$size');
    if (progress != null && !progress.deleted) {
      store.save('progress', progress.id, progress.data, deleted: true);
    }
    final match = store.get('match', id);
    if (match != null && !match.deleted) {
      store.save('match', id, match.data, deleted: true);
    }
    for (final key in ['location', 'preview', 'mediaMetadata', 'technical']) {
      store.removeLocal('$key:$id');
    }
    if (owned != null) {
      try {
        owned.deleteSync();
      } on FileSystemException catch (error) {
        throw AppFailure('无法删除导入的视频文件：${error.osError?.message ?? '请检查存储权限'}');
      }
      // Never recursively remove an import folder containing sibling files.
      try {
        owned.parent.deleteSync();
      } on FileSystemException {
        // Nonempty directories remain intact.
      }
    }
    changed = true;
  });
  final previewRoot = Directory(p.join(documentsPath, 'previews'));
  if (changed &&
      FileSystemEntity.typeSync(previewRoot.path, followLinks: false) ==
          FileSystemEntityType.directory) {
    final fingerprint = sha256.convert(utf8.encode(id));
    for (final extension in ['png', 'jpg']) {
      final path = p.join(documentsPath, 'previews', '$fingerprint.$extension');
      // Optional cache cleanup never follows symlinks or changes source files.
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // The library and owned video removal already committed successfully.
      }
    }
  }
  return changed;
}

File? managedLocalVideoFile(String documentsPath, String path) {
  try {
    final root = Directory(p.join(documentsPath, 'media'));
    final file = File(path);
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(file.parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    final appRoot = Directory(documentsPath).resolveSymbolicLinksSync();
    final ownedRoot = root.resolveSymbolicLinksSync();
    final actual = file.resolveSymbolicLinksSync();
    if (!p.isWithin(appRoot, ownedRoot) || !p.isWithin(ownedRoot, actual)) {
      return null;
    }
    final parts = p.split(p.relative(actual, from: ownedRoot));
    if (parts.length != 2 ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(parts.first)) {
      return null;
    }
    return File(actual);
  } on FileSystemException {
    return null;
  }
}
