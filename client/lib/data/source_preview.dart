import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';

String browsingMediaId(String sourceId, String path) =>
    'browse-${sha256.convert(utf8.encode('$sourceId:$path'))}';

/// Album thumbnails must never replace a file-browser or library resume cover.
String albumVideoPreviewId(
  String sourceId,
  String path, {
  bool originalResolution = false,
}) =>
    'browse-album-${originalResolution ? 'original-' : ''}'
    '${sha256.convert(utf8.encode('$sourceId:$path'))}';

const albumPreviewVersion = 3;

String albumPreviewFingerprint(
  String content, {
  bool originalResolution = false,
}) => sha256
    .convert(
      utf8.encode(
        '$content:first-frame-v$albumPreviewVersion:${originalResolution ? 'original' : '480'}',
      ),
    )
    .toString();

String browsePreviewRevision(
  AppStore store,
  String sourceId,
  String fileRevision,
) {
  if (sourceId == 'local') return fileRevision;
  final sources = store.local('sources');
  final configured = sources is List
      ? sources
            .whereType<Map>()
            .where((source) => source['id'] == sourceId)
            .firstOrNull
      : null;
  final source = configured ?? store.local('externalSource:$sourceId');
  if (source is! Map) return fileRevision;
  final identity = sha256.convert(
    utf8.encode(
      jsonEncode([
        for (final key in [
          'kind',
          'host',
          'port',
          'share',
          'url',
          'user',
          'domain',
        ])
          source[key],
      ]),
    ),
  );
  return '$fileRevision@origin:$identity';
}

bool hasCurrentPreviewOrigin(AppStore store, String sourceId, String revision) {
  final marker = revision.lastIndexOf('@origin:');
  return marker < 0 ||
      browsePreviewRevision(store, sourceId, revision.substring(0, marker)) ==
          revision;
}

/// A newly imported binding refers to the same observed file. Preserve its
/// browse revision so an already captured/in-flight frame keeps one identity.
/// Never carry a revision across a changed size or modification time.
String? matchingBrowsingPreviewRevision(
  AppStore store,
  String sourceId,
  String path,
  int size,
  int modified,
) {
  final browse = store.local('browse:${browsingMediaId(sourceId, path)}');
  final revision = browsePreviewRevision(
    store,
    sourceId,
    modified == 0 ? '' : '$modified',
  );
  final exclusion = sha256.convert(utf8.encode(jsonEncode([sourceId, path])));
  if (browse is! Map ||
      browse['source'] != sourceId ||
      browse['path'] != path ||
      browse['size'] != size ||
      (browse['previewRevision'] ?? '') != revision ||
      store.local('automatic-import-excluded:$exclusion') == true) {
    return null;
  }
  return revision.isEmpty ? null : revision;
}

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
