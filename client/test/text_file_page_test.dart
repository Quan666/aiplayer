import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:aiplayer/ui/text_file_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 250 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

Future<File> _file(
  WidgetTester tester,
  Directory root,
  String name,
  String text,
) async => (await tester.runAsync(
  () => File('${root.path}/$name').writeAsString(text),
))!;

SourceEntry _entry(File file, String name) =>
    SourceEntry(name: name, path: file.path);

Widget _page(Directory root, File file, String name) => MaterialApp(
  theme: GlassPalette.theme(),
  home: TextFilePage(
    source: const {'id': 'local', 'kind': 'local'},
    documentsPath: root.path,
    entry: _entry(file, name),
  ),
);

String? _count(WidgetTester tester) {
  final count = find.byKey(const ValueKey('text-search-count'));
  return count.evaluate().isEmpty ? null : tester.widget<Text>(count).data;
}

Finder _query() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == '搜索内容',
);

ScrollController _linesController(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('text-document-lines')))
    .controller!;

List<TextSpan> _highlights(WidgetTester tester, int row) =>
    (tester.widget<Text>(find.byKey(ValueKey('text-line:$row'))).textSpan!
            as TextSpan)
        .children!
        .whereType<TextSpan>()
        .where((span) => span.style?.backgroundColor != null)
        .toList();

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.resumed) return;
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

class _DelayedDocumentSecrets extends FlutterSecureStorage {
  final release = Completer<String?>();
  int sourceReads = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (key != 'source:remote') return Future.value(null);
    sourceReads++;
    return release.future;
  }
}

void main() {
  late Directory root;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    overrideSystemProxyPlatformForTesting('test');
    root = await Directory.systemTemp.createTemp('aiplayer-text-page-');
  });

  tearDown(() async {
    overrideSystemProxyPlatformForTesting(Platform.operatingSystem);
    await root.delete(recursive: true);
  });

  for (final fixture in [
    ('index.html', '<h1>原始文本</h1>\n<script>alert("plain text")</script>'),
    ('script.py', 'def greet():\n    print("原始文本")'),
    ('README.md', '# 原始文本\n[链接](https://example.test) **保留标记**'),
  ]) {
    testWidgets('${fixture.$1} displays source literally as selectable text', (
      tester,
    ) async {
      final file = await _file(tester, root, fixture.$1, fixture.$2);
      try {
        await tester.pumpWidget(_page(root, file, fixture.$1));
        await _until(
          tester,
          () => find.byKey(const ValueKey('text-line:1')).evaluate().isNotEmpty,
        );
        final actual = [
          for (var row = 0; row < 2; row++)
            tester
                .widget<Text>(find.byKey(ValueKey('text-line:$row')))
                .textSpan!
                .toPlainText(),
        ].join('\n');
        expect(actual, fixture.$2);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(find.byTooltip('用其他应用打开'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  testWidgets(
    'long text builds visible rows and search wraps with distinct current highlighting',
    (tester) async {
      final text = List.generate(
        1200,
        (row) => switch (row) {
          0 => 'Needle and needle',
          300 => 'middle NEEDLE',
          1199 => 'last needle',
          _ => 'ordinary row $row',
        },
      ).join('\n');
      final file = await _file(tester, root, 'long.md', text);
      try {
        await tester.pumpWidget(_page(root, file, 'long.md'));
        await _until(
          tester,
          () => find.byKey(const ValueKey('text-line:0')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const ValueKey('text-line:300')), findsNothing);
        expect(find.byKey(const ValueKey('text-line:1199')), findsNothing);
        final builtRows = find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('text-line:'),
        );
        expect(builtRows.evaluate().length, lessThan(80));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        await tester.enterText(_query(), 'needle');
        await tester.pump(const Duration(milliseconds: 220));
        await _until(tester, () => _count(tester) == '1/4');
        final first = _highlights(tester, 0);
        expect(first.map((span) => span.text), ['Needle', 'needle']);
        expect(
          first.first.style!.backgroundColor!.a,
          greaterThan(first.last.style!.backgroundColor!.a),
        );
        await tester.tap(find.byTooltip('下一个匹配'));
        await tester.pump();
        expect(_count(tester), '2/4');
        final second = _highlights(tester, 0);
        expect(
          second.first.style!.backgroundColor!.a,
          lessThan(second.last.style!.backgroundColor!.a),
        );
        await tester.tap(find.byTooltip('下一个匹配'));
        await tester.pump();
        expect(_count(tester), '3/4');
        expect(find.byKey(const ValueKey('text-line:300')), findsOneWidget);
        expect(_linesController(tester).offset, greaterThan(6000));
        await tester.tap(find.byTooltip('上一个匹配'));
        await tester.pump();
        await tester.tap(find.byTooltip('上一个匹配'));
        await tester.pump();
        await tester.tap(find.byTooltip('上一个匹配'));
        await tester.pump();
        expect(_count(tester), '4/4');
        expect(find.byKey(const ValueKey('text-line:1199')), findsOneWidget);
        expect(find.byKey(const ValueKey('text-line:0')), findsNothing);

        await tester.enterText(_query(), 'no such text');
        await tester.pump(const Duration(milliseconds: 220));
        await _until(tester, () => _count(tester) == '0/0');
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('下一个匹配'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_query(), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'resume retains query, selected match and independently scrolled position',
    (tester) async {
      final lines = List.generate(
        1000,
        (row) => row == 0 || row == 500 ? 'needle $row' : 'row $row',
      );
      final file = await _file(tester, root, 'resume.txt', lines.join('\n'));
      try {
        await tester.pumpWidget(_page(root, file, 'resume.txt'));
        await _until(
          tester,
          () => find.byKey(const ValueKey('text-line:0')).evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('搜索内容'));
        await tester.pump();
        await tester.enterText(_query(), 'needle');
        await tester.pump(const Duration(milliseconds: 220));
        await _until(tester, () => _count(tester) == '1/2');
        await tester.tap(find.byTooltip('下一个匹配'));
        await tester.pump();
        final controller = _linesController(tester);
        controller.jumpTo(controller.offset + 440);
        await tester.pump();
        final offset = controller.offset;
        _pause(tester);
        // No frame is delivered while Android is paused.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        expect(controller.offset, offset);
        lines[520] = 'updated while paused';
        await _file(tester, root, 'resume.txt', lines.join('\n'));
        _resume(tester);
        // The changed row confirms that the worker actually reloaded, rather
        // than merely checking the retained view before its async reply.
        await _until(tester, () {
          final row = find.byKey(const ValueKey('text-line:520'));
          return row.evaluate().isNotEmpty &&
              tester.widget<Text>(row).textSpan!.toPlainText() ==
                  'updated while paused';
        });
        await _until(tester, () => _count(tester) == '2/2');
        expect(tester.widget<TextField>(_query()).controller!.text, 'needle');
        expect(_count(tester), '2/2');
        expect(controller.offset, offset);
        expect(tester.takeException(), isNull);
      } finally {
        _resume(tester);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'initial background defers remote reads and pause without a frame rejects a late body',
    (tester) async {
      final requests = <String>[];
      late Completer<void> released,
          readStarted,
          firstFinished,
          resumedReleased,
          resumedReadStarted;
      final bytes = utf8.encode('remote body after resume');
      var reads = 0;
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      await tester.runAsync(() async {
        released = Completer<void>();
        readStarted = Completer<void>();
        firstFinished = Completer<void>();
        resumedReleased = Completer<void>();
        resumedReadStarted = Completer<void>();
        server.listen((request) async {
          requests.add(request.method);
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.contentLength = bytes.length;
          if (request.method == 'HEAD') {
            await request.response.close();
            return;
          }
          final currentRead = ++reads;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${bytes.length - 1}/${bytes.length}',
          );
          try {
            if (currentRead == 1) {
              request.response.add(bytes.sublist(0, 3));
              await request.response.flush();
              readStarted.complete();
              await released.future;
              request.response.add(bytes.sublist(3));
            } else {
              request.response.add(bytes.sublist(0, 3));
              await request.response.flush();
              resumedReadStarted.complete();
              await resumedReleased.future;
              request.response.add(bytes.sublist(3));
            }
            await request.response.close();
          } catch (_) {
            // The foreground worker owns the connection and closes it on pause.
          } finally {
            if (currentRead == 1) firstFinished.complete();
          }
        });
      });
      try {
        _pause(tester);
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: TextFilePage(
              source: {
                'id': 'remote',
                'kind': 'webdav',
                'url': 'http://127.0.0.1:${server.port}/',
              },
              documentsPath: root.path,
              entry: SourceEntry(
                name: 'remote.txt',
                path: '/remote.txt',
                size: bytes.length,
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        expect(requests, isEmpty);
        await tester.idle();
        expect(tester.binding.transientCallbackCount, 0);
        _resume(tester);
        await _until(tester, () => readStarted.isCompleted);
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        _pause(tester);
        // Flush cancellation continuations without requesting a new frame.
        await tester.idle();
        expect(tester.binding.transientCallbackCount, 0);
        final pausedRequests = requests.length;
        await tester.runAsync(() async {
          released.complete();
          await firstFinished.future.timeout(const Duration(seconds: 2));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        expect(requests.length, pausedRequests);
        expect(reads, 1);
        expect(find.byKey(const ValueKey('text-line:0')), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(tester.binding.transientCallbackCount, 0);

        _resume(tester);
        await _until(tester, () => resumedReadStarted.isCompleted);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        expect(find.byKey(const ValueKey('text-line:0')), findsNothing);
        await tester.runAsync(() async => resumedReleased.complete());
        await _until(
          tester,
          () => find.byKey(const ValueKey('text-line:0')).evaluate().isNotEmpty,
        );
        // The newly inserted text/scrollbar may animate its initial appearance;
        // after it settles there must be no continuing loading ticker.
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(reads, 2);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('text-line:0')))
              .textSpan!
              .toPlainText(),
          utf8.decode(bytes),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!released.isCompleted) released.complete();
        if (!resumedReleased.isCompleted) resumedReleased.complete();
        _resume(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => server.close(force: true));
      }
    },
  );

  testWidgets(
    'source browser views HTML and offers external PDF opening without importing media',
    (tester) async {
      await _file(tester, root, 'index.html', '<h1>view only</h1>');
      await _file(tester, root, 'paper.pdf', '%PDF-1.7');
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoIdentifyOnFolderOpen': false,
        });
      final model = AppModel(store, root, backgroundWork: false);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'local', 'kind': 'local', 'label': '本地'},
              initialPath: root.path,
              initialAlbumMode: false,
            ),
          ),
        );
        await _until(
          tester,
          () => find.text('index.html').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('index.html'));
        await _until(
          tester,
          () => find.byKey(const ValueKey('text-line:0')).evaluate().isNotEmpty,
        );
        expect(store.all('media'), isEmpty);
        expect(find.byType(TextFilePage), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('text-line:0')))
              .textSpan!
              .toPlainText(),
          '<h1>view only</h1>',
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(TextFilePage), findsNothing);
        await tester.tap(find.text('paper.pdf'));
        await tester.pumpAndSettle();
        expect(find.text('用其他应用打开'), findsOneWidget);
        expect(find.text('查看文本'), findsNothing);
        expect(store.all('media'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
      }
    },
  );

  for (final invalidation in [
    'rapid pause and resume',
    'source deleted',
    'source replaced',
    'page hidden',
  ]) {
    testWidgets('late credentials cannot open a document after $invalidation', (
      tester,
    ) async {
      const initial = {
        'id': 'remote',
        'kind': 'webdav',
        'url': 'http://127.0.0.1:1/old/',
      };
      final store = AppStore(':memory:')..setLocal('sources', [initial]);
      final secrets = _DelayedDocumentSecrets();
      final model = AppModel(
        store,
        root,
        secrets: secrets,
        backgroundWork: false,
      );
      late StateSetter updateVisibility;
      var visible = true, completed = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: StatefulBuilder(
              builder: (_, setState) {
                updateVisibility = setState;
                return TickerMode(
                  enabled: visible,
                  child: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () {
                          openSourceDocument(
                            context,
                            model: model,
                            sourceId: 'remote',
                            source: initial,
                            entry: const SourceEntry(
                              name: 'notes.md',
                              path: '/notes.md',
                            ),
                          ).whenComplete(() => completed = true);
                        },
                        child: const Text('查看文本'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('查看文本'));
        expect(secrets.sourceReads, 1);
        expect(completed, isFalse);
        switch (invalidation) {
          case 'rapid pause and resume':
            // A late secure-storage reply must not reopen after returning to
            // foreground, even if no intervening frame was ever delivered.
            _pause(tester);
            _resume(tester);
          case 'source deleted':
            store.setLocal('sources', []);
          case 'source replaced':
            store.setLocal('sources', [
              {...initial, 'url': 'http://127.0.0.1:1/replaced/'},
            ]);
          case 'page hidden':
            updateVisibility(() => visible = false);
            await tester.pump();
        }
        secrets.release.complete('late-private-password');
        await _until(
          tester,
          () => completed || find.byType(TextFilePage).evaluate().isNotEmpty,
        );
        expect(find.byType(TextFilePage), findsNothing);
        expect(find.byType(ExternalFilePage), findsNothing);
        expect(completed, isTrue);
        expect(secrets.sourceReads, 1);
        expect(store.all('media'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!secrets.release.isCompleted) secrets.release.complete(null);
        _resume(tester);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
      }
    });
  }
}
