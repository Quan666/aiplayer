import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'simultaneous player engines publish one complete fallback font',
    () async {
      final root = await Directory.systemTemp.createTemp('playback-fonts-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(List.generate(256, (index) => index));
      binding.defaultBinaryMessenger.setMockMessageHandler(
        'flutter/assets',
        (_) async => ByteData.sublistView(bytes),
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMessageHandler(
          'flutter/assets',
          null,
        ),
      );
      final directories = await Future.wait(
        List.generate(8, (_) => preparePlaybackFonts(root)),
      );
      final files = await directories.first.list().toList();
      expect(files, hasLength(1));
      expect(await File(files.single.path).readAsBytes(), bytes);
    },
  );

  test(
    'an existing fallback does not read or rewrite the bundled font',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playback-fonts-cached-',
      );
      addTearDown(() => root.delete(recursive: true));
      final font = File('${root.path}/subtitle-fonts/NotoSansSC-Regular.ttf');
      await font.parent.create(recursive: true);
      await font.writeAsBytes([1, 2, 3]);
      var reads = 0;
      binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
        _,
      ) async {
        reads++;
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMessageHandler(
          'flutter/assets',
          null,
        ),
      );
      await preparePlaybackFonts(root);
      expect(reads, 0);
      expect(await font.readAsBytes(), [1, 2, 3]);
    },
  );
}
