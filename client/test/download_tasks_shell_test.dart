import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/download_tasks_sheet.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;
  late _Downloads downloads;
  late _Model model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('download-tasks-shell-');
    store = AppStore(
      ':memory:',
    )..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
    downloads = _Downloads(directory);
    model = _Model(store, directory, downloads);
  });

  tearDown(() {
    model.dispose();
    downloads.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('download task entry opens from every tab at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      for (final index in [0, 1, 2]) {
        await tester.tap(find.byKey(ValueKey('nav-item-$index')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('下载任务'), findsNothing);
      }
      downloads.update(0);
      await tester.pump();
      for (final index in [0, 1, 2]) {
        await tester.tap(find.byKey(ValueKey('nav-item-$index')));
        await tester.pumpAndSettle();
        final button = find.byTooltip('下载任务');
        expect(button, findsOneWidget);
        final rect = tester.getRect(button);
        expect(rect.center.dx, greaterThan(width - 70));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(DownloadTasksSheet), findsOneWidget);
        expect(find.byType(DownloadTasksButton), findsNothing);
        Navigator.of(tester.element(find.byType(DownloadTasksSheet))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(DownloadTasksSheet), findsNothing);
        expect(find.byTooltip('下载任务'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('progress updates leave shell and library snapshot unchanged', (
    tester,
  ) async {
    await mount(tester);
    final shell = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final reads = model.snapshotReads;
    for (var received = 0; received < 100; received += 10) {
      downloads.update(received);
      await tester.pump();
    }
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first), same(shell));
    expect(model.snapshotReads, reads);
    expect(find.byTooltip('下载任务'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DownloadTasksButton),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed tasks stay visible until the last task is removed', (
    tester,
  ) async {
    await mount(tester);
    final shell = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final reads = model.snapshotReads;
    expect(find.byTooltip('下载任务'), findsNothing);
    for (final status in OfflineDownloadStatus.values) {
      downloads.update(100, status: status);
      await tester.pump();
      expect(find.byTooltip('下载任务'), findsOneWidget);
      expect(tester.widget<Scaffold>(find.byType(Scaffold).first), same(shell));
    }
    downloads.update(100, status: OfflineDownloadStatus.completed);
    await tester.pump();
    expect(
      tester
          .widget<Badge>(
            find.descendant(
              of: find.byType(DownloadTasksButton),
              matching: find.byType(Badge),
            ),
          )
          .isLabelVisible,
      isFalse,
    );
    await downloads.delete('one');
    await tester.pump();
    expect(find.byTooltip('下载任务'), findsNothing);
    downloads.update(10);
    await tester.pump();
    expect(find.byTooltip('下载任务'), findsOneWidget);
    await downloads.cancel('one');
    await tester.pump();
    expect(find.byTooltip('下载任务'), findsNothing);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first), same(shell));
    expect(model.snapshotReads, reads);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('task shortcuts avoid metadata, keyboard and covering routes', (
    tester,
  ) async {
    final task = model.startMetadataTask(const [], label: '已完成识别');
    await task.done;
    await mount(tester);
    final metadataOnlyRect = tester.getRect(find.byTooltip('识别任务'));
    expect(find.byTooltip('下载任务'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('task-shortcuts'))).height,
      metadataOnlyRect.height,
    );
    downloads.update(0);
    await tester.pumpAndSettle();
    final downloadRect = tester.getRect(find.byTooltip('下载任务'));
    final metadataRect = tester.getRect(find.byTooltip('识别任务'));
    expect(downloadRect.top - metadataRect.bottom, 8);
    await downloads.cancel('one');
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byTooltip('识别任务')), metadataOnlyRect);
    expect(
      tester.getSize(find.byKey(const ValueKey('task-shortcuts'))).height,
      metadataOnlyRect.height,
    );
    downloads.update(0);
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-shortcuts')), findsNothing);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byTooltip('下载任务'), findsOneWidget);

    final navigator = Navigator.of(tester.element(find.byType(LibraryPage)));
    final covered = navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('独立播放页面'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTasksButton, skipOffstage: false), findsNothing);
    navigator.pop();
    await covered;
    await tester.pumpAndSettle();
    expect(find.byTooltip('下载任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacing the model detaches the previous task manager', (
    tester,
  ) async {
    await mount(tester);
    downloads.update(10);
    await tester.pump();
    final replacementDownloads = _Downloads(directory);
    final replacement = _Model(store, directory, replacementDownloads);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: LibraryPage(model: replacement),
        ),
      );
      await tester.pumpAndSettle();
      expect(downloads.listening, isFalse);
      expect(replacementDownloads.listening, isTrue);
      expect(find.byTooltip('下载任务'), findsNothing);
      downloads.update(20);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(DownloadTasksButton),
          matching: find.text('1'),
        ),
        findsNothing,
      );
      replacementDownloads.update(0);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(DownloadTasksButton),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      replacement.dispose();
      replacementDownloads.dispose();
    }
  });
}

class _Downloads extends OfflineDownloads {
  _Downloads(Directory directory)
    : super(
        directory: directory,
        storePath: ':memory:',
        sourceConfiguration: (_) async => null,
      );
  final Map<String, OfflineDownload> _entries = {};
  @override
  Map<String, OfflineDownload> get entries => _entries;
  bool get listening => hasListeners;
  @override
  List<String> get taskIds => entries.keys.toList();
  @override
  int get activeCount => entries.values
      .where(
        (entry) =>
            entry.status == OfflineDownloadStatus.queued ||
            entry.status == OfflineDownloadStatus.downloading,
      )
      .length;
  @override
  int get pausedCount => entries.values
      .where((entry) => entry.status == OfflineDownloadStatus.paused)
      .length;
  @override
  int get failedCount => entries.values
      .where((entry) => entry.status == OfflineDownloadStatus.failed)
      .length;
  @override
  int get completedCount =>
      entries.values.where((entry) => entry.isComplete).length;
  @override
  bool get initialized => true;
  @override
  Future<void> initialize() async {}
  @override
  OfflineDownload? entryFor(String mediaId) => entries[mediaId];
  void update(
    int received, {
    OfflineDownloadStatus status = OfflineDownloadStatus.downloading,
  }) {
    if (!entries.containsKey('one')) tasksRevision++;
    entries['one'] = OfflineDownload(
      mediaId: 'one',
      sourceId: 'dav',
      remotePath: '/one.mkv',
      localPath: '/offline/one.mkv',
      name: 'one.mkv',
      status: status,
      received: received,
      total: 100,
    );
    notifyListeners();
  }

  @override
  Future<void> delete(String id) async {
    if (entries.remove(id) == null) return;
    tasksRevision++;
    notifyListeners();
  }

  @override
  Future<void> cancel(String id) => delete(id);
}

class _Model extends AppModel {
  _Model(super.store, super.documents, this.downloads)
    : super(backgroundWork: false);
  @override
  final OfflineDownloads downloads;
  int snapshotReads = 0;
  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    snapshotReads++;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
  }
}
