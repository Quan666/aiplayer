import 'dart:convert';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/media_title_translation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements SubtitleAiTransport {
  final String Function(Map<String, dynamic>, CancelToken) reply;
  final List<Map<String, dynamic>> requests = [];
  _Transport(this.reply);
  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) async {
    final request =
        jsonDecode((body['messages'] as List).last['content'])
            as Map<String, dynamic>;
    requests.add(request);
    return reply(request, cancel);
  }

  @override
  Future<List<String>> models(
    SubtitleAiConfig config,
    CancelToken cancel,
  ) async => [];
}

class _UiTranslations extends MediaTitleTranslations {
  _UiTranslations(super.store, {required super.settings});
  @override
  Future<void> translate({
    required String seriesKey,
    required String seriesTitle,
    required Iterable<String> titles,
    required SubtitleAiConfig config,
    required CancelToken cancel,
    SubtitleAiTransport? transport,
  }) => super.translate(
    seriesKey: seriesKey,
    seriesTitle: seriesTitle,
    titles: titles,
    config: config,
    cancel: cancel,
    transport: _Transport(
      (request, _) => jsonEncode([
        for (final row in request['titles'])
          {'id': row['id'], 'text': '译文 ${row['text']}'},
      ]),
    ),
  );
}

class _UiModel extends AppModel {
  _UiModel(super.store, super.documents);
  late final MediaTitleTranslations _translations = _UiTranslations(
    store,
    settings: () => settings,
  );
  @override
  MediaTitleTranslations get titleTranslations => _translations;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late MediaTitleTranslations translations;
  late Map<String, dynamic> settings;
  final config = SubtitleAiConfig(model: 'model');
  const key = 'bangumi:7:1';
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = AppStore(':memory:');
    settings = {'metadataStrategy': 'off', 'aiSubtitleModel': 'model'};
    translations = MediaTitleTranslations(store, settings: () => settings);
  });
  tearDown(() => store.dispose());

  Future<void> translate(
    List<String> titles,
    _Transport transport, {
    CancelToken? cancel,
  }) => translations.translate(
    seriesKey: key,
    seriesTitle: 'Example',
    titles: titles,
    config: config,
    cancel: cancel ?? CancelToken(),
    transport: transport,
  );
  _Transport validTransport() => _Transport(
    (request, _) => jsonEncode([
      for (final row in request['titles'])
        {'id': row['id'], 'text': '译文 ${row['text']}'},
    ]),
  );

  test(
    'translates named episodes in batches and reuses per-title cache for added episodes',
    () async {
      final transport = validTransport();
      final titles = ['Example', for (var i = 1; i <= 31; i++) 'Episode $i'];
      await translate(titles, transport);
      expect(transport.requests.length, 2);
      expect(transport.requests.first['seriesTitle'], 'Example');
      expect(translations.display(key, 'Episode 31'), '译文 Episode 31');
      expect(translations.display(key, 'Untranslated'), 'Untranslated');
      expect(translations.isComplete(key, titles), isTrue);
      translations.setVisible(key, false);
      expect(translations.display(key, 'Example'), 'Example');
      final reopened = MediaTitleTranslations(store, settings: () => settings);
      expect(reopened.isVisible(key), isFalse);
      reopened.setVisible(key, true);
      expect(reopened.display(key, 'Example'), '译文 Example');
      await translate([...titles, 'Episode 32'], transport);
      expect(transport.requests.length, 3);
      expect(transport.requests.last['titles'], [
        {'id': 0, 'text': 'Episode 32'},
      ]);
      settings = {...settings, 'aiSubtitleTarget': '日本語'};
      expect(translations.display(key, 'Example'), 'Example');
      settings = {...settings, 'aiSubtitleTarget': '简体中文'};
      expect(translations.display(key, 'Example'), '译文 Example');
    },
  );

  test(
    'invalid batches and cancelled responses never update title display or cache',
    () async {
      final malformed = _Transport(
        (_, _) => '[{"id":0,"text":"甲"},{"id":0,"text":"乙"}]',
      );
      await expectLater(
        translate(['Example', 'One'], malformed),
        throwsA(isA<AppFailure>()),
      );
      expect(translations.hasTranslations(key), isFalse);
      expect(store.localEntries('media-title-translation:'), isEmpty);
      final token = CancelToken();
      final cancelled = _Transport((_, cancel) {
        cancel.cancel();
        return '[{"id":0,"text":"作品"}]';
      });
      await expectLater(
        translate(['Example'], cancelled, cancel: token),
        throwsA(isA<Cancelled>()),
      );
      expect(store.localEntries('media-title-translation:'), isEmpty);
      expect(translations.display(key, 'Example'), 'Example');
    },
  );

  test(
    'validated earlier batches survive retry after a later batch fails',
    () async {
      var calls = 0;
      final interrupted = _Transport((request, _) {
        if (++calls == 2) throw const AppFailure('offline');
        return jsonEncode([
          for (final row in request['titles'])
            {'id': row['id'], 'text': '译文 ${row['text']}'},
        ]);
      });
      final titles = [for (var i = 0; i < 31; i++) 'Title $i'];
      await expectLater(
        translate(titles, interrupted),
        throwsA(isA<AppFailure>()),
      );
      expect(translations.hasTranslations(key), isFalse);
      final retry = validTransport();
      await translate(titles, retry);
      expect(retry.requests.single['titles'], [
        {'id': 0, 'text': 'Title 30'},
      ]);
    },
  );

  testWidgets(
    'shared details translate title and episode labels without changing metadata',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('aiplayer-title-');
      store.setLocal('settings', settings);
      store.save('media', 'one', {
        'title': 'file.mkv',
        'metadataTitle': 'Example',
        'series': 'Example',
        'season': '1',
        'episode': '1',
        'bangumiId': '7',
      });
      store.setLocal('episodeTitle:one', 'Encounter');
      final model = AppModel(store, root);
      final record = store.get('media', 'one')!;
      final original = Map<String, dynamic>.from(record.data);
      await translate(['Example', 'Encounter'], validTransport());
      translations.setVisible(key, false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaDetailsHeader(
              model: model,
              details: MediaCollectionDetails.fromRecords([record]),
              records: [record],
            ),
          ),
        ),
      );
      expect(find.text('Example'), findsOneWidget);
      await tester.tap(find.text('标题译文'));
      await tester.pumpAndSettle();
      expect(find.text('译文 Example'), findsOneWidget);
      expect(model.displayTitle(record), '译文 Example · 第 1 集 · 译文 Encounter');
      expect(store.get('media', 'one')!.data, original);
      expect(store.local('episodeTitle:one'), 'Encounter');
      await tester.tap(find.text('标题原文'));
      await tester.pumpAndSettle();
      expect(model.displayTitle(record), 'Example · 第 1 集 · Encounter');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'library rows and poster update when cached title display toggles',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-title-library-',
      );
      store.setLocal('settings', settings);
      store.save('media', 'one', {
        'title': 'file.mkv',
        'metadataTitle': 'Example',
        'series': 'Example',
        'season': '1',
        'episode': '1',
        'bangumiId': '7',
      });
      store.setLocal('episodeTitle:one', 'Encounter');
      final model = AppModel(store, root);
      await model.titleTranslations.translate(
        seriesKey: key,
        seriesTitle: 'Example',
        titles: ['Example', 'Encounter'],
        config: config,
        cancel: CancelToken(),
        transport: validTransport(),
      );
      model.titleTranslations.setVisible(key, false);
      await tester.pumpWidget(MaterialApp(home: LibraryPage(model: model)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('details:one')));
      await tester.pumpAndSettle();
      expect(find.text('第 1 集 · Encounter'), findsOneWidget);
      await tester.tap(find.text('标题译文'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 集 · 译文 Encounter'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.text('译文 Example · 第 1 集 · 译文 Encounter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'unmatched single video translates directly without a confirmation dialog',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-title-unmatched-',
      );
      store.setLocal('settings', settings);
      store.save('media', 'solo', {'title': 'Untitled movie.mkv'});
      final model = _UiModel(store, root);
      await tester.pumpWidget(MaterialApp(home: LibraryPage(model: model)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('details:solo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI 翻译标题'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        model.seriesTitle(store.get('media', 'solo')!),
        '译文 Untitled movie.mkv',
      );
      expect(store.localEntries('media-title-translation:'), isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'title translation sits right of summary translation and wraps on narrow screens',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-title-layout-',
      );
      store.setLocal('settings', settings);
      final model = AppModel(store, root);
      Widget view(double width) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MediaDetailsHeader(
                model: model,
                details: const MediaCollectionDetails(
                  title: 'Example',
                  summary: 'Original synopsis.',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view(700));
      await tester.pumpAndSettle();
      final summary = tester.getCenter(find.text('AI 翻译简介'));
      final title = tester.getCenter(find.text('AI 翻译标题'));
      expect(title.dx, greaterThan(summary.dx));
      expect(title.dy, closeTo(summary.dy, 1));
      expect(
        title.dy,
        greaterThan(tester.getBottomLeft(find.text('Original synopsis.')).dy),
      );
      await tester.pumpWidget(view(260));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('AI 翻译标题')).right,
        lessThanOrEqualTo(260),
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      root.deleteSync(recursive: true);
    },
  );
}
