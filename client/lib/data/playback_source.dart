import 'media_technical_info.dart';
import 'store.dart';

enum PlaybackSourcePreference { automatic, original, offline }

/// Keep only a binding's identity, never source credentials or unrelated data.
Map<String, dynamic>? playbackBindingSnapshot(Map<String, dynamic>? value) =>
    value == null
    ? null
    : value.isEmpty
    ? const <String, dynamic>{}
    : Map<String, dynamic>.unmodifiable({
        'source': value['source'] as String?,
        'path': value['path'] as String?,
        'previewRevision': value['previewRevision'] as String? ?? '',
      });

/// A source choice belongs to one playback request, not the media's binding.
class MediaPlaybackChoice {
  final SyncRecord media;
  final PlaybackSourcePreference preference;
  final Map<String, dynamic>? expectedBinding;

  MediaPlaybackChoice(
    this.media,
    this.preference, {
    Map<String, dynamic>? expectedBinding,
  }) : expectedBinding = playbackBindingSnapshot(expectedBinding);
}

/// One concrete file prepared by the library worker, in default playback order.
class MediaPlaybackOption {
  final MediaPlaybackChoice choice;
  final String sourceId, path, displayPath;
  final MediaTechnicalInfo technical;
  final bool isLocal;

  const MediaPlaybackOption({
    required this.choice,
    required this.sourceId,
    required this.path,
    required this.displayPath,
    required this.technical,
    required this.isLocal,
  });

  SyncRecord get media => choice.media;
  PlaybackSourcePreference get preference => choice.preference;
}
