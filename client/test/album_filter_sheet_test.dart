import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_filter_sheet.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final index = AlbumIndex(
    const [
      SourceEntry(name: 'trip', path: '/trip', directory: true),
      SourceEntry(name: '001.jpg', path: '/001.jpg'),
      SourceEntry(name: '001.jpeg', path: '/001.jpeg'),
      SourceEntry(name: '001.arw', path: '/001.arw'),
      SourceEntry(name: 'notes.txt', path: '/notes.txt'),
      SourceEntry(name: 'readme', path: '/readme'),
    ],
    sourceId: 'nas',
    directory: '/',
  );
  AlbumOptions? applied;

  Future<void> mount(
    WidgetTester tester, {
    AlbumOptions? initial,
    AlbumSnapshot? snapshot,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    applied = null;
    final options = initial ?? AlbumOptions();
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => applied = await showAlbumFilterSheet(
                context,
                initial: options,
                snapshot: snapshot ?? index.filter(options),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder chip(String type) => find.byKey(ValueKey('album-type:$type'));

  testWidgets(
    'compact phone sheet selects folders without hidden old constraints',
    (tester) async {
      await mount(
        tester,
        initial: AlbumOptions(
          types: const {'*'},
          query: 'legacy',
          minSize: 100,
          orientation: 'portrait',
          kinds: const {MediaKind.image},
          includeExtensions: const {'.jpg'},
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('类型'), findsWidgets);
      expect(find.text('TXT'), findsOneWidget);
      expect(find.text('无后缀'), findsOneWidget);
      await tester.tap(chip('*'));
      await tester.pump();
      await tester.tap(chip('folder'));
      await tester.pump();
      expect(tester.widget<FilterChip>(chip('folder')).selected, isTrue);
      expect(tester.widget<FilterChip>(chip('*')).selected, isFalse);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(applied!.types, {'folder'});
      expect(applied!.query, isEmpty);
      expect(applied!.minSize, isNull);
      expect(applied!.orientation, 'any');
      expect(applied!.kinds, isEmpty);
      expect(applied!.includeExtensions, isEmpty);
      final result = index.filter(applied!);
      expect(result.items, hasLength(1));
      expect(result.items.single.isDirectory, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exact dynamic suffixes support one or several selected formats',
    (tester) async {
      await mount(tester, initial: AlbumOptions(types: const {'*'}));
      await tester.tap(chip('*'));
      await tester.pump();
      await tester.tap(chip('.jpg'));
      await tester.pump();
      expect(tester.widget<FilterChip>(chip('.jpg')).selected, isTrue);
      expect(tester.widget<FilterChip>(chip('.jpeg')).selected, isFalse);
      await tester.tap(chip('.jpeg'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(applied!.types, {'.jpg', '.jpeg'});
      expect(
        index.filter(applied!).items.single.members.map((entry) => entry.name),
        containsAll(['001.jpg', '001.jpeg']),
      );
      expect(index.filter(applied!).matchedFileCount, 2);
    },
  );

  testWidgets('All mirrors its formats and four types fit in one phone row', (
    tester,
  ) async {
    final compact = AlbumIndex(
      const [
        SourceEntry(name: 'a.jpg', path: '/a.jpg'),
        SourceEntry(name: 'b.png', path: '/b.png'),
        SourceEntry(name: 'c.mp4', path: '/c.mp4'),
      ],
      sourceId: 'nas',
      directory: '/',
    ).filter(AlbumOptions());
    await mount(
      tester,
      initial: AlbumOptions(types: const {'*'}),
      snapshot: compact,
    );
    for (final type in ['*', '.jpg', '.mp4', '.png']) {
      expect(tester.widget<FilterChip>(chip(type)).selected, isTrue);
      expect(tester.getTopLeft(chip(type)).dy, tester.getTopLeft(chip('*')).dy);
    }
    expect(
      tester.getTopLeft(chip('.jpg')).dx - tester.getTopRight(chip('*')).dx,
      closeTo(6, .01),
    );
    expect(tester.getTopLeft(chip('*')).dx, 12);
    await tester.tap(chip('.jpg'));
    await tester.pump();
    expect(tester.widget<FilterChip>(chip('*')).selected, isFalse);
    expect(tester.widget<FilterChip>(chip('.jpg')).selected, isFalse);
    expect(tester.widget<FilterChip>(chip('.png')).selected, isTrue);
    await tester.tap(chip('.jpg'));
    await tester.pump();
    expect(tester.widget<FilterChip>(chip('*')).selected, isTrue);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(applied!.types, {'*'});
  });

  testWidgets(
    'short filter content sizes its sheet without empty bottom space',
    (tester) async {
      await mount(tester);
      final sheet = tester.getRect(find.byType(AlbumFilterSheet));
      final last = tester.getRect(
        find.widgetWithText(SwitchListTile, '不显示隐藏文件'),
      );
      expect(sheet.bottom - last.bottom, lessThan(32));
      expect(sheet.height, lessThan(480));
    },
  );

  testWidgets(
    'empty type selection disables Apply and reset restores defaults',
    (tester) async {
      await mount(tester, initial: AlbumOptions(types: const {'.jpg'}));
      await tester.tap(chip('.jpg'));
      await tester.pump();
      final apply = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '应用'),
      );
      expect(apply.onPressed, isNull);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(applied!.types, isEmpty);
      expect(applied!.groupPhotos, isTrue);
    },
  );

  testWidgets(
    'default selection comes from worker and large type grids stay lazy',
    (tester) async {
      final snapshot = AlbumSnapshot(
        items: const [],
        availableExtensions: const [],
        availableTypes: ['folder', for (var i = 0; i < 1000; i++) '.kind$i'],
        defaultTypes: const {'folder'},
        matchedFileCount: 0,
        pendingMetadataCount: 0,
        totalFileCount: 1000,
      );
      await mount(tester, snapshot: snapshot);
      expect(tester.widget<FilterChip>(chip('folder')).selected, isTrue);
      expect(find.byType(FilterChip).evaluate().length, lessThan(70));
      expect(chip('.kind999'), findsNothing);
      expect(find.text('应用'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('album-filter-scroll')),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FilterChip).evaluate().length, lessThan(70));
      expect(find.text('应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
