import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'store.dart';
import 'source_preview.dart';
import '../sources/source.dart';

typedef PersistedMediaPreview = ({String id, String? previousPath});

@immutable
class SourcePreviewBinding {
  final String id, browseId;
  final String thumbnailId;
  final String? thumbnail;
  final bool needsCapture;
  const SourcePreviewBinding(
    this.id,
    this.browseId,
    this.thumbnail,
    this.needsCapture, {
    String? thumbnailId,
  }) : thumbnailId = thumbnailId ?? id;
}

/// Remove only the failed prepared path observed by the caller. A newer
/// playback capture or source binding must survive an older decode failure.
bool discardPreparedMediaPreview(
  AppStore store,
  String id,
  Map<String, dynamic> expected,
) {
  final current = store.local('preview:$id');
  if (current is! Map || !mapEquals(current, expected)) return false;
  final location = store.local('location:$id') ?? store.local('browse:$id');
  if (location is! Map ||
      location['source'] is! String ||
      location['path'] is! String ||
      store.get('media', id)?.deleted == true ||
      !hasCurrentPreviewOrigin(
        store,
        location['source'] as String,
        location['previewRevision'] as String? ?? '',
      )) {
    return false;
  }
  final content = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            location['source'],
            location['path'],
            (location['size'] as num?)?.toInt() ?? 0,
            location['previewRevision'] as String? ?? '',
          ]),
        ),
      )
      .toString();
  if (expected['contentFingerprint'] != content &&
      expected['fingerprint'] != content) {
    return false;
  }
  store.removeLocal('preview:$id');
  return true;
}

Future<SourcePreviewBinding> readSourcePreviewBinding(
  AppStore store,
  String source,
  SourceEntry entry,
  int formatVersion, {
  bool albumCover = false,
  bool originalResolution = false,
}) async {
  final browseId = albumCover
      ? albumVideoPreviewId(
          source,
          entry.path,
          originalResolution: originalResolution,
        )
      : browsingMediaId(source, entry.path);
  Future<SourcePreviewBinding> missing() async {
    if (albumCover && originalResolution) {
      final small = await readSourcePreviewBinding(
        store,
        source,
        entry,
        formatVersion,
        albumCover: true,
      );
      return SourcePreviewBinding(
        browseId,
        browseId,
        small.thumbnail,
        true,
        thumbnailId: small.thumbnailId,
      );
    }
    return SourcePreviewBinding(browseId, browseId, null, true);
  }

  final existing = albumCover ? null : store.locationFor(source, entry.path);
  final record = existing == null ? null : store.get('media', existing['id']);
  final id = record?.deleted == false ? record!.id : browseId;
  final location = store.local('location:$id') ?? store.local('browse:$id');
  if (location is! Map ||
      location['source'] != source ||
      location['path'] != entry.path ||
      !hasCurrentPreviewOrigin(
        store,
        source,
        location['previewRevision'] as String? ?? '',
      ) ||
      (id == browseId &&
          (location['size'] != entry.size ||
              (location['previewRevision'] ?? '') !=
                  browsePreviewRevision(
                    store,
                    source,
                    entry.modified == 0 ? '' : '${entry.modified}',
                  )))) {
    return id == browseId
        ? await missing()
        : SourcePreviewBinding(id, browseId, null, true);
  }
  final content = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            source,
            entry.path,
            (location['size'] as num?)?.toInt() ?? 0,
            location['previewRevision'] as String? ?? '',
          ]),
        ),
      )
      .toString();
  final saved = store.local('preview:$id');
  final thumbnail =
      saved is Map &&
          saved['formatVersion'] == formatVersion &&
          (saved['contentFingerprint'] == content ||
              saved['fingerprint'] == content) &&
          saved['path'] is String
      ? saved['path'] as String
      : null;
  if (thumbnail == null || !await File(thumbnail).exists()) {
    return id == browseId
        ? await missing()
        : SourcePreviewBinding(id, browseId, null, true);
  }
  // Album entries have an independent policy and cache identity. Keep a
  // prepared cover visible if that policy ever needs a version migration.
  return SourcePreviewBinding(
    id,
    browseId,
    thumbnail,
    albumCover &&
        (saved['firstFrame'] != true ||
            saved['albumVersion'] != albumPreviewVersion),
  );
}

/// Source-origin changes invalidate personal browse previews as well as
/// queued registrations. This scan runs on the existing worker connection.
void invalidateSourceBrowsePreviews(AppStore store, String source) {
  final removed = <String>{};
  for (final entry in store.localEntries('browse:').entries) {
    if (entry.value is! Map || entry.value['source'] != source) continue;
    final id = entry.key.substring('browse:'.length);
    removed.add(id);
    store.removeLocal(entry.key);
    store.removeLocal('preview:$id');
    store.removeLocal('mediaMetadata:$id');
  }
  if (removed.isNotEmpty) {
    final index = List<String>.from(
      store.local('browse:index') ?? const <String>[],
    )..removeWhere(removed.contains);
    store.setLocal('browse:index', index);
  }
}

/// Runs inside a worker-owned transaction. In-memory stores use the same
/// validation only in tests; no image bytes cross the persistence boundary.
PersistedMediaPreview? persistCapturedMediaPreview(
  AppStore store,
  Map<String, dynamic> input,
) {
  final source = input['source'] as String;
  final path = input['sourcePath'] as String;
  final requestedId = input['id'] as String;
  if (!hasCurrentPreviewOrigin(store, source, input['revision'] as String)) {
    return null;
  }
  if (requestedId.startsWith('browse-')) {
    final original = store.local('browse:$requestedId');
    if (original is! Map ||
        browsePreviewRevision(
              store,
              source,
              original['fileRevision'] as String? ??
                  original['previewRevision'] as String? ??
                  '',
            ) !=
            input['revision']) {
      return null;
    }
  }
  var id = requestedId;
  if (id.startsWith('browse-') && !id.startsWith('browse-album-')) {
    final location = store.locationFor(source, path);
    final record = location == null ? null : store.get('media', location['id']);
    if (record?.deleted == false) id = record!.id;
  }
  final record = store.get('media', id);
  final browse = store.local('browse:$id');
  if (record?.deleted == true || record?.data['transient'] == true) return null;
  if (record?.deleted != false) {
    final exclusion = sha256.convert(utf8.encode(jsonEncode([source, path])));
    if (browse == null ||
        (!id.startsWith('browse-album-') &&
            store.local('automatic-import-excluded:$exclusion') == true)) {
      return null;
    }
  }
  final location = store.local('location:$id') ?? browse;
  if (location is! Map ||
      location['source'] != source ||
      location['path'] != path ||
      ((location['size'] as num?)?.toInt() ?? 0) != input['size'] ||
      (location['previewRevision'] as String? ?? '') != input['revision']) {
    return null;
  }
  double? position;
  if (record != null) {
    final key = '$id:${location['size'] ?? record.data['size'] ?? 0}';
    final value = store.get('progress', key)?.data['position'];
    if (value is num && value.isFinite && value > 0) {
      position = value.toDouble();
    }
  }
  if (position?.round() != (input['position'] as double?)?.round()) return null;
  final content = sha256
      .convert(
        utf8.encode(
          jsonEncode([source, path, input['size'], input['revision']]),
        ),
      )
      .toString();
  final fingerprint = input['firstFrame'] == true
      ? albumPreviewFingerprint(
          content,
          originalResolution: input['originalResolution'] == true,
        )
      : position == null
      ? content
      : sha256.convert(utf8.encode('$content:${position.round()}')).toString();
  final previousPath = (store.local('preview:$id') as Map?)?['path'];
  store.setLocal('preview:$id', {
    'path': input['previewPath'],
    'fingerprint': fingerprint,
    'contentFingerprint': content,
    'requestedPosition': input['position'],
    'capturedPosition': input['capturedPosition'],
    if (input['firstFrame'] == true) 'firstFrame': true,
    if (input['firstFrame'] == true) 'albumVersion': albumPreviewVersion,
    if (input['originalResolution'] == true) 'originalResolution': true,
    'formatVersion': input['formatVersion'],
  });
  final saved = store.local('mediaMetadata:$id');
  final previous = saved is Map && saved['fingerprint'] == content
      ? Map<String, dynamic>.from(saved)
      : <String, dynamic>{};
  final duration = input['duration'] as double;
  final width = input['width'] as int?;
  final height = input['height'] as int?;
  final next = <String, dynamic>{
    ...previous,
    'fingerprint': content,
    if (duration.isFinite && duration > 0) 'duration': duration,
    if (width != null && width > 0) 'width': width,
    if (height != null && height > 0) 'height': height,
  };
  if (!mapEquals(previous, next)) store.setLocal('mediaMetadata:$id', next);
  return (id: id, previousPath: previousPath is String ? previousPath : null);
}
