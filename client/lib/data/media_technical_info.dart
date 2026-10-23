import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'store.dart';

/// Local facts about one file, kept separate from catalogue and sync metadata.
class MediaTechnicalInfo {
  final String container, codec, resolutionHint;
  final int? width, height, bitrate, size;
  final double? duration;
  const MediaTechnicalInfo({
    this.container = '',
    this.codec = '',
    this.resolutionHint = '',
    this.width,
    this.height,
    this.bitrate,
    this.size,
    this.duration,
  });

  static int? _positive(Object? value) {
    final number = value is num ? value : num.tryParse('$value');
    return number != null && number.isFinite && number > 0
        ? number.round()
        : null;
  }

  static String fingerprint(AppStore store, SyncRecord record) {
    final location =
        store.local('location:${record.id}') ??
        store.local('browse:${record.id}');
    final values = location is Map ? location : const {};
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              values['source'],
              values['path'],
              values['size'] ?? record.data['size'],
              values['modified'],
            ]),
          ),
        )
        .toString();
  }

  factory MediaTechnicalInfo.forRecord(
    AppStore store,
    SyncRecord record, {
    ({int width, int height})? dimensions,
    double? duration,
    String? fileName,
    int? fileSize,
  }) {
    final current = store.get('media', record.id) ?? record;
    final location =
        store.local('location:${record.id}') ??
        store.local('browse:${record.id}');
    final local = location is Map ? location : const {};
    final saved = store.local('technical:${record.id}');
    final data =
        saved is Map && saved['fingerprint'] == fingerprint(store, current)
        ? saved
        : const {};
    final name =
        fileName ??
        '${current.data['fileName'] ?? local['path'] ?? current.data['title'] ?? ''}';
    final width = _positive(data['width']) ?? dimensions?.width;
    final height = _positive(data['height']) ?? dimensions?.height;
    final hint =
        RegExp(
          r'(?:^|[\s._\-\[\]()])(4320p|2160p|1440p|1080[pi]|720p|576[pi]|480p|4k|8k)(?=$|[\s._\-\[\]()])',
          caseSensitive: false,
        ).firstMatch(p.basename(name))?[1] ??
        '';
    return MediaTechnicalInfo(
      container: videoContainerLabel(
        '${data['container'] ?? ''}',
        fileName: name,
      ),
      codec: '${data['codec'] ?? ''}',
      width: width,
      height: height,
      bitrate: _positive(data['bitrate']),
      size: _positive(fileSize ?? local['size'] ?? current.data['size']),
      duration:
          data['duration'] is num &&
              (data['duration'] as num).isFinite &&
              (data['duration'] as num) > 0
          ? (data['duration'] as num).toDouble()
          : duration,
      resolutionHint: width != null && height != null ? '' : hint,
    );
  }

  /// Merge only verified, positive facts and avoid rewriting identical samples.
  bool save(AppStore store, SyncRecord record) {
    final signature = fingerprint(store, record);
    final saved = store.local('technical:${record.id}');
    final previous = saved is Map && saved['fingerprint'] == signature
        ? Map<String, dynamic>.from(saved)
        : <String, dynamic>{};
    final next = <String, dynamic>{
      ...previous,
      'fingerprint': signature,
      if (container.trim().isNotEmpty) 'container': container.trim(),
      if (codec.trim().isNotEmpty) 'codec': codec.trim(),
      if (_positive(width) != null) 'width': width,
      if (_positive(height) != null) 'height': height,
      if (_positive(bitrate) != null) 'bitrate': bitrate,
      if (duration != null && duration!.isFinite && duration! > 0)
        'duration': duration,
    };
    if (next.length == 1 || mapEquals(previous, next)) return false;
    store.setLocal('technical:${record.id}', next);
    return true;
  }

  String get label => [
    if (container.isNotEmpty) container,
    if (codec.isNotEmpty) codec,
    if (width != null && height != null) '$width × $height',
    if (resolutionHint.isNotEmpty) '$resolutionHint（文件名标注）',
    if (size != null && size! > 0) mediaFileSize(size!),
  ].join(' · ');
}

String mediaFileSize(int size) {
  if (size <= 0) return '';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KiB';
  if (size < 1024 * 1024 * 1024) {
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String videoCodecLabel(String value) => switch (value.trim().toLowerCase()) {
  'h264' || 'avc1' => 'H.264',
  'hevc' || 'h265' || 'hev1' || 'hvc1' => 'H.265 / HEVC',
  'av1' => 'AV1',
  'vp9' => 'VP9',
  'vp8' => 'VP8',
  'mpeg2video' => 'MPEG-2',
  'mpeg4' => 'MPEG-4',
  _ => value.trim(),
};

/// Demuxer names describe families; the filename identifies the displayed format.
String videoContainerLabel(String value, {String? fileName}) {
  final name = fileName?.trim() ?? '';
  final uri = Uri.tryParse(name);
  final path = uri != null && uri.hasScheme ? uri.path : name;
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (const {
    'mp4',
    'mov',
    'm4v',
    'mkv',
    'webm',
    'avi',
    'ts',
    'mts',
    'm2ts',
    'mpeg',
    'mpg',
    'm2v',
    'vob',
    'wmv',
    'asf',
    'flv',
    'f4v',
    '3gp',
    '3g2',
    'ogv',
    'ogg',
    'rm',
    'rmvb',
    'divx',
    'mj2',
    'mxf',
    'nut',
    'm4a',
  }.contains(extension)) {
    return extension.toUpperCase();
  }
  final formats = value
      .toLowerCase()
      .split(RegExp(r'[,/]'))
      .map((format) => format.trim())
      .toSet();
  if (formats.contains('matroska') || formats.contains('mkv')) {
    return 'MKV';
  }
  if (formats.contains('mp4')) return 'MP4';
  if (formats.contains('mov')) return 'MOV';
  if (formats.contains('mpegts')) return 'MPEG-TS';
  return value.trim().toUpperCase();
}
