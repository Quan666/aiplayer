import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/album_viewer.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

void main() {
  testWidgets('file view opens the tapped photo format when names match', (
    tester,
  ) async {
    final directory = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('file-photo-');
      final photo = images.Image(width: 24, height: 16);
      await File('${directory.path}/same.jpg')
          .writeAsBytes(images.encodeJpg(photo));
      await File('${directory.path}/same.png')
          .writeAsBytes(images.encodePng(photo));
      return directory;
    }))!;
    final selected = '${directory.path}/same.png';
    final store = AppStore(':memory:');
    final model = AppModel(store, directory, backgroundWork: false);
    Future<void> until(bool Function() ready) async {
      for (var count = 0; count < 200 && !ready(); count++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(ready(), isTrue);
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SourceBrowser(
            model: model,
            source: const {'id': 'local', 'kind': 'local', 'label': '本地'},
            initialPath: directory.path,
            initialAlbumMode: false,
          ),
        ),
      );
      await until(() => find.text('same.png').evaluate().isNotEmpty);
      await tester.tap(find.text('same.png'));
      await until(() => find.byType(AlbumViewer).evaluate().isNotEmpty);
      final viewer = tester.widget<AlbumViewer>(find.byType(AlbumViewer));
      final item = viewer.snapshot.items[viewer.initialIndex];
      expect(item.preferred.path, selected);
      expect(item.members, hasLength(1));
      expect(viewer.snapshot.items, hasLength(2));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
