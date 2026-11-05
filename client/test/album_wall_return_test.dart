import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'returning to an unchanged large wall does not rebuild its cells',
    (tester) async {
      final snapshot = AlbumIndex(
        [
          for (var i = 0; i < 10000; i++)
            SourceEntry(name: '$i.jpg', path: '/$i.jpg'),
        ],
        sourceId: 'local',
        directory: '/',
      ).filter(AlbumOptions());
      final controller = AlbumScrollController();
      final wall = GlobalKey<AlbumWallState>();
      var cellsBuilt = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumWall(
            key: wall,
            snapshot: snapshot,
            controller: controller,
            onOpen: (_) {},
            thumbnail: (_, _, _) {
              cellsBuilt++;
              return const ColoredBox(color: Colors.blue);
            },
          ),
        ),
      );
      controller.jumpTo(347.25);
      await tester.pumpAndSettle();
      final built = cellsBuilt;
      expect(built, lessThan(100));
      for (var i = 0; i < 20; i++) {
        wall.currentState!.restoreViewport(347.25);
        await tester.pump();
      }
      expect(cellsBuilt, built);
      expect(controller.offset, 347.25);
      expect(controller.restoring, isFalse);

      wall.currentState!.restoreViewport(1800);
      await tester.pumpAndSettle();
      expect(controller.offset, 1800);
      expect(cellsBuilt, greaterThan(built));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
