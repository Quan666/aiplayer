import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/offline_download_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Downloads extends OfflineDownloads {
  final values = <String, OfflineDownload>{};
  final retries = <String>[];
  final cancellations = <String>[];
  final pauses = <String>[], resumes = <String>[];
  int reads = 0;

  _Downloads(Directory directory)
    : super(
        directory: directory,
        storePath: ':memory:',
        sourceConfiguration: (_) async => null,
      );

  @override
  OfflineDownload? entryFor(String mediaId) {
    reads++;
    return values[mediaId];
  }

  void update(
    String id,
    OfflineDownloadStatus status, {
    int received = 0,
    String? remotePath,
    String bindingRevision = '',
    bool userPaused = false,
  }) {
    final wasComplete = values[id]?.isComplete ?? false;
    values[id] = OfflineDownload(
      mediaId: id,
      sourceId: 'nas',
      remotePath: remotePath ?? '/share/$id.mkv',
      localPath: '/offline/nas/share/$id.mkv',
      name: '$id.mkv',
      status: status,
      received: received,
      total: 100,
      bindingRevision: bindingRevision,
      userPaused: userPaused,
    );
    if (wasComplete != values[id]!.isComplete) completedRevision++;
    notifyListeners();
  }

  void remove(String id) {
    if (values.remove(id)?.isComplete == true) completedRevision++;
    notifyListeners();
  }

  @override
  Future<void> retry(String mediaId) async => retries.add(mediaId);

  @override
  Future<void> cancel(String mediaId) async => cancellations.add(mediaId);

  @override
  Future<void> pause(String mediaId) async {
    pauses.add(mediaId);
    update(mediaId, OfflineDownloadStatus.paused, userPaused: true);
  }

  @override
  Future<void> resume(String mediaId) async {
    resumes.add(mediaId);
    update(mediaId, OfflineDownloadStatus.queued);
  }
}

class _Model extends AppModel {
  final _Downloads fakeDownloads;
  final requested = <List<String>>[];
  final sourceRequested = <(String, List<String>)>[];
  final sourceBatches = <List<SourceEntry>>[];
  final removed = <String>[];

  _Model(super.store, super.documents, this.fakeDownloads)
    : super(backgroundWork: false);

  @override
  OfflineDownloads get downloads => fakeDownloads;

  @override
  bool canDownload(SyncRecord media) => true;

  @override
  Future<void> downloadMedia(Iterable<SyncRecord> records) async {
    requested.add(records.map((item) => item.id).toList());
  }

  @override
  Future<void> downloadSourceEntries(
    String sourceId,
    Iterable<SourceEntry> entries,
  ) async {
    final batch = entries.toList();
    sourceBatches.add(batch);
    sourceRequested.add((sourceId, batch.map((item) => item.path).toList()));
  }

  @override
  Future<void> deleteDownload(String id) async {
    removed.add(id);
    fakeDownloads.remove(id);
  }
}

SyncRecord _record(String id) => SyncRecord(
  id: id,
  kind: 'media',
  data: {'title': '$id.mkv', 'fileName': '$id.mkv'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _Downloads downloads;
  late _Model model;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('offline-controls-');
    store = AppStore(':memory:');
    downloads = _Downloads(directory);
    model = _Model(store, directory, downloads);
  });

  tearDown(() {
    model.dispose();
    downloads.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Widget shell(Widget child) => MaterialApp(
    theme: GlassPalette.theme(),
    home: Scaffold(body: child),
  );

  void bind(SyncRecord record, {String source = 'nas', String? path}) {
    store.save('media', record.id, record.data);
    store.setLocal('location:${record.id}', {
      'id': record.id,
      'source': source,
      'path': path ?? '/share/${record.id}.mkv',
    });
  }

  testWidgets('one download and completed-file removal use separate actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(OfflineDownloadButton(model: model, item: _record('one'))),
    );
    await tester.tap(find.byTooltip('下载视频'));
    await tester.pumpAndSettle();
    expect(model.requested, [
      ['one'],
    ]);

    downloads.update('one', OfflineDownloadStatus.completed, received: 100);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('已下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除离线视频'));
    await tester.pumpAndSettle();
    expect(model.removed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.removed, isEmpty);
    await tester.tap(find.byTooltip('已下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除离线视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(model.removed, ['one']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'source rows download without importing synchronously in the UI',
    (tester) async {
      await tester.pumpWidget(
        shell(
          OfflineDownloadButton(
            model: model,
            item: _record('preview-id'),
            sourceId: 'nas',
            sourceEntry: const SourceEntry(
              name: 'one.mkv',
              path: '/share/one.mkv',
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('下载视频'));
      await tester.pumpAndSettle();
      expect(model.sourceRequested, hasLength(1));
      expect(model.sourceRequested.single.$1, 'nas');
      expect(model.sourceRequested.single.$2, ['/share/one.mkv']);
      expect(store.all('media'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('multi-select builds lazily and submits only checked videos', (
    tester,
  ) async {
    final records = List.generate(300, (index) => _record('episode-$index'));
    for (final record in records) {
      bind(record);
    }
    await tester.pumpWidget(
      shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDownloadSelection(context, model, records),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
    await tester.tap(find.byKey(const ValueKey('download-select:0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('download-select:2')));
    await tester.pump();
    await tester.tap(find.text('下载 (2)'));
    await tester.pumpAndSettle();
    expect(model.requested, [
      ['episode-0', 'episode-2'],
    ]);
    expect(find.byKey(const ValueKey('download-selection-list')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('selection excludes completed, local and unavailable videos', (
    tester,
  ) async {
    final records = [
      'remote',
      'completed',
      'local',
      'missing',
      'stale',
    ].map(_record).toList();
    bind(records[0]);
    bind(records[1]);
    bind(records[2], source: 'local');
    bind(records[4], path: '/other/stale.mkv');
    downloads.update('stale', OfflineDownloadStatus.completed, received: 100);
    downloads.update(
      'completed',
      OfflineDownloadStatus.completed,
      received: 100,
    );
    await tester.pumpWidget(
      shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDownloadSelection(context, model, records),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final choices = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(choices.first.onChanged, isNotNull);
    expect(choices.skip(1).every((item) => item.onChanged == null), isTrue);
    expect(choices.map((item) => item.value), [
      false,
      true,
      false,
      false,
      false,
    ]);
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    expect(find.byTooltip('旧位置的下载'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('下载 (1)'));
    await tester.pumpAndSettle();
    expect(model.requested, [
      ['remote'],
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'completed selections stay checked through manual and bulk selection changes',
    (tester) async {
      final records = ['completed', 'one', 'two'].map(_record).toList();
      for (final record in records) {
        bind(record);
      }
      downloads.update(
        'completed',
        OfflineDownloadStatus.completed,
        received: 100,
      );
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDownloadSelection(context, model, records),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final completed = find.byKey(const ValueKey('download-select:0'));
      expect(tester.widget<CheckboxListTile>(completed).value, isTrue);
      expect(tester.widget<CheckboxListTile>(completed).onChanged, isNull);
      expect(find.text('下载 (0)'), findsOneWidget);
      await tester.tap(completed);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(completed).value, isTrue);
      expect(find.text('下载 (0)'), findsOneWidget);

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('下载 (2)'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pump();
      expect(find.text('下载 (0)'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(completed).value, isTrue);
      expect(tester.widget<CheckboxListTile>(completed).onChanged, isNull);

      await tester.tap(find.byKey(const ValueKey('download-select:2')));
      await tester.pump();
      await tester.tap(find.text('下载 (1)'));
      await tester.pumpAndSettle();
      expect(model.requested, [
        ['two'],
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completion while selecting removes that file from count and submission',
    (tester) async {
      final records = ['one', 'two'].map(_record).toList();
      for (final record in records) {
        bind(record);
      }
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDownloadSelection(context, model, records),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('下载 (2)'), findsOneWidget);

      downloads.update('one', OfflineDownloadStatus.completed, received: 100);
      await tester.pump();
      final completed = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('download-select:0')),
      );
      expect(completed.value, isTrue);
      expect(completed.onChanged, isNull);
      expect(find.text('下载 (1)'), findsOneWidget);
      await tester.tap(find.text('下载 (1)'));
      await tester.pumpAndSettle();
      expect(model.requested, [
        ['two'],
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final background in [true, false]) {
    testWidgets(
      'selection coalesces completed files while ${background ? 'paused without frames' : 'covered by another route'}',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        addTearDown(() {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        });
        final records = ['one', 'two', 'three'].map(_record).toList();
        for (final record in records) {
          bind(record);
        }
        await tester.pumpWidget(
          shell(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showDownloadSelection(context, model, records),
                child: const Text('打开'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选'));
        await tester.pump();
        expect(find.text('下载 (3)'), findsOneWidget);

        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          showDialog<void>(
            context: tester.element(
              find.byKey(const ValueKey('download-selection-list')),
            ),
            builder: (context) => AlertDialog(
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回选择'),
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
        }
        downloads.reads = 0;
        downloads.update('one', OfflineDownloadStatus.completed, received: 100);
        downloads.update('two', OfflineDownloadStatus.completed, received: 100);
        // In particular, Android may deliver no frame after paused.
        expect(downloads.reads, 0);

        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          expect(
            downloads.reads,
            3,
            reason: 'prune the retained selection once',
          );
        } else {
          await tester.tap(find.text('返回选择'));
        }
        await tester.pumpAndSettle();
        for (final index in [0, 1]) {
          final completed = tester.widget<CheckboxListTile>(
            find.byKey(ValueKey('download-select:$index')),
          );
          expect(completed.value, isTrue);
          expect(completed.onChanged, isNull);
        }
        expect(find.text('下载 (1)'), findsOneWidget);
        await tester.tap(find.text('下载 (1)'));
        await tester.pumpAndSettle();
        expect(model.requested, [
          ['three'],
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'source selection resolves saved IDs and accepts unimported paths',
    (tester) async {
      const entries = [
        SourceEntry(name: 'one.mkv', path: '/share/one.mkv'),
        SourceEntry(name: 'two.mkv', path: '/share/two.mkv'),
      ];
      bind(_record('saved-id'), path: entries.first.path);
      downloads.update(
        'saved-id',
        OfflineDownloadStatus.completed,
        received: 100,
        remotePath: entries.first.path,
      );
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showSourceDownloadSelection(context, model, 'nas', entries),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final choices = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(choices.first.onChanged, isNull);
      expect(choices.first.value, isTrue);
      expect(choices.last.onChanged, isNotNull);
      expect(choices.last.value, isFalse);
      await tester.tap(find.text('全选'));
      await tester.pump();
      await tester.tap(find.text('下载 (1)'));
      await tester.pumpAndSettle();
      expect(model.sourceRequested.single.$1, 'nas');
      expect(model.sourceRequested.single.$2, ['/share/two.mkv']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('source chooser retains directory flags in a mixed batch', (
    tester,
  ) async {
    const entries = [
      SourceEntry(name: 'Season', path: '/share/Season/', directory: true),
      SourceEntry(name: 'movie.mkv', path: '/share/movie.mkv'),
    ];
    await tester.pumpWidget(
      shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showSourceDownloadSelection(context, model, 'nas', entries),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('文件夹包含所有子目录中的视频。'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('下载 (2)'));
    await tester.pumpAndSettle();
    expect(model.sourceRequested.single.$2, [
      '/share/Season/',
      '/share/movie.mkv',
    ]);
    expect(model.sourceBatches.single.first.directory, isTrue);
    expect(model.sourceBatches.single.last.directory, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bulk selection and manual additions stay within 2000 items', (
    tester,
  ) async {
    final entries = List.generate(
      2001,
      (index) =>
          SourceEntry(name: 'file-$index.mkv', path: '/share/$index.mkv'),
    );
    await tester.pumpWidget(
      shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showSourceDownloadSelection(context, model, 'nas', entries),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
    await tester.tap(find.text('选择前2000项'));
    await tester.pump();
    expect(find.text('下载 (2000)'), findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('download-selection-list')),
        matching: find.byType(Scrollable),
      ),
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-select:2000')));
    await tester.pump();
    expect(find.text('单次最多选择 2000 项。'), findsOneWidget);
    expect(find.text('下载 (2000)'), findsOneWidget);
    await tester.tap(find.text('下载 (2000)'));
    await tester.pumpAndSettle();
    expect(model.sourceBatches.single.length, 2000);
    expect(model.sourceRequested.single.$2, isNot(contains('/share/2000.mkv')));
    await tester.pumpWidget(const SizedBox());
  });

  for (final changedField in ['source', 'path', 'previewRevision']) {
    testWidgets(
      'a changed $changedField requires explicit removal of the old download',
      (tester) async {
        final record = _record('one');
        bind(record);
        downloads.update('one', OfflineDownloadStatus.completed, received: 100);
        await tester.pumpWidget(
          shell(OfflineDownloadButton(model: model, item: record)),
        );
        expect(find.byTooltip('已下载'), findsOneWidget);
        store.setLocal('location:one', {
          ...store.local('location:one') as Map,
          changedField: switch (changedField) {
            'path' => '/other/one.mkv',
            'source' => 'other-nas',
            _ => 'new-server',
          },
        });
        model.changed();
        await tester.pumpAndSettle();
        expect(find.byTooltip('旧位置的下载'), findsOneWidget);
        expect(find.byIcon(Icons.download_done_rounded), findsNothing);
        expect(model.removed, isEmpty);
        await tester.tap(find.byTooltip('旧位置的下载'));
        await tester.pumpAndSettle();
        expect(find.text('重试下载'), findsNothing);
        await tester.tap(find.text('删除离线视频'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(model.removed, ['one']);
        expect(find.byTooltip('下载视频'), findsOneWidget);
        expect(model.requested, isEmpty);
        await tester.tap(find.byTooltip('下载视频'));
        await tester.pumpAndSettle();
        expect(model.requested, [
          ['one'],
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('paused updates coalesce without a frame and refresh on resume', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      shell(OfflineDownloadButton(model: model, item: _record('one'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    downloads.reads = 0;
    downloads.update('one', OfflineDownloadStatus.downloading, received: 10);
    downloads.update('one', OfflineDownloadStatus.downloading, received: 20);
    downloads.update('one', OfflineDownloadStatus.completed, received: 100);
    expect(
      downloads.reads,
      0,
      reason: 'background notifications do not wait for a new frame',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(downloads.reads, 1);
    await tester.pumpAndSettle();
    expect(find.byTooltip('已下载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('episode download menu pauses and continues the retained task', (
    tester,
  ) async {
    downloads.update('one', OfflineDownloadStatus.queued);
    await tester.pumpWidget(
      shell(OfflineDownloadButton(model: model, item: _record('one'))),
    );
    await tester.tap(find.byTooltip('等待下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停下载'));
    await tester.pumpAndSettle();
    expect(downloads.pauses, ['one']);
    await tester.tap(find.byTooltip('下载已暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续下载'));
    await tester.pumpAndSettle();
    expect(downloads.resumes, ['one']);
    expect(find.byTooltip('等待下载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed and queued downloads offer retry and cancel', (
    tester,
  ) async {
    downloads.update('one', OfflineDownloadStatus.failed);
    await tester.pumpWidget(
      shell(OfflineDownloadButton(model: model, item: _record('one'))),
    );
    await tester.tap(find.byTooltip('下载失败'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试下载'));
    await tester.pumpAndSettle();
    expect(downloads.retries, ['one']);
    downloads.update('one', OfflineDownloadStatus.queued);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('等待下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消下载'));
    await tester.pumpAndSettle();
    expect(downloads.cancellations, ['one']);
    await tester.pumpWidget(const SizedBox());
  });
}
