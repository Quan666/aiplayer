import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/metadata_match_dialog.dart';
import 'package:aiplayer/ui/metadata_tasks_sheet.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _subject = <String, dynamic>{
  'id': 42,
  'provider': 'bangumi',
  'name': 'Example',
  'name_cn': '正式作品',
  'summary': '作品简介',
};

class _Catalog extends LibraryCatalog {
  final resolveGate = Completer<Map<String, dynamic>?>();
  final detailsGate = Completer<Map<String, dynamic>>();
  _Catalog(super.store);

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    final value = await resolveGate.future;
    cancel?.check();
    return value;
  }

  @override
  Future<List<Map<String, dynamic>>> search(
    String title, {
    String? source,
    CancelToken? cancel,
  }) async => [_subject];

  @override
  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    final value = await detailsGate.future;
    cancel?.check();
    return value;
  }
}

class _Model extends AppModel {
  late final _fakeCatalog = _Catalog(store);
  _Model(super.store, super.documents);
  bool forbidMediaReads = false;
  @override
  List<SyncRecord> get media {
    if (forbidMediaReads) throw StateError('UI scanned the media library');
    return super.media;
  }

  @override
  LibraryCatalog get catalog => _fakeCatalog;
  @override
  Future<void> fillEpisodeNames(
    String series,
    Map<String, dynamic> subject, {
    String? season,
    CancelToken? cancel,
    Set<String>? mediaIds,
  }) async {
    cancel?.check();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _Model model;
  late SyncRecord media;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('metadata-sheet-');
    store = AppStore(':memory:')
      ..setLocal('settings', {
        'metadataStrategy': 'off',
        'aiMetadataEnabled': false,
      });
    store.save('media', 'one', {
      'title': 'Example S01E01.mkv',
      'fileName': 'Example S01E01.mkv',
      'series': 'Example',
      'season': '1',
      'episode': '1',
    });
    media = store.get('media', 'one')!;
    model = _Model(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  Widget app({Set<String> ids = const {'one'}}) => MaterialApp(
    theme: GlassPalette.theme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            TextButton(
              onPressed: () => showMetadataMatchDialog(
                context,
                model,
                'Example',
                season: '1',
                mediaIds: ids,
              ),
              child: const Text('打开匹配'),
            ),
            TextButton(
              onPressed: () => showMetadataTasks(context, model),
              child: const Text('打开任务'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('打开匹配'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('metadata-match-sheet')), findsOneWidget);
  }

  testWidgets(
    'phone sheet stays above the keyboard with reachable close and scrollable results',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(app());
      await open(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('metadata-match-sheet')))
            .height,
        lessThan(450),
        reason:
            'The initial form should fit its contents instead of opening an empty tall panel.',
      );
      await tester.tap(find.byType(TextField).first);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final sheet = tester.getRect(
        find.byKey(const ValueKey('metadata-match-sheet')),
      );
      expect(sheet.bottom, lessThanOrEqualTo(544.1));
      expect(tester.getCenter(find.text('关闭')).dy, lessThan(544));
      expect(find.text('作品名称'), findsOneWidget);
      expect(find.text('季度'), findsOneWidget);
      expect(find.textContaining('同时搜索'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'closing the sheet preserves recognition and reopening shows its completed result',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final task = model.startMetadataTask([media]);
      await tester.pump();
      await open(tester);
      expect(find.text('后台识别'), findsOneWidget);
      await tester.tap(find.text('后台识别'));
      await tester.pumpAndSettle();
      expect(task.running, isTrue);
      expect(task.cancelled, isFalse);
      expect(find.byKey(const ValueKey('metadata-match-sheet')), findsNothing);
      model._fakeCatalog.resolveGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(task.running, isFalse);
      expect(task.matched, 1);
      expect(store.get('media', 'one')!.data['bangumiId'], '42');
      await open(tester);
      expect(find.text('已匹配 1 个视频'), findsOneWidget);
      expect(find.text('已处理 1/1 · 已匹配 1 · 失败 0'), findsOneWidget);
      expect(find.text('后台识别'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual candidate application continues after closing and does not auto-dismiss on start',
    (tester) async {
      await tester.pumpWidget(app());
      await open(tester);
      await tester.tap(find.byTooltip('搜索资料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('正式作品'));
      await tester.pumpAndSettle();
      final task = model.metadataTasks.single;
      expect(task.running, isTrue);
      expect(
        find.byKey(const ValueKey('metadata-match-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(task.cancelled, isFalse);
      model._fakeCatalog.detailsGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(task.matched, 1);
      expect(store.get('media', 'one')!.data['bangumiId'], '42');
      await open(tester);
      expect(find.text('已匹配 1 个视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source reidentification starts in the background and leaves browsing usable',
    (tester) async {
      store.setLocal('location:one', {
        'id': 'one',
        'source': 'local',
        'path': '/Example.mkv',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: SourcesPage(
              model: model,
              onImport: () async {},
              onPlay: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地视频'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text(model.displayTitle(media)));
      await tester.pumpAndSettle();
      expect(find.text('AI 自动识别'), findsNothing);
      await tester.tap(find.text('重新识别影视资料'));
      await tester.pumpAndSettle();
      final task = model.metadataTasks.single;
      expect(task.running, isTrue);
      expect(find.text('已开始后台识别'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('metadata-match-sheet')), findsNothing);
      await tester.longPress(find.text(model.displayTitle(media)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动搜索影视资料'));
      await tester.pumpAndSettle();
      expect(find.text('后台识别'), findsOneWidget);
      expect(find.text('已处理 0/1 · 已匹配 0 · 失败 0'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(task.cancelled, isFalse);
      model._fakeCatalog.resolveGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(task.matched, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('batch candidates stay scoped to the selected video', (
    tester,
  ) async {
    store.save('media', 'two', {
      ...media.data,
      'fileName': 'Example S01E02.mkv',
      'episode': '2',
    });
    final second = store.get('media', 'two')!;
    await tester.pumpWidget(app(ids: {'one', 'two'}));
    await tester.pump();
    final batch = model.startMetadataTask([media, second]);
    await tester.pump();
    for (final record in [media, second]) {
      final next = record.id == 'two';
      batch.results[record.id] = AiMetadataMatch(
        AiMediaIdentity(
          fileName: '${record.data['fileName']}',
          name: next ? '作品二' : '作品一',
          kind: 'tv',
          season: '1',
          episode: next ? '2' : '1',
          confidence: .9,
        ),
        [
          {..._subject, 'id': next ? 66 : 42, 'name_cn': next ? '作品二' : '作品一'},
        ],
        null,
      );
    }
    model.cancelMetadataTask(batch);
    model._fakeCatalog.resolveGate.complete(null);
    await tester.pumpAndSettle();
    await open(tester);
    final choice = find.byKey(const ValueKey('metadata-record-choice'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example S01E02.mkv').last);
    await tester.pumpAndSettle();
    expect(find.text('识别：作品二 · 第 2 集'), findsOneWidget);
    final candidate = find.widgetWithText(ListTile, '作品二');
    await tester.ensureVisible(candidate);
    await tester.tap(candidate);
    await tester.pumpAndSettle();
    expect(model.metadataTasks.single, same(batch));
    final selection = batch.selectionTask!;
    expect(selection.mediaIds, {'two'});
    expect(batch.mediaIds, {'one', 'two'});
    expect(selection.running, isTrue);
    expect(find.byKey(const ValueKey('metadata-match-sheet')), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.text('2/2  Example S01E02.mkv'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isFalse,
    );
    model._fakeCatalog.detailsGate.complete(_subject);
    await tester.pumpAndSettle();
    expect(store.get('media', 'one')!.data['bangumiId'], isNull);
    expect(store.get('media', 'two')!.data['bangumiId'], '42');
    expect(find.text('1/2  Example S01E01.mkv'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unmatched files can be searched individually, advanced, revisited and removed',
    (tester) async {
      for (final (id, episode) in [('two', '2'), ('three', '3')]) {
        store.save('media', id, {
          ...media.data,
          'fileName': 'Example S01E0$episode.mkv',
          'episode': episode,
        });
      }
      final records = [
        media,
        store.get('media', 'two')!,
        store.get('media', 'three')!,
      ];
      await tester.pumpWidget(app(ids: {'one', 'two', 'three'}));
      final task = model.startMetadataTask(records);
      await tester.pump();
      model._fakeCatalog.resolveGate.completeError(
        const NetworkUnavailable('上一轮自动识别超时'),
      );
      await tester.pumpAndSettle();
      expect(task.running, isFalse);
      expect(task.results, isEmpty);
      expect(task.error, '上一轮自动识别超时');
      model.forbidMediaReads = true;
      await open(tester);
      expect(find.text('1/3  Example S01E01.mkv'), findsOneWidget);
      await tester.tap(find.byTooltip('搜索资料'));
      await tester.pumpAndSettle();
      expect(find.text('上一轮自动识别超时'), findsNothing);
      final candidate = find.widgetWithText(ListTile, '正式作品');
      await tester.ensureVisible(candidate);
      await tester.tap(candidate);
      await tester.pumpAndSettle();
      final selection = task.selectionTask!;
      expect(selection.mediaIds, {'one'});
      expect(model.metadataTasks.single, same(task));
      model._fakeCatalog.detailsGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(task.matched, 1);
      expect(task.error, isEmpty);
      expect(find.text('上一轮自动识别超时'), findsNothing);
      expect(task.isMatched('one'), isTrue);
      expect(store.get('media', 'one')!.data['bangumiId'], '42');
      expect(store.get('media', 'two')!.data['bangumiId'], isNull);
      expect(find.text('2/3  Example S01E02.mkv'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('上一个'));
      await tester.tap(find.byTooltip('上一个'));
      await tester.pumpAndSettle();
      expect(find.text('1/3  Example S01E01.mkv'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '正式作品'), findsOneWidget);
      await tester.tap(find.byTooltip('删除识别记录'));
      await tester.pumpAndSettle();
      expect(task.mediaIds, {'two', 'three'});
      expect(find.text('1/2  Example S01E02.mkv'), findsOneWidget);
      expect(store.get('media', 'one')!.deleted, isFalse);
      expect(store.get('media', 'one')!.data['bangumiId'], '42');
      await tester.tap(find.byTooltip('下一个'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '保留搜索名称');
      await tester.tap(find.byTooltip('上一个'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一个'));
      await tester.pumpAndSettle();
      expect(find.text('保留搜索名称'), findsOneWidget);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      expect(model.metadataTasks, isEmpty);
      expect(find.byKey(const ValueKey('metadata-match-sheet')), findsNothing);
      expect(store.get('media', 'two')!.deleted, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'task list deletes running recognition without late application',
    (tester) async {
      await tester.pumpWidget(app());
      final task = model.startMetadataTask([media]);
      await tester.pump();
      await tester.tap(find.text('打开任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('删除识别任务'));
      await tester.pumpAndSettle();
      expect(task.cancelled, isTrue);
      expect(task.removed, isTrue);
      expect(model.metadataTasks, isEmpty);
      model._fakeCatalog.resolveGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(store.get('media', 'one')!.data['bangumiId'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'only the explicit cancel action cancels a running recognition task',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final task = model.startMetadataTask([media]);
      await tester.pump();
      await open(tester);
      await tester.tap(find.text('取消任务'));
      await tester.pumpAndSettle();
      expect(task.cancelled, isTrue);
      expect(find.text('已取消'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('metadata-match-sheet')),
        findsOneWidget,
      );
      model._fakeCatalog.resolveGate.complete(_subject);
      await tester.pumpAndSettle();
      expect(store.get('media', 'one')!.data['bangumiId'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
