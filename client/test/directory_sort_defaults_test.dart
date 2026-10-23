import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'global sorting updates existing folders, new defaults and independent overrides across restart',
    () {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-sort-defaults-',
      );
      final database = '${root.path}/library.db';
      var store = AppStore(database);
      var model = AppModel(store, root);
      const visibleSubtitles = 'directorySort:nas:Shows/A/';
      const hiddenSubtitles = 'directorySort:nas:Shows/B/';
      const imports = 'directorySort:local:imports';
      const newFolder = 'directorySort:second-server:New/';
      const entries = [
        SourceEntry(name: 'Episode2.mkv', path: '2'),
        SourceEntry(name: 'Episode10.mkv', path: '10'),
        SourceEntry(name: 'Episode2.ass', path: 'subtitle'),
      ];
      try {
        model.setDirectorySorting(
          visibleSubtitles,
          const DirectorySort(field: 'modified', showSubtitles: true),
        );
        model.setDirectorySorting(
          hiddenSubtitles,
          const DirectorySort(field: 'size', descending: true),
        );
        model.setDirectorySorting(
          imports,
          const DirectorySort(field: 'type', showSubtitles: true),
        );
        model.applyDirectorySortingToAll(
          const DirectorySort(descending: true, showSubtitles: true),
        );
        for (final key in [
          visibleSubtitles,
          hiddenSubtitles,
          imports,
          newFolder,
        ]) {
          final sorting = model.directorySorting(key);
          expect(sorting.field, 'name', reason: key);
          expect(sorting.descending, isTrue, reason: key);
        }
        expect(model.directorySorting(visibleSubtitles).showSubtitles, isTrue);
        expect(model.directorySorting(imports).showSubtitles, isTrue);
        expect(model.directorySorting(hiddenSubtitles).showSubtitles, isFalse);
        expect(model.directorySorting(newFolder).showSubtitles, isFalse);
        expect(store.local(newFolder), isNull);

        model.setDirectorySorting(
          visibleSubtitles,
          model.directorySorting(visibleSubtitles).copyWith(descending: false),
        );
        expect(model.directorySorting(visibleSubtitles).descending, isFalse);
        expect(model.directorySorting(hiddenSubtitles).descending, isTrue);
        expect(model.directorySorting(newFolder).descending, isTrue);
        model.dispose();
        store.dispose();
        store = AppStore(database);
        model = AppModel(store, root);

        final own = model.directorySorting(visibleSubtitles);
        expect(own.field, 'name');
        expect(own.descending, isFalse);
        expect(own.showSubtitles, isTrue);
        expect(own.apply(entries).map((entry) => entry.path), [
          'subtitle',
          '2',
          '10',
        ]);
        for (final key in [hiddenSubtitles, newFolder]) {
          final sorting = model.directorySorting(key);
          expect(sorting.field, 'name', reason: key);
          expect(sorting.descending, isTrue, reason: key);
          expect(sorting.showSubtitles, isFalse, reason: key);
          expect(sorting.apply(entries).map((entry) => entry.path), [
            '10',
            '2',
          ]);
        }
        expect(model.directorySorting(imports).showSubtitles, isTrue);
        expect(model.directorySorting(imports).descending, isTrue);
        expect(store.pending, isEmpty);
      } finally {
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'library series retain episode order by default and share applied name sorting',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-series-sort-');
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      for (final series in ['A', 'B']) {
        for (final episode in [(1, 'B'), (2, 'A'), (10, 'C')]) {
          store.save('media', '$series-${episode.$1}', {
            'title': '${episode.$2}.mkv',
            'series': '作品 $series',
            'season': '1',
            'episode': '${episode.$1}',
            'size': episode.$1 * 100,
          });
        }
      }
      final details = find.byKey(const ValueKey('series-details-list'));
      List<String> episodeOrder() => find
          .descendant(
            of: details,
            matching: find.byType(MediaDetailsEpisodeTile),
          )
          .evaluate()
          .map((element) => element.widget.key)
          .whereType<ValueKey<String>>()
          .map((key) => key.value)
          .where((value) => value.startsWith('series-episode:'))
          .map((value) => value.substring('series-episode:'.length))
          .toList();
      Future<void> openSeries(String series) async {
        final open = find.byKey(ValueKey('details:$series-1'));
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        await openSeries('A');
        expect(episodeOrder(), ['A-1', 'A-2', 'A-10']);
        final sortButton = find.byTooltip('排序与显示');
        await tester.ensureVisible(sortButton);
        await tester.tap(sortButton);
        await tester.pumpAndSettle();
        final selector = find.byWidgetPredicate(
          (widget) => widget is GlassSelect<String> && widget.label == '排序',
        );
        expect(tester.widget<GlassSelect<String>>(selector).value, 'name');
        expect(find.text('显示字幕文件'), findsNothing);
        expect(
          tester
              .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '降序'))
              .value,
          isFalse,
        );
        await tester.tap(find.text('降序'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用到所有文件夹'));
        await tester.pumpAndSettle();
        expect(episodeOrder(), ['A-10', 'A-1', 'A-2']);
        Navigator.of(tester.element(details)).pop();
        await tester.pumpAndSettle();
        await openSeries('B');
        expect(episodeOrder(), ['B-10', 'B-1', 'B-2']);
        await tester.ensureVisible(sortButton);
        await tester.tap(sortButton);
        await tester.pumpAndSettle();
        expect(tester.widget<GlassSelect<String>>(selector).value, 'name');
        expect(
          tester
              .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '降序'))
              .value,
          isTrue,
        );
        expect(find.text('应用到所有文件夹'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
