import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'media_technical_info.dart';
import 'media_episodes.dart';
import 'playback_source.dart';
import 'store.dart';

/// Called only while preparing the library snapshot on its worker.
List<MediaPlaybackOption> preparePlaybackOptions(
  List<SyncRecord> versions,
  Map<String, Map<String, dynamic>> locations,
  Map<String, Map<String, dynamic>> offlineLocations,
  Map<String, dynamic> technicalFacts,
  Set<String> availableSources,
) {
  final options = <MediaPlaybackOption>[];
  final preferred = uniqueMediaEpisodes(
    versions,
    playable: (record) => locations.containsKey(record.id),
  ).firstOrNull;
  for (final record in [
    ?preferred,
    ...versions.where((record) => record.id != preferred?.id),
  ]) {
    final binding = locations[record.id];
    final technical = _technical(record, binding, technicalFacts);
    void add(
      Map<String, dynamic> location,
      PlaybackSourcePreference preference,
    ) {
      final source = location['source'], path = location['path'];
      if (source is! String ||
          source.isEmpty ||
          path is! String ||
          path.isEmpty) {
        return;
      }
      options.add(
        MediaPlaybackOption(
          choice: MediaPlaybackChoice(
            record,
            preference,
            expectedBinding: binding ?? const {},
          ),
          sourceId: source,
          path: path,
          displayPath: '${location['displayPath'] ?? binding?['path'] ?? path}',
          technical: technical,
          isLocal: source == 'local',
        ),
      );
    }

    if (binding != null && availableSources.contains(binding['source'])) {
      add(binding, PlaybackSourcePreference.original);
    }
    final offline = offlineLocations[record.id];
    if (offline != null &&
        offline['source'] == 'local' &&
        (binding == null ||
            (offline['remoteSource'] == binding['source'] &&
                offline['remotePath'] == binding['path'] &&
                (offline['remoteRevision'] ?? '') ==
                    (binding['previewRevision'] ?? '')))) {
      add(offline, PlaybackSourcePreference.offline);
    }
  }
  final order = {for (var i = 0; i < options.length; i++) options[i]: i};
  options.sort((a, b) {
    final quality = _compare(a, b);
    return quality != 0 ? quality : order[a]!.compareTo(order[b]!);
  });
  final seen = <(String, String)>{};
  return List.unmodifiable(
    options.where((item) => seen.add((item.sourceId, item.path))),
  );
}

int _compare(MediaPlaybackOption a, MediaPlaybackOption b) {
  if (a.isLocal != b.isLocal) return a.isLocal ? -1 : 1;
  final pixels = _pixels(b.technical).compareTo(_pixels(a.technical));
  if (pixels != 0) return pixels;
  final bitrate = (b.technical.bitrate ?? 0).compareTo(
    a.technical.bitrate ?? 0,
  );
  if (bitrate != 0) return bitrate;
  // Format, codec and file size are labels, not evidence of better quality.
  return 0;
}

int _pixels(MediaTechnicalInfo value) {
  if (value.width != null && value.height != null) {
    return value.width! * value.height!;
  }
  // Filename claims remain labelled as such; no dimensions are invented.
  return switch (value.resolutionHint.toLowerCase()) {
    '8k' || '4320p' => 7680 * 4320,
    '4k' || '2160p' => 3840 * 2160,
    '1440p' => 2560 * 1440,
    '1080p' || '1080i' => 1920 * 1080,
    '720p' => 1280 * 720,
    '576p' || '576i' => 720 * 576,
    '480p' => 720 * 480,
    _ => 0,
  };
}

int? _positive(Object? value) {
  final number = value is num ? value : num.tryParse('$value');
  return number != null && number.isFinite && number > 0
      ? number.round()
      : null;
}

MediaTechnicalInfo _technical(
  SyncRecord record,
  Map<String, dynamic>? binding,
  Map<String, dynamic> facts,
) {
  final signature = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            binding?['source'],
            binding?['path'],
            binding?['size'] ?? record.data['size'],
            binding?['modified'],
          ]),
        ),
      )
      .toString();
  final saved = facts['technical:${record.id}'];
  final data = saved is Map && saved['fingerprint'] == signature
      ? saved
      : const {};
  final name =
      '${record.data['fileName'] ?? binding?['path'] ?? record.data['title'] ?? ''}';
  final width = _positive(data['width']), height = _positive(data['height']);
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
    size: _positive(binding?['size'] ?? record.data['size']),
    duration:
        data['duration'] is num &&
            (data['duration'] as num).isFinite &&
            (data['duration'] as num) > 0
        ? (data['duration'] as num).toDouble()
        : null,
    resolutionHint: width != null && height != null ? '' : hint,
  );
}
