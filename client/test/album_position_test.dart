import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_catalog_worker.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

Future<void> until(
  WidgetTester tester,
  bool Function() ready, {
  Duration? timeout,
}) async {
  final wait = Stopwatch()..start();
  for (var i = 0; !ready(); i++) {
    if (timeout == null ? i >= 180 : wait.elapsed >= timeout) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

Future<void> flushPages(WidgetTester tester) async {
  await until(tester, () => AlbumPage.pendingDisposals == 0);
}

void main() {
  testWidgets(
    'TV album return and reopen preserve focus and viewport; menu returns to the same cell',
    (tester) async {
      final root = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('album-tv-return-');
        for (var i = 0; i < 40; i++) {
          await Directory('${root.path}/album${i.toString().padLeft(2, '0')}')
              .create();
          await Directory(
            '${root.path}/album08/child${i.toString().padLeft(2, '0')}',
          ).create(recursive: true);
        }
        return root;
      }))!;
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      AlbumWall wall() => tester.widget<AlbumWall>(find.byType(AlbumWall));
      AlbumWallState state() =>
          tester.state<AlbumWallState>(find.byType(AlbumWall));
      FocusNode focus(String id) => tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(ValueKey(id)),
              matching: find.byType(InkWell),
            ),
          )
          .focusNode!;
      Future<void> loaded(String firstName) => until(
        tester,
        () =>
            find.byType(AlbumWall).evaluate().isNotEmpty &&
            wall().snapshot.items.length == 40 &&
            wall().snapshot.items.first.name == firstName &&
            tester
                    .widget<IconButton>(
                      find.widgetWithIcon(IconButton, Icons.sort),
                    )
                    .onPressed !=
                null &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      Future<void> menu() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump(TelevisionInputScope.menuDoublePressInterval);
        await tester.pump(const Duration(milliseconds: 200));
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                TelevisionInputScope(overrideTelevision: true, child: child!),
            home: AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: root.path,
              initialEntries: [
                for (var i = 0; i < 40; i++)
                  SourceEntry(
                    name: 'album${i.toString().padLeft(2, '0')}',
                    path: '${root.path}/album${i.toString().padLeft(2, '0')}',
                    directory: true,
                  ),
              ],
            ),
          ),
        );
        await loaded('album00');
        wall().controller.jumpTo(327.25);
        await tester.pump();
        final parentId = wall().snapshot.items[8].id;
        focus(parentId).requestFocus();
        await tester.pump();
        final parentOffset = wall().controller.offset;
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await loaded('child00');
        await tester.pump();
        await until(
          tester,
          () => focus(wall().snapshot.items.first.id).hasFocus,
        );
        wall().controller.jumpTo(450.25);
        await tester.pump();
        final childId = wall().snapshot.items[9].id;
        focus(childId).requestFocus();
        await tester.pump();
        final childOffset = wall().controller.offset;
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getRect(find.byType(AppBar)).bottom,
          lessThanOrEqualTo(0),
        );
        await menu();
        expect(tester.getRect(find.byType(AppBar)).top, closeTo(0, .01));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(focus(childId).hasFocus, isTrue);
        expect(wall().controller.offset, closeTo(childOffset, .01));

        await menu();
        await tester.tap(find.byType(BackButton));
        await loaded('album00');
        await tester.pump();
        expect(state().focusedId, parentId);
        expect(focus(parentId).hasFocus, isTrue);
        expect(wall().controller.offset, closeTo(parentOffset, .01));
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await loaded('child00');
        await tester.pump();
        expect(state().focusedId, childId);
        expect(focus(childId).hasFocus, isTrue);
        expect(wall().controller.offset, closeTo(childOffset, .01));
        await tester.pump(const Duration(seconds: 10));
        expect(wall().controller.offset, closeTo(childOffset, .01));
        expect(focus(childId).hasFocus, isTrue);
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                TelevisionInputScope(overrideTelevision: true, child: child!),
            home: AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: '${root.path}/album08',
            ),
          ),
        );
        await loaded('child00');
        await tester.pump();
        expect(focus(childId).hasFocus, isTrue);
        expect(wall().controller.offset, closeTo(childOffset, .01));
        wall().controller.jumpTo(0);
        await tester.pump();
        final firstRowId = wall().snapshot.items[2].id;
        focus(firstRowId).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(focus(firstRowId).hasFocus, isTrue);
        expect(wall().controller.offset, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        model.dispose();
        store.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  for (final preset in ['default', 'legacy', 'explicit', 'custom']) {
    testWidgets('album name default and saved sort migration: $preset', (
      tester,
    ) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-default-'),
      ))!;
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      final descending = preset == 'explicit' || preset == 'custom';
      final savedOptions = <String, dynamic>{
        'types': ['*'],
        if (preset != 'default')
          'sortField': preset == 'custom' ? 'modified' : 'captured',
        if (preset != 'default') 'descending': true,
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: root.path,
              initialSettings: {
                'options': savedOptions,
                if (preset == 'explicit') 'sortSelected': true,
              },
              initialEntries: [
                for (final number in [10, 2, 1])
                  SourceEntry(
                    name: 'item$number.txt',
                    path: '${root.path}/item$number.txt',
                    modified: number,
                  ),
              ],
            ),
          ),
        );
        await until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              tester
                      .widget<AlbumWall>(find.byType(AlbumWall))
                      .snapshot
                      .items
                      .length ==
                  3,
        );
        expect(
          tester
              .widget<AlbumWall>(find.byType(AlbumWall))
              .snapshot
              .items
              .map((item) => item.name),
          descending
              ? ['item10.txt', 'item2.txt', 'item1.txt']
              : ['item1.txt', 'item2.txt', 'item10.txt'],
        );
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        final saved = (await tester.runAsync(
          () async => jsonDecode(
            await File(albumSettingsPath(root.path, 'local', root.path))
                .readAsString(),
          ) as Map,
        ))!;
        expect(
          saved['options']['sortField'],
          descending ? (preset == 'custom' ? 'modified' : 'captured') : 'name',
        );
        expect(saved['options']['descending'], descending);
        expect(saved['sortSelected'], descending);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        model.dispose();
        store.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'preview metadata keeps order and viewport until an explicit sort',
    (tester) async {
      final entries = <SourceEntry>[];
      final metadata = <String, AlbumFileMetadata>{};
      final root = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'album-position-id-',
        );
        for (var i = 0; i < 96; i++) {
          final name = '${i.toString().padLeft(3, '0')}.jpg';
          final file = File('${root.path}/$name');
          final photo = images.Image(width: 40, height: 30);
          final year = i < 43 ? 2020 : 2026;
          photo.exif.exifIfd['DateTimeOriginal'] = '$year:11:04 12:00:00';
          final bytes = images.encodeJpg(photo);
          await file.writeAsBytes(bytes);
          entries.add(
            SourceEntry(
              name: name,
              path: file.path,
              size: bytes.length,
              modified: 1,
            ),
          );
          metadata[file.path] = AlbumFileMetadata(
            capturedAt: DateTime(year, 11, 4, 12).millisecondsSinceEpoch,
            width: 40,
            height: 30,
          );
        }
        return root;
      }))!;
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      final worker = AlbumCatalogWorker();
      const relative = 13.25;
      final wallKey = GlobalKey<AlbumWallState>();
      final referenceScroll = ScrollController();
      Widget frame(Widget child) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 24),
          ),
          child: child,
        ),
      );
      try {
        final known = (await tester.runAsync(
          () => worker.build(
            entries,
            sourceId: 'local',
            directory: root.path,
            metadata: metadata,
            options: AlbumOptions(sortField: 'captured', descending: true),
          ),
        ))!;
        final id = known.items[known.indexByPath['${root.path}/024.jpg']!].id;
        await tester.pumpWidget(
          frame(
            AlbumWall(
              key: wallKey,
              snapshot: known,
              controller: referenceScroll,
              padding: const EdgeInsets.only(top: 72),
              thumbnail: (_, _, _) => const SizedBox(),
              onOpen: (_) {},
            ),
          ),
        );
        final savedOffset =
            wallKey.currentState!.itemScrollOffset(known.indexById[id]!) +
            relative;
        await tester.runAsync(
          () => worker.savePreferences(
            albumSettingsPath(root.path, 'local', root.path),
            {
              'options': AlbumOptions(
                sortField: 'captured',
                descending: true,
              ).toJson(),
              'sortSelected': true,
              'viewport': {
                'offset': savedOffset,
                'id': id,
                'relativeOffset': relative,
              },
            },
          ),
        );
        await tester.pumpWidget(
          frame(
            AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: root.path,
              initialEntries: entries,
            ),
          ),
        );
        AlbumWall wall() => tester.widget<AlbumWall>(find.byType(AlbumWall));
        AlbumWallState wallState() =>
            tester.state<AlbumWallState>(find.byType(AlbumWall));
        await until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              wall().snapshot.items.length == entries.length,
        );
        final initial = wall().snapshot;
        expect(initial.items.every((item) => item.capturedAt == null), isTrue);
        expect(initial.indexById[id], isNot(known.indexById[id]));
        expect(
          wall().controller.offset,
          closeTo(
            wallState().itemScrollOffset(initial.indexById[id]!) + relative,
            .01,
          ),
        );

        final initialOrder = initial.items.map((item) => item.id).toList();
        final initialSections = [
          for (final section in initial.wallSections.sections)
            (section.itemStart, section.itemEnd, section.day),
        ];
        final offsetBeforeMetadata = wall().controller.offset;
        final publications = Set<AlbumSnapshot>.identity()..add(initial);
        // The worker reads all 96 EXIF headers sequentially. Its readiness
        // depends on real I/O, so keep checking layout while allowing a slower
        // runner to complete the batch instead of budgeting fake frames.
        await until(tester, () {
          final current = wall().snapshot;
          publications.add(current);
          expect(current.items.map((item) => item.id), initialOrder);
          expect([
            for (final section in current.wallSections.sections)
              (section.itemStart, section.itemEnd, section.day),
          ], initialSections);
          expect(wall().controller.offset, closeTo(offsetBeforeMetadata, .01));
          return current.items.every((item) => item.capturedAt != null);
        }, timeout: const Duration(seconds: 10));
        // Default indexing batches its facts without repeatedly publishing the
        // full wall. Both order and date rows stay fixed when facts arrive.
        expect(publications.length, lessThanOrEqualTo(2));
        expect(wall().snapshot.indexById[id], initial.indexById[id]);
        await tester.tap(find.byTooltip('排序'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用'));
        await until(
          tester,
          () => wall().snapshot.indexById[id] == known.indexById[id],
        );
        expect(
          wall().snapshot.items.map((item) => item.id),
          known.items.map((item) => item.id),
        );
        expect(
          wall().controller.offset,
          closeTo(
            wallState().itemScrollOffset(wall().snapshot.indexById[id]!) +
                relative,
            .01,
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        final saved = await tester.runAsync(
          () async => jsonDecode(
            await File(albumSettingsPath(root.path, 'local', root.path))
                .readAsString(),
          ) as Map,
        );
        expect(saved!['viewport']['id'], id);
        expect(saved['viewport']['relativeOffset'], closeTo(relative, .01));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        referenceScroll.dispose();
        await tester.runAsync(worker.flushPreferencesAndClose);
        model.dispose();
        store.dispose();
        await tester.runAsync(() async {
          await root.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'directory return keeps its snapshot and saves fractional position',
    (tester) async {
      final root = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('album-position-');
        await Directory('${root.path}/child').create();
        return root;
      }))!;
      final entries = [
        SourceEntry(name: 'child', path: '${root.path}/child', directory: true),
        for (var i = 0; i < 160; i++)
          SourceEntry(name: '$i.txt', path: '${root.path}/$i.txt'),
      ];
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      final pageKey = GlobalKey();
      Widget page({
        bool fresh = false,
        double? initialOffset,
        int initialAnchor = 0,
      }) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 24),
          ),
          child: AlbumPage(
            key: fresh ? null : pageKey,
            model: model,
            source: const {'id': 'local', 'kind': 'local'},
            initialPath: root.path,
            initialOffset: initialOffset,
            initialAnchor: initialAnchor,
            initialEntries: entries,
            initialSettings: fresh
                ? null
                : {
                    'options': AlbumOptions(types: const {'*'}).toJson(),
                  },
          ),
        ),
      );
      AlbumWall wall() => tester.widget<AlbumWall>(find.byType(AlbumWall));
      bool loaded() =>
          find.byType(AlbumWall).evaluate().isNotEmpty &&
          wall().snapshot.items.length == entries.length &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty;
      try {
        await tester.pumpWidget(page());
        await until(tester, loaded);
        await tester.pump();
        final snapshot = wall().snapshot;
        final first = find.byKey(ValueKey(snapshot.items.first.id));
        final toolbar = tester.getRect(find.byType(AppBar));
        expect(tester.getRect(first).top, greaterThanOrEqualTo(toolbar.bottom));
        expect(toolbar.top, 0);
        final scroll = wall().controller;
        scroll.jumpTo(327.25);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.getRect(find.byType(AppBar)).bottom,
          lessThanOrEqualTo(0),
        );
        // Navigation uses the same callback as a wall tap, after a free scroll.
        wall().onOpen(snapshot.items.firstWhere((item) => item.isDirectory));
        await until(tester, () => find.text('没有符合条件的项目').evaluate().isNotEmpty);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        expect(wall().snapshot, same(snapshot));
        expect(wall().controller.offset, closeTo(327.25, .01));
        await until(tester, loaded);
        await tester.pump();
        expect(wall().controller.offset, closeTo(327.25, .01));
        await tester.pumpWidget(const SizedBox());
        // Wait for the real worker flush before recreating the page.
        await flushPages(tester);
        await tester.pumpWidget(page(fresh: true));
        await until(tester, loaded);
        await tester.pump();
        expect(wall().controller.offset, closeTo(327.25, .01));

        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        await tester.pumpWidget(page(fresh: true, initialOffset: 123.75));
        await until(tester, loaded);
        expect(wall().controller.offset, closeTo(123.75, .01));

        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        await tester.pumpWidget(page(fresh: true, initialAnchor: 8));
        await until(tester, loaded);
        final state = tester.state<AlbumWallState>(find.byType(AlbumWall));
        expect(
          wall().controller.offset,
          closeTo(state.itemScrollOffset(8), .01),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushPages(tester);
        model.dispose();
        store.dispose();
        await tester.runAsync(() async {
          await root.delete(recursive: true);
        });
      }
    },
  );
}
