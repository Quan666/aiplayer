import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment(
    'MEDIA_FIXTURE',
    defaultValue: '/tmp/aiplayer-media-fixture/Example S01E01.mkv',
  );
  testWidgets('real video preview is a bounded encoded frame with duration', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    expect(await File(fixture).exists(), true);
    final preview = await captureMediaPreview(
      fixture,
      CancelToken(),
    ).timeout(const Duration(seconds: 30));
    expect(preview.duration, closeTo(30, 1));
    expect(preview.width, greaterThan(0));
    expect(preview.height, greaterThan(0));
    expect(preview.bytes.take(2), [255, 216]);
    final codec = await ui.instantiateImageCodec(preview.bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, lessThanOrEqualTo(480));
    expect(frame.image.height, lessThanOrEqualTo(480));
    expect(preview.bytes.length, greaterThan(500));
    frame.image.dispose();
    codec.dispose();
  });

  testWidgets(
    'import generates a real cached cover and visible watch progress',
    (tester) async {
      MediaKit.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      final font = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
      await font.load();
      final root = await Directory.systemTemp.createTemp(
        'aiplayer-preview-library-',
      );
      final source = await File(fixture).copy('${root.path}/旅行记录.mkv');
      var store = AppStore('${root.path}/library.db');
      var model = AppModel(store, root, enableThumbnails: true);
      final boundaryKey = GlobalKey();
      var disposed = false;
      try {
        await model.updatePreferences({
          'autoDiscover': false,
          'animations': false,
        });
        // Import completes while the decoder queue is paused, proving that a
        // screenshot never blocks adding a file to the library.
        await model.pausePreviews();
        final id = await model
            .importFile(source.path)
            .timeout(const Duration(seconds: 3));
        expect(model.media.single.id, id);
        expect(model.thumbnailPath(id), isNull);
        model.resumePreviews();
        for (var i = 0; i < 300 && model.thumbnailPath(id) == null; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        var path = model.thumbnailPath(id);
        expect(
          path,
          isNotNull,
          reason: 'The real decoder did not publish a thumbnail.',
        );
        var cover = File(path!);
        expect(await cover.length(), greaterThan(500));
        final record = store.get('media', id)!;
        expect(model.mediaDuration(record), closeTo(30, 1));
        expect(
          record.data['duration'],
          0,
          reason: 'Device metadata must not become sync data.',
        );
        store.save('progress', model.progressKey(record), {
          'position': 9.0,
          'duration': 30.0,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });

        await binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                devicePixelRatio: 1,
              ),
              child: AIPlayerApp(model: model),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final openingCover = path;
        final openingBytes = await cover.readAsBytes();
        for (
          var i = 0;
          i < 300 && model.thumbnailPath(id) == openingCover;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        path = model.thumbnailPath(id);
        expect(
          path,
          isNot(openingCover),
          reason: 'Continue cover must be regenerated at saved progress.',
        );
        cover = File(path!);
        expect(await cover.readAsBytes(), isNot(openingBytes));
        await tester.pumpAndSettle();
        expect(find.text('继续观看'), findsOneWidget);
        expect(find.text('00:09 / 00:30 · 30%'), findsOneWidget);
        expect(
          find.byWidgetPredicate((widget) {
            if (widget is! Image) return false;
            var provider = widget.image;
            if (provider is ResizeImage) provider = provider.imageProvider;
            return provider is FileImage && provider.file.path == path;
          }),
          findsAtLeastNWidgets(2),
        );
        expect(tester.takeException(), isNull);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final screenshot = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await screenshot.toByteData(
          format: ui.ImageByteFormat.png,
        );
        screenshot.dispose();
        final artifacts = Directory('${Directory.current.path}/../artifacts');
        await artifacts.create(recursive: true);
        await File('${artifacts.path}/library_thumbnail.png').writeAsBytes(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );

        final modified = await cover.lastModified();
        await tester.pumpWidget(const SizedBox());
        await model.pausePreviews();
        model.dispose();
        store.dispose();
        disposed = true;
        // A cached cover remains usable after restart even when its original
        // source is temporarily unavailable. No decoder or network is required.
        await source.delete();
        store = AppStore('${root.path}/library.db');
        model = AppModel(store, root, enableThumbnails: true);
        disposed = false;
        expect(model.thumbnailPath(id), path);
        expect(model.mediaDuration(store.get('media', id)!), closeTo(30, 1));
        await tester.pump(const Duration(milliseconds: 250));
        expect(await cover.lastModified(), modified);
        await model.pausePreviews();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await binding.setSurfaceSize(null);
        if (!disposed) {
          await model.pausePreviews();
          model.dispose();
          store.dispose();
        }
        await root.delete(recursive: true);
      }
    },
  );
}
