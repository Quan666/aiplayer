import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/download_tasks_sheet.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Downloads extends OfflineDownloads {
  final values = <String, OfflineDownload>{};
  final ids = <String>[];
  final actions = <String>[];
  int entryReads = 0, listReads = 0, listeners = 0;
  int _active = 0, _paused = 0, _failed = 0, _completed = 0;
  Completer<void>? pauseGate;

  _Downloads(Directory directory)
    : super(
        directory: directory,
        storePath: ':memory:',
        sourceConfiguration: (_) async => null,
      );

  @override
  List<String> get taskIds {
    listReads++;
    return ids;
  }

  @override
  int get activeCount => _active;
  @override
  int get pausedCount => _paused;
  @override
  int get failedCount => _failed;
  @override
  int get completedCount => _completed;
  @override
  OfflineDownload? entryFor(String mediaId) {
    entryReads++;
    return values[mediaId];
  }

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }

  void put(
    String id, {
    OfflineDownloadStatus status = OfflineDownloadStatus.downloading,
    int received = 25,
    bool notify = true,
    bool isDirectory = false,
    int discoveredFiles = 0,
  }) {
    if (!values.containsKey(id)) {
      ids.add(id);
      tasksRevision++;
    }
    values[id] = OfflineDownload(
      mediaId: id,
      sourceId: 'nas',
      remotePath: '/share/$id.mkv',
      localPath: '/offline/$id.mkv',
      name: isDirectory ? id : '$id.mkv',
      status: status,
      received: received,
      total: 100,
      userPaused: status == OfflineDownloadStatus.paused,
      error: status == OfflineDownloadStatus.failed ? '连接中断' : '',
      isDirectory: isDirectory,
      discoveredFiles: discoveredFiles,
    );
    _count();
    if (notify) notifyListeners();
  }

  void remove(String id) {
    if (values.remove(id) == null) return;
    ids.remove(id);
    tasksRevision++;
    _count();
    notifyListeners();
  }

  void _count() {
    _active = _paused = _failed = _completed = 0;
    for (final entry in values.values) {
      switch (entry.status) {
        case OfflineDownloadStatus.queued:
        case OfflineDownloadStatus.downloading:
          _active++;
        case OfflineDownloadStatus.paused:
          _paused++;
        case OfflineDownloadStatus.failed:
          _failed++;
        case OfflineDownloadStatus.completed:
          _completed++;
      }
    }
  }

  @override
  Future<void> pause(String id) async {
    actions.add('pause:$id');
    if (pauseGate != null) {
      await pauseGate!.future;
      return;
    }
    put(id, status: OfflineDownloadStatus.paused);
  }

  @override
  Future<void> resume(String id) async {
    actions.add('resume:$id');
    put(id);
  }

  @override
  Future<void> retry(String id) async {
    actions.add('retry:$id');
    put(id);
  }

  @override
  Future<void> cancel(String id) async {
    actions.add('cancel:$id');
    remove(id);
  }

  @override
  Future<void> delete(String id) async {
    actions.add('delete:$id');
    remove(id);
  }

  @override
  Future<void> pauseAll() async {
    actions.add('pause-all');
    for (final id in List<String>.of(ids)) {
      if (values[id]!.status == OfflineDownloadStatus.downloading ||
          values[id]!.status == OfflineDownloadStatus.queued) {
        put(id, status: OfflineDownloadStatus.paused);
      }
    }
  }

  @override
  Future<void> resumeAll() async {
    actions.add('resume-all');
    for (final id in List<String>.of(ids)) {
      if (values[id]!.status == OfflineDownloadStatus.paused) put(id);
    }
  }
}

class _Model extends AppModel {
  final _Downloads manager;
  _Model(super.store, super.documents, this.manager)
    : super(backgroundWork: false);
  @override
  OfflineDownloads get downloads => manager;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _Downloads manager;
  late _Model model;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('download-task-ui-');
    store = AppStore(':memory:');
    manager = _Downloads(directory);
    model = _Model(store, directory, manager);
  });
  tearDown(() {
    model.dispose();
    manager.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Widget shell(Widget child) => MaterialApp(
    theme: GlassPalette.theme(),
    home: Scaffold(body: child),
  );

  testWidgets(
    'task button hides with no tasks and returns for completed or pending tasks',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            floatingActionButton: DownloadTasksButton(model: model),
          ),
        ),
      );
      expect(find.byTooltip('下载任务'), findsNothing);
      manager.put(
        'done',
        status: OfflineDownloadStatus.completed,
        received: 100,
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载任务'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
      await tester.tap(find.byTooltip('下载任务'));
      await tester.pumpAndSettle();
      expect(find.text('done.mkv'), findsOneWidget);
      await tester.tap(find.byTooltip('删除离线视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('暂无下载任务'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载任务'), findsNothing);
      manager.put('pending');
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载任务'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
      await tester.tap(find.byTooltip('下载任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('取消下载'));
      await tester.pumpAndSettle();
      expect(find.text('暂无下载任务'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载任务'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(manager.listeners, 0);
    },
  );

  testWidgets(
    'large queue is lazy and progress preserves the list structure and other rows',
    (tester) async {
      for (var i = 0; i < 1000; i++) {
        manager.put('task-$i', notify: false);
      }
      await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
      await tester.pumpAndSettle();
      expect(find.text('task-999.mkv'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator).evaluate().length,
        lessThan(30),
      );
      final list = tester.widget(
        find.byKey(const PageStorageKey('download-task-list')),
      );
      final other = tester.widget(find.text('task-998.mkv'));
      manager.listReads = 0;
      manager.put('task-999', received: 50);
      await tester.pump();
      expect(manager.listReads, 0);
      expect(
        identical(
          list,
          tester.widget(find.byKey(const PageStorageKey('download-task-list'))),
        ),
        isTrue,
      );
      expect(
        identical(other, tester.widget(find.text('task-998.mkv'))),
        isTrue,
      );
      expect(find.text('下载中 · 50 B / 100 B · 50%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('folder scan shows video count without byte progress', (
    tester,
  ) async {
    manager.put('Season 1', isDirectory: true, discoveredFiles: 12);
    await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('读取文件夹 · 12 个视频'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byTooltip('暂停下载'), findsOneWidget);
    expect(find.byTooltip('取消下载'), findsOneWidget);
    manager.put(
      'Season 1',
      isDirectory: true,
      discoveredFiles: 20,
      status: OfflineDownloadStatus.paused,
    );
    await tester.pump();
    expect(find.text('已暂停 · 20 个视频'), findsOneWidget);
    expect(find.byTooltip('继续下载'), findsOneWidget);
    await tester.tap(find.byTooltip('取消下载'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('cancel:Season 1'));
    expect(find.text('暂无下载任务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(manager.listeners, 0);
  });

  testWidgets('task actions pause continue retry cancel and confirm deletion', (
    tester,
  ) async {
    manager.put('active');
    manager.put('failed', status: OfflineDownloadStatus.failed);
    manager.put('done', status: OfflineDownloadStatus.completed, received: 100);
    await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('暂停下载'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('pause:active'));
    await tester.tap(find.byTooltip('继续下载'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('resume:active'));
    await tester.tap(find.byTooltip('重试下载'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('retry:failed'));
    await tester.tap(find.byTooltip('全部暂停'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('pause-all'));
    await tester.tap(find.byTooltip('全部继续'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('resume-all'));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('download-task:active')),
        matching: find.byTooltip('取消下载'),
      ),
    );
    await tester.pumpAndSettle();
    expect(manager.actions, contains('cancel:active'));
    await tester.tap(find.byTooltip('删除离线视频'));
    await tester.pumpAndSettle();
    expect(manager.actions, isNot(contains('delete:done')));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(manager.actions, contains('delete:done'));
    expect(find.text('done.mkv'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('paused updates and removal do not read tasks without a frame', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    manager.put('one');
    manager.put('two');
    await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    manager.entryReads = manager.listReads = 0;
    manager.put('one', received: 60);
    manager.remove('two');
    expect(manager.entryReads, 0);
    expect(manager.listReads, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('two.mkv'), findsNothing);
    expect(find.text('下载中 · 60 B / 100 B · 60%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hidden removal keeps a safe frozen list across unrelated layout',
    (tester) async {
      for (var i = 0; i < 8; i++) {
        manager.put('task-$i', notify: false);
      }
      Future<void> mount(bool visible, double width) => tester.pumpWidget(
        shell(
          TickerMode(
            enabled: visible,
            child: SizedBox(
              width: width,
              child: DownloadTasksSheet(model: model),
            ),
          ),
        ),
      );
      await mount(true, 500);
      await tester.pumpAndSettle();
      await mount(false, 500);
      manager.entryReads = manager.listReads = 0;
      for (final id in List<String>.of(manager.ids)) {
        manager.remove(id);
      }
      expect(manager.entryReads, 0);
      expect(manager.listReads, 0);
      await mount(false, 430);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(manager.listReads, 0);
      await mount(true, 430);
      await tester.pumpAndSettle();
      expect(find.text('暂无下载任务'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pending action finishing while paused is enabled after resume', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    manager.put('one');
    manager.pauseGate = Completer<void>();
    await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('暂停下载'));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('暂停下载'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    manager.pauseGate!.complete();
    await Future<void>.value();
    await Future<void>.value();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('暂停下载'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('model replacement detaches all previous task listeners', (
    tester,
  ) async {
    manager.put('old');
    final replacementStore = AppStore(':memory:');
    final replacementDownloads = _Downloads(directory)..put('new');
    final replacement = _Model(
      replacementStore,
      directory,
      replacementDownloads,
    );
    await tester.pumpWidget(shell(DownloadTasksSheet(model: model)));
    await tester.pumpAndSettle();
    expect(manager.listeners, greaterThan(0));
    await tester.pumpWidget(shell(DownloadTasksSheet(model: replacement)));
    await tester.pumpAndSettle();
    expect(manager.listeners, 0);
    manager.entryReads = manager.listReads = 0;
    manager.put('late');
    expect(manager.entryReads, 0);
    expect(manager.listReads, 0);
    expect(find.text('old.mkv'), findsNothing);
    expect(find.text('new.mkv'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(replacementDownloads.listeners, 0);
    replacement.dispose();
    replacementDownloads.dispose();
    replacementStore.dispose();
  });
}
