import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'store.dart';

const _cachePrefixes = [
  'catalog-v1:',
  'subject-v5:',
  'episode-names:',
  'metadataEpisodeNames:',
  'directory-preview:',
  'directory-preview-envelope:',
  'media-ai-',
  'preview:',
  'mediaMetadata:',
  'technical:',
];

/// Callers stop cache producers before clearing and invalidate their in-memory
/// snapshots afterwards. This removes only reproducible, device-local data.
Future<void> clearStoredCaches(AppStore store, Directory documents) {
  if (store.path == ':memory:') {
    _clearDatabaseCaches(store);
    return _clearPreviewFiles(documents.path);
  }
  final databasePath = store.path;
  final documentsPath = documents.path;
  return Isolate.run(() => _clearStoredCaches(databasePath, documentsPath));
}

Future<void> _clearStoredCaches(
  String databasePath,
  String documentsPath,
) async {
  final store = await retryStoreBusy(() => AppStore.openExisting(databasePath));
  try {
    await retryStoreBusy(() => _clearDatabaseCaches(store));
    await _clearPreviewFiles(documentsPath);
  } finally {
    store.dispose();
  }
}

void _clearDatabaseCaches(AppStore store) {
  store.transaction(() {
    // Keep monotonic epochs: an older worker must never publish a preview from
    // before this clear, even after a second clear or an application restart.
    for (final key in ['directoryPreviewEpoch', 'cacheClearEpoch']) {
      final next = ((store.local(key) as num?)?.toInt() ?? 0) + 1;
      store.db.execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)', [
        key,
        '$next',
      ]);
    }
    for (final prefix in _cachePrefixes) {
      final upper =
          prefix.substring(0, prefix.length - 1) +
          String.fromCharCode(prefix.codeUnitAt(prefix.length - 1) + 1);
      // Range deletes use the primary key without reading/decoding payloads.
      // Direct SQL deliberately creates no synced deletion or edit markers;
      // the store's triggers still invalidate snapshots across connections.
      store.db.execute('DELETE FROM local WHERE key>=? AND key<?', [
        prefix,
        upper,
      ]);
    }
    store.db.execute('DELETE FROM cache');
  });
}

Future<void> _clearPreviewFiles(String documentsPath) async {
  final path = p.join(documentsPath, 'previews');
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    // An unexpected link must never turn a cache clear into deleting user files.
    await Link(path).delete();
  } else if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type == FileSystemEntityType.file) {
    await File(path).delete();
  }
}
