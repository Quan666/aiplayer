import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_catalog_worker.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final television in [false, true]) {
    testWidgets('album focus border is television only: $television', (
      tester,
    ) async {
      final scroll = ScrollController();
      final snapshot = AlbumIndex(
        const [SourceEntry(name: 'photo.jpg', path: '/photo.jpg')],
        sourceId: 'local',
        directory: '/',
      ).filter(AlbumOptions());
      await tester.pumpWidget(
        MaterialApp(
          home: TelevisionMode(
            enabled: television,
            child: Scaffold(
              body: AlbumWall(
                snapshot: snapshot,
                controller: scroll,
                onOpen: (_) {},
                thumbnail: (_, _, _) => const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      final cell = find.descendant(
        of: find.byType(AlbumWall),
        matching: find.byType(InkWell),
      );
      final ink = tester.widget<InkWell>(cell);
      ink.focusNode!.requestFocus();
      await tester.pump();
      expect(ink.focusNode!.hasFocus, isTrue);
      final borders = find.descendant(
        of: find.byType(AlbumWall),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border != null,
        ),
      );
      expect(borders, television ? findsOneWidget : findsNothing);
      if (!television) expect(ink.focusColor, Colors.transparent);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
  }

  testWidgets('TV album cells separate short OK, held OK and menu presses', (
    tester,
  ) async {
    final scroll = ScrollController();
    final snapshot = AlbumIndex(
      const [SourceEntry(name: 'photo.jpg', path: '/photo.jpg')],
      sourceId: 'local',
      directory: '/',
    ).filter(AlbumOptions());
    var opened = 0, menus = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(
          body: AlbumWall(
            snapshot: snapshot,
            controller: scroll,
            onOpen: (_) => opened++,
            onMenu: (_) => menus++,
            thumbnail: (_, _, _) => const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    tester
        .widget<InkWell>(
          find.descendant(
            of: find.byType(AlbumWall),
            matching: find.byType(InkWell),
          ),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(opened, 1);
    expect(menus, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 650));
    expect(menus, 1);
    expect(opened, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(opened, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    expect(menus, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 550));
    expect(menus, 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  for (final mode in ['files', 'album', 'album-menu']) {
    final startAlbum = mode != 'files';
    testWidgets(
      startAlbum
          ? 'album $mode control switches child folder to files and persists that choice'
          : 'opening a photo from files returns to files without enabling album mode',
      (tester) async {
        final root = (await tester.runAsync(() async {
          final root = await Directory.systemTemp.createTemp('album-mode-');
          final folder = await Directory('${root.path}/photos/child')
              .create(recursive: true);
          final bytes = image.encodeJpg(image.Image(width: 16, height: 12));
          await File('${root.path}/photos/a.jpg').writeAsBytes(bytes);
          if (!startAlbum) {
            await File('${root.path}/photos/movie.mp4').writeAsBytes([0]);
          }
          await File('${folder.path}/child.jpg').writeAsBytes(bytes);
          return root;
        }))!;
        final store = AppStore('${root.path}/library.db');
        final model = AppModel(store, root, backgroundWork: false);
        final settings = AlbumCatalogWorker();
        final folder = '${root.path}/photos';
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: SourceBrowser(
                model: model,
                source: const {'id': 'local', 'kind': 'local', 'label': '本地'},
                initialPath: folder,
                initialAlbumMode: startAlbum ? true : null,
              ),
            ),
          );
          if (startAlbum) {
            await until(
              tester,
              () =>
                  find.byType(AlbumWall).evaluate().isNotEmpty &&
                  tester
                          .widget<AlbumWall>(find.byType(AlbumWall))
                          .snapshot
                          .items
                          .length ==
                      2,
            );
            await tester.tap(find.text('child'));
            await until(
              tester,
              () =>
                  tester
                      .widget<AlbumWall>(find.byType(AlbumWall))
                      .snapshot
                      .items
                      .singleOrNull
                      ?.preferred
                      .name ==
                  'child.jpg',
            );
            expect(find.byTooltip('文件视图'), findsOneWidget);
            await tester.tap(find.byTooltip('相册选项'));
            await tester.pumpAndSettle();
            expect(find.text('沉浸浏览'), findsNothing);
            expect(find.text('读取拍摄信息'), findsNothing);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            await until(
              tester,
              () =>
                  tester
                      .widget<IconButton>(
                        find.ancestor(
                          of: find.byTooltip('文件视图'),
                          matching: find.byType(IconButton),
                        ),
                      )
                      .onPressed !=
                  null,
            );
            if (mode == 'album-menu') {
              await tester.tap(find.byTooltip('相册选项'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('文件视图'));
            } else {
              await tester.tap(find.byTooltip('文件视图'));
            }
            await until(
              tester,
              () =>
                  find.byType(AlbumPage).evaluate().isEmpty &&
                  find.text('child.jpg').evaluate().isNotEmpty,
            );
            final prefs = await tester.runAsync(
              () => settings.readPreferences(
                albumSettingsPath(root.path, 'local', '$folder/child'),
              ),
            );
            expect(prefs?['album'], isFalse);
          } else {
            await until(tester, () => find.text('a.jpg').evaluate().isNotEmpty);
            await until(
              tester,
              () => find.byType(AlbumThumbnail).evaluate().isNotEmpty,
            );
            expect(find.byType(AlbumVideoThumbnail), findsOneWidget);
            final thumbnail = tester.widget<AlbumThumbnail>(
              find.byType(AlbumThumbnail).first,
            );
            await until(
              tester,
              () => thumbnail.service.peek(thumbnail.entry) != null,
            );
            final preview = thumbnail.service.peek(thumbnail.entry)!;
            await tester.tap(find.text('a.jpg'));
            await until(
              tester,
              () => find.byType(AlbumViewer).evaluate().isNotEmpty,
            );
            final route = ModalRoute.of(
              tester.element(find.byType(AlbumViewer)),
            )!;
            await until(tester, () => route.animation!.isCompleted);
            expect(find.byType(AlbumPage), findsNothing);
            expect(
              tester
                  .widget<AlbumViewer>(find.byType(AlbumViewer))
                  .initialPreview
                  ?.path,
              preview.path,
            );
            await tester.tap(
              find.descendant(
                of: find.byType(AlbumViewer),
                matching: find.byType(BackButton),
              ),
            );
            await until(
              tester,
              () =>
                  find.byType(AlbumViewer).evaluate().isEmpty &&
                  find.text('a.jpg').evaluate().isNotEmpty,
            );
            expect(find.byType(AlbumPage), findsNothing);
            final prefs = await tester.runAsync(
              () => settings.readPreferences(
                albumSettingsPath(root.path, 'local', folder),
              ),
            );
            expect(prefs?['album'], isNot(true));
            expect(store.records('media'), isEmpty);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          final decodes = ArtworkDecodeQueue.instance;
          await until(
            tester,
            () => decodes.activeCount == 0 && decodes.pendingCount == 0,
          );
          await tester.runAsync(settings.flushPreferencesAndClose);
          model.dispose();
          var flushed = false;
          unawaited(model.flushMetadataTasks().then((_) => flushed = true));
          await until(tester, () => flushed);
          await tester.runAsync(() async {
            store.dispose();
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
