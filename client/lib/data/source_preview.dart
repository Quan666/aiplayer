import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';

String browsingMediaId(String sourceId, String path) =>
    'browse-${sha256.convert(utf8.encode('$sourceId:$path'))}';

/// Recognition changes a browsing entry into a library record. The captured
/// image belongs to its source content, not the temporary browsing ID. Move
/// only matching cache metadata; the image itself is already on disk.
bool adoptBrowsingMediaPreview(
  AppStore store,
  String sourceId,
  String path,
  String mediaId,
) {
  final browsingId = browsingMediaId(sourceId, path);
  if (browsingId == mediaId) return false;
  final location = store.local('location:$mediaId');
  if (location is! Map ||
      location['source'] != sourceId ||
      location['path'] != path) {
    return false;
  }
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            sourceId,
            path,
            (location['size'] as num?)?.toInt() ?? 0,
            location['previewRevision'] as String? ?? '',
          ]),
        ),
      )
      .toString();
  var changed = false;
  for (final prefix in ['preview:', 'mediaMetadata:']) {
    final original = store.local('$prefix$browsingId');
    if (original is! Map) continue;
    final current = store.local('$prefix$mediaId');
    bool matches(Map value) => prefix == 'preview:'
        ? value['contentFingerprint'] == fingerprint ||
              value['fingerprint'] == fingerprint
        : value['fingerprint'] == fingerprint;
    if (matches(original) && (current is! Map || !matches(current))) {
      store.setLocal('$prefix$mediaId', original);
      changed = true;
    }
    // There must be one cache owner. A later browsing capture must not delete a
    // file still referenced by the library's promoted cache.
    if (matches(original)) store.removeLocal('$prefix$browsingId');
  }
  return changed;
}
