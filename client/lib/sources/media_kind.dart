/// File categories shared by directory, album and audio browsing. Extension
/// recognition is deliberately separate from the current device's decoders.
enum MediaKind { folder, image, raw, video, audio, sidecar, other }

const imageFileExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.jpe',
  '.jfif',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.wbmp',
  '.tif',
  '.tiff',
  '.heic',
  '.heif',
  '.avif',
  '.jxl',
  '.ico',
};

const rawFileExtensions = <String>{
  '.arw',
  '.srf',
  '.sr2',
  '.cr2',
  '.cr3',
  '.crw',
  '.nef',
  '.nrw',
  '.raf',
  '.orf',
  '.rw2',
  '.rwl',
  '.dng',
  '.pef',
  '.ptx',
  '.srw',
  '.raw',
  '.3fr',
  '.fff',
  '.iiq',
  '.kdc',
  '.dcr',
  '.erf',
  '.mos',
  '.mrw',
  '.x3f',
  '.mef',
};

const videoFileExtensions = <String>{
  '.mp4',
  '.m4v',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.ts',
  '.m2ts',
  '.mts',
  '.mpg',
  '.mpeg',
  '.m2v',
  '.vob',
  '.wmv',
  '.flv',
  '.3gp',
  '.3g2',
  '.ogv',
  '.rm',
  '.rmvb',
  '.asf',
  '.divx',
  '.f4v',
};

const audioFileExtensions = <String>{
  '.mp3',
  '.flac',
  '.aac',
  '.m4a',
  '.ogg',
  '.oga',
  '.wav',
  '.wave',
  '.opus',
  '.aiff',
  '.aif',
  '.alac',
  '.ape',
  '.wma',
  '.mka',
  '.ac3',
  '.dts',
  '.dsf',
  '.dff',
  '.wv',
  '.amr',
};

const sidecarFileExtensions = <String>{
  '.xmp',
  '.aae',
  '.pp3',
  '.dop',
  '.thm',
  '.lrv',
  '.nfo',
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
  '.sub',
  '.idx',
  '.lrc',
  '.cue',
};

/// Exact suffix with a leading dot. A JPEG category filter can select both
/// .jpg and .jpeg; an exact .jpg filter never silently selects .jpeg.
String mediaExtension(String name) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  final dot = name.lastIndexOf('.');
  return dot <= slash + 1 || dot == name.length - 1
      ? ''
      : name.substring(dot).toLowerCase();
}

String normalizeMediaExtension(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  return trimmed.startsWith('.') ? trimmed : '.$trimmed';
}

MediaKind mediaKindOf(String name) {
  final extension = mediaExtension(name);
  if (imageFileExtensions.contains(extension)) return MediaKind.image;
  if (rawFileExtensions.contains(extension)) return MediaKind.raw;
  if (videoFileExtensions.contains(extension)) return MediaKind.video;
  if (audioFileExtensions.contains(extension)) return MediaKind.audio;
  if (sidecarFileExtensions.contains(extension)) return MediaKind.sidecar;
  return MediaKind.other;
}

bool isImageFile(String name) => switch (mediaKindOf(name)) {
  MediaKind.image || MediaKind.raw => true,
  _ => false,
};

bool isRawImageFile(String name) => mediaKindOf(name) == MediaKind.raw;
bool isAudioFile(String name) => mediaKindOf(name) == MediaKind.audio;
