import 'dart:convert';

import 'store.dart';

/// Batch checkpoints remain local until a complete translation can replace
/// the portable cache. Each checkpoint writes only the newly validated cues.
Map<String, dynamic>? subtitleTranslationCache(
  AppStore store,
  String key, {
  Map<String, dynamic>? batch,
  bool finish = false,
  Object? epoch,
}) {
  final prefix = '$key:';
  final end = '$key;';
  if ((batch != null || finish) && store.local('cacheClearEpoch') != epoch) {
    return null;
  }
  if (batch != null) {
    for (final entry in (batch['values'] as Map<String, String>).entries) {
      store.cache('$prefix${entry.key}', entry.value);
    }
    return null;
  }

  final rows = store.db.select(
    'SELECT key, value FROM cache WHERE key>=? AND key<?',
    [prefix, end],
  );
  if (finish && rows.isEmpty) return null;
  final saved = store.local(key);
  final values = saved is Map && saved['version'] == 1 && saved['values'] is Map
      ? Map<String, dynamic>.from(saved['values'] as Map)
      : <String, dynamic>{};
  for (final row in rows) {
    values[(row['key'] as String).substring(prefix.length)] = jsonDecode(
      row['value'] as String,
    );
  }
  if (values.isEmpty) return null;
  final result = <String, dynamic>{'version': 1, 'values': values};
  if (finish) {
    store.setLocal(key, result);
    store.db.execute('DELETE FROM cache WHERE key>=? AND key<?', [prefix, end]);
    return null;
  }
  return result;
}
