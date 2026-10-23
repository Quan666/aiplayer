import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as images;
import 'package:path/path.dart' as p;

import '../core/network.dart';
import 'media_previews.dart';
import 'poster_cache.dart';
import 'store.dart';

/// Portable images live inside authenticated vault records. Device paths never
/// leave this adapter; missing/evicted caches are not shared deletions.
class SyncArtwork {
  final AppStore store;
  final Directory documents;
  final PosterCache posterCache;
  final _encoded = <String, (String, String)>{};
  SyncArtwork(this.store, this.documents, this.posterCache);

  static bool valid(String key, dynamic value) {
    if (value is! Map || value['image'] is! String) return false;
    if (_imageBytes(value['image']) == null) return false;
    if (key.startsWith('poster:')) {
      final uri = Uri.tryParse(key.substring(7));
      return value.length == 1 &&
          uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          key.length <= 4096;
    }
    bool number(dynamic v) => v is num && v.isFinite && v >= 0;
    return key.startsWith('preview:') &&
        value.keys.every(
          [
            'image',
            'mediaId',
            'size',
            'modified',
            'requestedPosition',
            'capturedPosition',
          ].contains,
        ) &&
        value['mediaId'] is String &&
        key == 'preview:${value['mediaId']}' &&
        RegExp(r'^[A-Za-z0-9_.:-]{1,200}$').hasMatch(value['mediaId']) &&
        number(value['size']) &&
        (value['modified'] == null || number(value['modified'])) &&
        (value['requestedPosition'] == null ||
            number(value['requestedPosition'])) &&
        (value['capturedPosition'] == null ||
            number(value['capturedPosition']));
  }

  static Uint8List? _imageBytes(String image) {
    if (image.length > 180000) return null;
    final match = RegExp(
      r'^data:image/(jpeg|png|webp);base64,([A-Za-z0-9+/]+={0,2})$',
    ).firstMatch(image);
    if (match == null) return null;
    try {
      final bytes = base64Decode(match[2]!);
      if (base64Encode(bytes) != match[2] || _mime(bytes) != match[1]) {
        return null;
      }
      return bytes;
    } on FormatException {
      return null;
    }
  }

  Future<String?> _encode(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > 12 * 1024 * 1024) {
        return null;
      }
      final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      final saved = _encoded.remove(file.path);
      if (saved?.$1 == stamp) {
        _encoded[file.path] = saved!;
        return saved.$2;
      }
      final image = await compute(_portableImage, await file.readAsBytes());
      if (image != null) {
        _encoded[file.path] = (stamp, image);
        // Each pause may produce a new file path. Bound the encoded copies
        // retained in RAM while leaving permanent disk artwork untouched.
        while (_encoded.length > 32) {
          _encoded.remove(_encoded.keys.first);
        }
      }
      return image;
    } on FileSystemException {
      return null;
    }
  }

  Future<Map<String, dynamic>> snapshot({
    Set<String>? mediaIds,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final result = <String, dynamic>{};
    final locations = mediaIds == null
        ? store.locations
        : [
            for (final id in mediaIds)
              if (store.local('location:$id') case final Map location)
                <String, dynamic>{...location, 'id': id},
          ];
    for (final location in locations) {
      cancel?.check();
      final id = location['id'];
      if (location['source'] == 'local' || id is! String) continue;
      final media = store.get('media', id);
      if (media == null || media.deleted || store.isPrivateMedia(id)) continue;
      final url = media.data['poster'];
      if (url is String && !result.containsKey('poster:$url')) {
        final image = await _encode(posterCache.cachedFile(url));
        if (image != null && valid('poster:$url', {'image': image})) {
          result['poster:$url'] = {'image': image};
        }
      }
      final preview = store.local('preview:$id');
      final request = _request(
        id,
        location,
        preview is Map ? preview['requestedPosition'] : null,
      );
      if (preview is! Map ||
          preview['path'] is! String ||
          preview['formatVersion'] != MediaPreview.formatVersion ||
          preview['contentFingerprint'] != request.contentFingerprint ||
          !p.isWithin(p.join(documents.path, 'previews'), preview['path'])) {
        continue;
      }
      final image = await _encode(File(preview['path']));
      cancel?.check();
      if (image == null) continue;
      final value = {
        'image': image,
        'mediaId': id,
        'size': location['size'] ?? 0,
        if (location['modified'] != null) 'modified': location['modified'],
        'requestedPosition': preview['requestedPosition'],
        'capturedPosition': preview['capturedPosition'],
      };
      if (valid('preview:$id', value)) result['preview:$id'] = value;
    }
    return result;
  }

  MediaPreviewRequest _request(String id, Map location, dynamic position) =>
      MediaPreviewRequest(
        id,
        location['source'],
        location['path'],
        (location['size'] as num?)?.toInt() ?? 0,
        revision: location['previewRevision'] as String? ?? '',
        position: (position as num?)?.toDouble(),
      );

  Future<void> apply(String key, dynamic value, {required bool deleted}) async {
    // Removing a synchronized cache must not delete independently created art.
    if (deleted || !valid(key, value)) return;
    final bytes = _imageBytes(value['image'])!;
    if (key.startsWith('poster:')) {
      final url = key.substring(7);
      // Retain an original-quality local image when it produced this exact
      // portable copy, but replace old cached artwork when its content changes.
      if (await _encode(posterCache.cachedFile(url)) == value['image']) return;
      await posterCache.restore(url, bytes, replace: true);
      return;
    }
    final id = value['mediaId'] as String;
    final location = store.local('location:$id');
    if (location is! Map ||
        location['source'] == 'local' ||
        store.isPrivateMedia(id) ||
        store.get('media', id)?.deleted != false ||
        (location['size'] ?? 0) != value['size'] ||
        value['modified'] != null &&
            location['modified'] != value['modified']) {
      return;
    }
    final request = _request(id, location, value['requestedPosition']);
    final directory = Directory(p.join(documents.path, 'previews'));
    final digest = sha256.convert(bytes).toString();
    final file = File(p.join(directory.path, 'sync-$digest.image'));
    final previous = store.local('preview:$id');
    if (previous is Map &&
        previous['path'] == file.path &&
        previous['fingerprint'] == request.fingerprint &&
        await file.exists()) {
      return;
    }
    if (!await file.exists()) {
      // Header-only or corrupt images must never be installed as a good cache.
      if (await compute(_portableImage, bytes) == null) return;
      await directory.create(recursive: true);
      final temporary = File('${file.path}.part');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    }
    store.setLocal('preview:$id', {
      'path': file.path,
      'fingerprint': request.fingerprint,
      'contentFingerprint': request.contentFingerprint,
      'requestedPosition': value['requestedPosition'],
      'capturedPosition': value['capturedPosition'],
      'formatVersion': MediaPreview.formatVersion,
    });
  }
}

String? _mime(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return 'jpeg';
  }
  if (bytes.length >= 8 &&
      listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10])) {
    return 'png';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'webp';
  }
  return null;
}

String? _portableImage(Uint8List bytes) {
  try {
    final decoder = images.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 64000000) {
      return null;
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) return null;
    final mime = _mime(bytes);
    if (mime != null && bytes.length <= 134970) {
      return 'data:image/$mime;base64,${base64Encode(bytes)}';
    }
    var image = decoded;
    if (image.width > 960 || image.height > 960) {
      image = images.copyResize(
        image,
        width: image.width >= image.height ? 960 : null,
        height: image.height > image.width ? 960 : null,
      );
    }
    for (final quality in [85, 70, 55, 40]) {
      final jpeg = images.encodeJpg(image, quality: quality);
      if (jpeg.length <= 134970) {
        return 'data:image/jpeg;base64,${base64Encode(jpeg)}';
      }
      image = images.copyResize(
        image,
        width: (image.width * .8).round().clamp(1, 960),
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}
