import 'dart:async';
import 'dart:io';

import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'portrait and landscape decodes bound both edges and reuse textures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'artwork-decode-',
      );
      try {
        for (final size in [(100, 300), (300, 100)]) {
          final file = File('${directory.path}/${size.$1}.png');
          await file.writeAsBytes(
            images.encodePng(images.Image(width: size.$1, height: size.$2)),
          );
          final provider = artworkImage(file, 128);
          Future<ImageInfo> load() {
            final ready = Completer<ImageInfo>();
            final stream = provider.resolve(ImageConfiguration.empty);
            late ImageStreamListener listener;
            listener = ImageStreamListener(
              (image, _) {
                ready.complete(image);
                stream.removeListener(listener);
              },
              onError: (Object error, StackTrace? stack) {
                ready.completeError(error, stack);
                stream.removeListener(listener);
              },
            );
            stream.addListener(listener);
            return ready.future;
          }

          final first = await load();
          final second = await load();
          expect(first.image.width, lessThanOrEqualTo(128));
          expect(first.image.height, lessThanOrEqualTo(128));
          expect(
            first.image.width / first.image.height,
            closeTo(size.$1 / size.$2, .1),
          );
          expect(first.image.isCloneOf(second.image), isTrue);
          first.dispose();
          second.dispose();
          await provider.evict();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
