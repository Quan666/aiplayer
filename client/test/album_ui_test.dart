import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_filter_sheet.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:aiplayer/remote/remote_control_service.dart'
    show RemoteControlState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

AlbumSnapshot listing(int count) => AlbumIndex(
  [
    for (var i = 0; i < count; i++)
      SourceEntry(name: '${i.toString().padLeft(5, '0')}.jpg', path: '/$i.jpg'),
  ],
  sourceId: 'local',
  directory: '/',
).filter(AlbumOptions());

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var n = 0; n < 160 && !done(); n++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets('keyboard focus stays clear of the overlaid album controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final scroll = AlbumScrollController();
    final snapshot = listing(200);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlbumWall(
            snapshot: snapshot,
            controller: scroll,
            padding: const EdgeInsets.only(top: 72, bottom: 76),
            onOpen: (_) {},
            thumbnail: (_, _, _) => const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    Finder cell(int index) => find.descendant(
      of: find.byKey(ValueKey(snapshot.items[index].id)),
      matching: find.byType(InkWell),
    );
    tester.widget<InkWell>(cell(0)).focusNode!.requestFocus();
    await tester.pump();
    var index = 0;
    for (final direction in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
    ]) {
      for (var step = 0; step < 8; step++) {
        index += direction == LogicalKeyboardKey.arrowDown ? 4 : -4;
        await tester.sendKeyEvent(direction);
        await tester.pumpAndSettle();
        expect(tester.widget<InkWell>(cell(index)).focusNode!.hasFocus, isTrue);
        final rect = tester.getRect(cell(index));
        expect(rect.top, greaterThanOrEqualTo(72));
        expect(rect.bottom, lessThanOrEqualTo(424));
      }
    }
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
    'metadata anchor restoration yields to a new drag before its frame',
    (tester) async {
      final scroll = ScrollController();
      final wall = GlobalKey<AlbumWallState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumWall(
              key: wall,
              snapshot: listing(5000),
              controller: scroll,
              onOpen: (_) {},
              thumbnail: (_, _, _) => const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      );
      scroll.jumpTo(347.25);
      await tester.pump();
      wall.currentState!.restoreIndex(
        100,
        relativeOffset: 12.5,
        onlyWhenIdle: true,
      );
      final gesture = await tester.startGesture(const Offset(300, 250));
      await gesture.moveBy(const Offset(0, -40));
      expect(scroll.position.isScrollingNotifier.value, isTrue);
      final dragOffset = scroll.offset;
      await tester.pump();
      expect(scroll.offset, closeTo(dragOffset, .01));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'remote vertical navigation follows columns across partial date rows',
    (tester) async {
      final today = DateTime.now();
      final previous = DateTime(today.year, today.month, today.day - 1);
      final entries = [
        for (var index = 0; index < 3; index++)
          SourceEntry(name: 'a$index.jpg', path: '/a$index.jpg'),
        for (var index = 0; index < 5; index++)
          SourceEntry(name: 'b$index.jpg', path: '/b$index.jpg'),
      ];
      final catalog = AlbumIndex(
        entries,
        sourceId: 'local',
        directory: '/',
        metadata: {
          for (final entry in entries)
            entry.path: AlbumFileMetadata(
              capturedAt: entry.name.startsWith('a')
                  ? today.millisecondsSinceEpoch
                  : previous.millisecondsSinceEpoch,
            ),
        },
      );
      final snapshot = catalog.filter(
        AlbumOptions(sortField: 'captured', descending: true),
      );
      final nameSorted = catalog.filter(
        AlbumOptions(sortField: 'name', descending: false),
      );
      expect(nameSorted.wallSections.headerCount, 0);
      expect(nameSorted.wallSections.totalRows[3], 2);
      final modifiedSorted = catalog.filter(
        AlbumOptions(sortField: 'modified'),
      );
      expect(
        modifiedSorted.wallSections.headerCount,
        0,
      ); // No modified dates fabricated.
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumWall(
              snapshot: snapshot,
              controller: scroll,
              onOpen: (_) {},
              thumbnail: (_, _, _) => const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      );
      Finder button(int index) => find.descendant(
        of: find.byKey(ValueKey(snapshot.items[index].id)),
        matching: find.byType(InkWell),
      );
      tester.widget<InkWell>(button(0)).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(button(3)).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(button(0)).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(button(5)).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(button(7)).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(button(5)).focusNode!.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'capture dates use compact full-width lazy dividers and small group badges',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final today = DateTime.now();
      final previous = DateTime(today.year - 1, 9, 1);
      final entries = [
        const SourceEntry(name: 'a.jpg', path: '/a.jpg'),
        const SourceEntry(name: 'a.arw', path: '/a.arw'),
        const SourceEntry(name: 'b.jpg', path: '/b.jpg'),
        for (var index = 0; index < 5000; index++)
          SourceEntry(name: 'old$index.jpg', path: '/old$index.jpg'),
      ];
      final snapshot = AlbumIndex(
        entries,
        sourceId: 'local',
        directory: '/',
        metadata: {
          '/a.jpg': AlbumFileMetadata(capturedAt: today.millisecondsSinceEpoch),
          '/a.arw': AlbumFileMetadata(capturedAt: today.millisecondsSinceEpoch),
          '/b.jpg': AlbumFileMetadata(
            capturedAt: previous.millisecondsSinceEpoch,
          ),
        },
      ).filter(AlbumOptions(sortField: 'captured', descending: true));
      final scroll = ScrollController();
      final wall = GlobalKey<AlbumWallState>();
      var built = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumWall(
              key: wall,
              snapshot: snapshot,
              controller: scroll,
              onOpen: (_) {},
              thumbnail: (_, item, _) {
                built++;
                return ColoredBox(
                  key: ValueKey('tile:${item.id}'),
                  color: Colors.blue,
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('${today.month}月${today.day}日'), findsOneWidget);
      expect(find.text('${previous.year}年9月1日'), findsOneWidget);
      final currentDivider = tester.getRect(
        find.byKey(const ValueKey('album-day:0')),
      );
      expect(currentDivider.width, 400);
      expect(currentDivider.height, 22);
      final badge = find
          .ancestor(of: find.text('2'), matching: find.byType(SizedBox))
          .first;
      expect(tester.getSize(badge), const Size.square(18));
      expect(built, lessThan(50));
      wall.currentState!.restoreIndex(120, focus: true);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(wall.currentState!.anchorIndex, lessThanOrEqualTo(120));
      expect(built, lessThan(120));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'four-column wall has narrow gaps, no outer gutter and lazy remote navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scroll = ScrollController();
      final snapshot = listing(5000);
      AlbumItem? opened;
      var built = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => RemoteControlScope(child: child!),
          home: Scaffold(
            body: AlbumWall(
              snapshot: snapshot,
              controller: scroll,
              onOpen: (value) => opened = value,
              thumbnail: (_, item, _) {
                built++;
                return ColoredBox(
                  key: ValueKey('image:${item.id}'),
                  color: Colors.blue,
                );
              },
            ),
          ),
        ),
      );
      final first = find.byKey(ValueKey('image:${snapshot.items[0].id}'));
      final second = find.byKey(ValueKey('image:${snapshot.items[1].id}'));
      final fourth = find.byKey(ValueKey('image:${snapshot.items[3].id}'));
      final fifth = find.byKey(ValueKey('image:${snapshot.items[4].id}'));
      expect(tester.getTopLeft(first), Offset.zero);
      expect(tester.getTopLeft(second).dx - tester.getTopRight(first).dx, 1.5);
      expect(tester.getTopRight(fourth).dx, 600);
      expect(tester.getTopLeft(fourth).dy, 0);
      expect(tester.getTopLeft(fifth).dy - tester.getBottomLeft(first).dy, 1.5);
      expect(built, lessThan(50));
      final firstButton = find.descendant(
        of: find.byKey(ValueKey(snapshot.items.first.id)),
        matching: find.byType(InkWell),
      );
      tester.widget<InkWell>(firstButton).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(opened?.id, snapshot.items[1].id);
      final remote = tester.state<RemoteControlScopeState>(
        find.byType(RemoteControlScope),
      );
      remote.service.value = const RemoteControlState(phase: 'connected');
      for (var n = 0; n < 4; n++) {
        final result = await remote.service.onCommand(
          RemoteCommand(n, 'down', null, null, null, () => true),
        );
        expect(result.ok, isTrue);
        await tester.pumpAndSettle();
      }
      expect(scroll.offset, greaterThan(0));
      final remoteTarget = find.descendant(
        of: find.byKey(ValueKey(snapshot.items[17].id)),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(remoteTarget).focusNode!.hasFocus, isTrue);
      final activated = await remote.service.onCommand(
        RemoteCommand(5, 'select', null, null, null, () => true),
      );
      expect(activated.ok, isTrue);
      expect(opened?.id, snapshot.items[17].id);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'filter sheet selects exact type chips and clears removed constraints',
    (tester) async {
      AlbumOptions? applied;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('open'),
                onPressed: () async {
                  applied = await showAlbumFilterSheet(
                    context,
                    initial: AlbumOptions(
                      types: ['*'],
                      query: 'old',
                      minSize: 1024,
                    ),
                    snapshot: AlbumIndex(
                      [
                        for (final ext in ['jpg', 'jpeg', 'arw'])
                          SourceEntry(name: '001.$ext', path: '/001.$ext'),
                      ],
                      sourceId: 'local',
                      directory: '/',
                    ).filter(AlbumOptions()),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('album-type:*')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-type:.jpg')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-type:.arw')));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(applied!.types, {'.jpg', '.arw'});
      expect(applied!.includeExtensions, isEmpty);
      expect(applied!.excludeExtensions, isEmpty);
      expect(applied!.query, isEmpty);
      expect(applied!.minSize, isNull);
      expect(applied!.groupPhotos, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local album opens mixed same-name group and exposes format switch',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('album-ui-');
        final photos = await Directory('${root.path}/photos').create();
        final bytes = image.encodeJpg(image.Image(width: 20, height: 20));
        await File('${photos.path}/001.jpg').writeAsBytes(bytes);
        await File('${photos.path}/001.jpeg').writeAsBytes(bytes);
        await File('${photos.path}/001.arw').writeAsBytes([0, 1, 2, 3]);
        await File('${photos.path}/002.jpg').writeAsBytes(bytes);
        return root;
      }))!;
      final photos = Directory('${root.path}/photos');
      final store = AppStore(':memory:');
      final model = AppModel(store, root, backgroundWork: false);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumPage(
            model: model,
            source: const {'id': 'local', 'kind': 'local'},
            initialPath: photos.path,
          ),
        ),
      );
      await pumpUntil(
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
      final wall = tester.widget<AlbumWall>(find.byType(AlbumWall));
      final group = wall.snapshot.items.firstWhere(
        (item) => item.preferred.name == '001.jpg',
      );
      expect(group.members.length, 3);
      final firstCell = find.byKey(ValueKey(wall.snapshot.items.first.id));
      expect(
        tester.getTopLeft(firstCell).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppBar)).dy),
      );
      await tester.tap(find.byKey(ValueKey(group.id)));
      await pumpUntil(
        tester,
        () => find.byTooltip('选择格式').evaluate().isNotEmpty,
      );
      final route = ModalRoute.of(tester.element(find.byType(AlbumViewer)))!;
      for (var n = 0; n < 40 && !route.animation!.isCompleted; n++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(route.animation!.isCompleted, isTrue);
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('album-image-loading'))
            .evaluate()
            .isEmpty,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择格式'));
      await tester.pumpAndSettle();
      expect(find.text('001.arw'), findsOneWidget);
      expect(find.text('001.jpeg'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final decodes = ArtworkDecodeQueue.instance;
      await pumpUntil(
        tester,
        () => decodes.activeCount == 0 && decodes.pendingCount == 0,
      );
      await tester.runAsync(() async {
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      });
      expect(tester.takeException(), isNull);
    },
  );
}
