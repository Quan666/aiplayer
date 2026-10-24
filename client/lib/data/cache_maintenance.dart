import 'dart:io';
import 'dart:isolate';

import 'store.dart';

const _cachePrefixes = [
  'catalog-v1:',
  'subject-v5:',
  'episode-names:',
  'metadataEpisodeNames:',
  'media-ai-',
  'mediaMetadata:',
  'technical:',
];

/// Callers stop cache producers before clearing and invalidate their in-memory
/// snapshots afterwards. Artwork files, captured-cover references and directory
/// snapshots carrying offline poster identities are retained.
Future<void> clearStoredCaches(AppStore store, Directory documents) {
  if (store.path == ':memory:') {
    _clearDatabaseCaches(store);
    return Future.value();
  }
  final databasePath = store.path;
  return Isolate.run(() => _clearStoredCaches(databasePath));
}

Future<void> _clearStoredCaches(String databasePath) async {
  final store = await retryStoreBusy(() => AppStore.openExisting(databasePath));
  try {
    await retryStoreBusy(() => _clearDatabaseCaches(store));
  } finally {
    store.dispose();
  }
}

void _clearDatabaseCaches(AppStore store) {
  store.transaction(() {
    // Keep the saved directory's poster identity usable offline while rejecting
    // older workers. Only current snapshots advance: stale snapshots must never
    // become valid again. JSON work runs on this maintenance connection.
    final directoryEpoch =
        (store.local('directoryPreviewEpoch') as num?)?.toInt() ?? 0;
    for (final prefix in [
      'directory-preview:',
      'directory-preview-envelope:',
    ]) {
      store.db.execute(
        '''UPDATE local SET value=json_set(value, '\$.epoch', ?)
           WHERE key>=? AND key<? AND CASE WHEN json_valid(value)
             THEN json_type(value)='object'
               AND COALESCE(json_extract(value, '\$.epoch'), 0)=?
             ELSE 0 END''',
        [directoryEpoch + 1, prefix, _prefixEnd(prefix), directoryEpoch],
      );
    }
    for (final key in ['directoryPreviewEpoch', 'cacheClearEpoch']) {
      final next = ((store.local(key) as num?)?.toInt() ?? 0) + 1;
      store.db.execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)', [
        key,
        '$next',
      ]);
    }
    for (final prefix in _cachePrefixes) {
      // Range deletes use the primary key without reading/decoding payloads.
      // Direct SQL deliberately creates no synced deletion or edit markers;
      // the store's triggers still invalidate snapshots across connections.
      store.db.execute('DELETE FROM local WHERE key>=? AND key<?', [
        prefix,
        _prefixEnd(prefix),
      ]);
    }
    store.db.execute('DELETE FROM cache');
  });
}

String _prefixEnd(String prefix) =>
    prefix.substring(0, prefix.length - 1) +
    String.fromCharCode(prefix.codeUnitAt(prefix.length - 1) + 1);
