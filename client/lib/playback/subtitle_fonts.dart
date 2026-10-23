import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Install the shared fallback once while the library is visible. Each desktop
/// player can then use the existing file without extracting a large font on
/// its first-video path. Atomic replacement also handles two starting engines.
Future<Directory> preparePlaybackFonts(Directory documents) async {
  final directory = Directory(p.join(documents.path, 'subtitle-fonts'));
  final font = File(p.join(directory.path, 'NotoSansSC-Regular.ttf'));
  if (await font.exists() && await font.length() > 0) return directory;
  await directory.create(recursive: true);
  final temporary = File(
    '${font.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    final data = await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf');
    await temporary.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    // A different engine may have completed the same preparation meanwhile.
    if (!await font.exists() || await font.length() == 0) {
      try {
        await temporary.rename(font.path);
      } on FileSystemException {
        if (!await font.exists() || await font.length() == 0) rethrow;
      }
    }
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
  return directory;
}
