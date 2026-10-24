import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeferredDetailsModel extends AppModel {
  int loads = 0, libraryReads = 0, episodeLabels = 0, snapshotReads = 0;
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
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    snapshotReads++;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
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
    'details refresh existing data silently, build visible episodes and coalesce hidden-library changes',
    (tester) async {
      for (var i = 1; i <= 200; i++) {
        episode(i);
      }
      await library(tester);
      model.libraryReads = model.snapshotReads = 0;
      model.episodeLabels = 0;
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      expect(model.loads, 0);
      await tester.pump();
      expect(find.byKey(const ValueKey('series-details-list')), findsOneWidget);
      expect(find.byType(MediaDetailsOverview), findsOneWidget);
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
      final headerLoading = find.descendant(
        of: find.byType(MediaDetailsOverview),
        matching: find.byType(LinearProgressIndicator),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        headerLoading,
        findsNothing,
        reason: 'existing details stay usable while their source is pending',
      );
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
      expect(model.libraryReads, 0);
      expect(
        model.snapshotReads,
        3,
        reason:
            'details checks the card snapshot once before source loading, '
            'then obtains updated aggregates after the mocked loader; '
            'the uncovered library then reuses that snapshot',
      );

      model._loaded = null;
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(model.loads, 2);
      expect(headerLoading, findsNothing);
      expect(find.textContaining('已收录 201 集'), findsOneWidget);
      model.loaded.completeError(StateError('source offline'));
      await tester.pumpAndSettle();
      expect(headerLoading, findsNothing);
      expect(find.textContaining('已收录 201 集'), findsOneWidget);
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

  testWidgets(
    'open details refresh new episodes and metadata once after background updates',
    (tester) async {
      episode(1);
      episode(2);
      await library(tester);
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      model.libraryReads = model.snapshotReads = 0;

      final first = store.get('media', 'episode-1')!;
      store.save('media', first.id, {
        ...first.data,
        'summary': '后台补齐的作品简介',
        'totalEpisodes': 12,
      });
      episode(3);
      store.setLocal('episodeTitle:episode-2', '新的相遇');
      for (var index = 0; index < 20; index++) {
        model.changed();
      }
      await tester.pumpAndSettle();

      expect(find.textContaining('已收录 3 集'), findsOneWidget);
      expect(find.text('后台补齐的作品简介'), findsOneWidget);
      expect(find.text('共 12 集'), findsOneWidget);
      expect(find.textContaining('新的相遇'), findsOneWidget);
      expect(model.snapshotReads, 1);
      expect(model.libraryReads, 0);
      expect(
        model.loads,
        1,
        reason: 'metadata refresh must not relist sources',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'episode name updates refresh details without reading another library snapshot',
    (tester) async {
      episode(1);
      episode(2);
      await library(tester);
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      model.libraryReads = model.snapshotReads = 0;

      store.setLocal('episodeTitle:episode-2', '随后到达的集名');
      model.changed();
      await tester.pumpAndSettle();
      expect(find.textContaining('随后到达的集名'), findsOneWidget);
      expect(model.snapshotReads, 0);
      final labels = model.episodeLabels;
      for (var index = 0; index < 20; index++) {
        model.changed();
      }
      await tester.pumpAndSettle();
      expect(model.episodeLabels, labels);
      expect(model.snapshotReads, 0);
      expect(model.libraryReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'covered details defer metadata work and refresh once when visible again',
    (tester) async {
      episode(1);
      episode(2);
      await library(tester);
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.byType(BottomSheet)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('覆盖页'))),
        ),
      );
      await tester.pumpAndSettle();
      model.libraryReads = model.snapshotReads = 0;
      for (var number = 3; number <= 6; number++) {
        episode(number);
        model.changed();
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(model.snapshotReads, 0);
      expect(model.libraryReads, 0);

      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.textContaining('已收录 6 集'), findsOneWidget);
      expect(model.snapshotReads, 1);
      expect(model.libraryReads, 0);
      expect(
        model.loads,
        2,
        reason: 'returning to details checks its source once for new files',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'covered details cancel pending source work and reload once on return',
    (tester) async {
      episode(1);
      await library(tester);
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final firstRequest = model.detailsCancel!;
      expect(firstRequest.cancelled, isFalse);
      final navigator = Navigator.of(tester.element(find.byType(BottomSheet)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('覆盖页'))),
        ),
      );
      // Settle the route transition while source cancellation is pending.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(firstRequest.cancelled, isTrue);
      model.loaded.completeError(const Cancelled());
      await tester.pumpAndSettle();
      model._loaded = null;
      await tester.pump(const Duration(minutes: 1));
      expect(model.loads, 1, reason: 'covered details must not poll sources');

      navigator.pop();
      await tester.pumpAndSettle();
      expect(model.loads, 2);
      expect(model.detailsCancel, isNot(same(firstRequest)));
      expect(model.detailsCancel!.cancelled, isFalse);
      episode(2);
      model.loaded.complete(store.all('media'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已收录 2 集'), findsOneWidget);
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
    'title completeness refreshes local episode names with reused records',
    (tester) async {
      episode(1);
      final records = store.all('media');
      final key = mediaSeriesKey(records.first);
      store.setLocal('episodeTitle:episode-1', 'Opening');
      store.setLocal(
        'media-title-display:${sha256.convert(utf8.encode(jsonEncode([key, model.titleTranslations.profile])))}',
        {
          'visible': true,
          'titles': {'长篇作品': 'Translated show', 'Opening': '开场'},
        },
      );
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaTitleTranslation(
              model: model,
              title: '长篇作品',
              records: records,
            ),
          ),
        ),
      );
      await mount();
      expect(find.text('标题原文'), findsOneWidget);
      expect(find.text('翻译新增标题'), findsNothing);

      store.setLocal('episodeTitle:episode-1', 'A newly fetched episode name');
      model.changed();
      // Source headers rebuild while retaining their unchanged media snapshot.
      await mount();
      expect(find.text('翻译新增标题'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
