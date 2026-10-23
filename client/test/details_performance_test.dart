import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeferredDetailsModel extends AppModel {
  int loads = 0, libraryReads = 0, episodeLabels = 0;
  CancelToken? detailsCancel;
  Completer<List<SyncRecord>>? _loaded;
  Completer<List<SyncRecord>> get loaded =>
      _loaded ??= Completer<List<SyncRecord>>();
  _DeferredDetailsModel(super.store, super.documents);
  @override
  List<SyncRecord> get media {
    libraryReads++;
    return super.media;
  }

  @override
  String episodeLabel(SyncRecord record) {
    episodeLabels++;
    return super.episodeLabel(record);
  }

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) {
    loads++;
    detailsCancel = cancel;
    return loaded.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _DeferredDetailsModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync(
      'aiplayer-details-performance-',
    );
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _DeferredDetailsModel(store, directory);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  void episode(int number) => store.save('media', 'episode-$number', {
    'series': '长篇作品',
    'title': '原始文件$number.mkv',
    'season': '1',
    'episode': '$number',
    'bangumiId': '123',
    'metadataTitle': '长篇作品',
  });
  Future<void> library(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'details show existing data first, build visible episodes and coalesce hidden-library changes',
    (tester) async {
      for (var i = 1; i <= 200; i++) {
        episode(i);
      }
      await library(tester);
      model.libraryReads = 0;
      model.episodeLabels = 0;
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      expect(model.loads, 0);
      await tester.pump();
      expect(find.byKey(const ValueKey('series-details-list')), findsOneWidget);
      expect(find.textContaining('已收录 200 集'), findsOneWidget);
      expect(model.loads, 0);
      expect(
        model.episodeLabels,
        lessThan(30),
        reason: 'offscreen episodes must not query or build during entrance',
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        model.loads,
        0,
        reason: 'directory loading must wait for the entrance animation',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(model.loads, 1);
      for (var i = 0; i < 20; i++) {
        model.changed();
      }
      await tester.pump();
      expect(
        model.libraryReads,
        0,
        reason: 'notifications must not rebuild the obscured library',
      );

      episode(201);
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已收录 201 集'), findsOneWidget);
      expect(model.libraryReads, 0);
      final rows = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'series-episode:',
            ),
      );
      expect(rows.evaluate().length, lessThan(30));
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        model.libraryReads,
        0,
        reason: 'closing animation must also avoid a full-library rebuild',
      );
      await tester.pumpAndSettle();
      expect(model.libraryReads, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unchanged source completion does not rebuild visible episode rows',
    (tester) async {
      episode(1);
      episode(2);
      await library(tester);
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final rendered = model.episodeLabels;
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      expect(model.episodeLabels, rendered);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing details cancels pending source completion', (
    tester,
  ) async {
    episode(1);
    await library(tester);
    await tester.tap(find.byKey(const ValueKey('details:episode-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.loads, 1);
    expect(model.detailsCancel!.cancelled, false);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();
    expect(model.detailsCancel!.cancelled, true);
    model.loaded.completeError(const Cancelled());
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'collapsed long synopses shape a bounded preview and expand to full text',
    (tester) async {
      final summary = '😀长篇简介。' * 2000;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaSummary(model: model, summary: summary),
            ),
          ),
        ),
      );
      final original = find
          .descendant(
            of: find.byType(MediaSummary),
            matching: find.byType(Text),
          )
          .first;
      expect(
        tester.widget<Text>(original).data!.runes.length,
        lessThanOrEqualTo(601),
      );
      await tester.tap(find.text('展开简介'));
      await tester.pump();
      expect(tester.widget<Text>(original).data, summary);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
