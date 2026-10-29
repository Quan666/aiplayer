import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'macOS folder menu downloads every WebDAV episode with one cached episode',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      FlutterSecureStorage.setMockInitialValues({});
      late _Fixture fixture;
      await tester.runAsync(() async {
        await AppLog.instance.clear();
        fixture = await _Fixture.create();
        // Own the worker port in the real event loop so shutdown can finish
        // after the widget test stops pumping frames.
        await fixture.model.downloads.initialize();
      });
      final folder = find.byKey(const ValueKey(_Fixture.folder));
      final menu = find.byKey(
        const ValueKey('folder-options:${_Fixture.folder}'),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme().copyWith(
              platform: TargetPlatform.macOS,
            ),
            home: SourceBrowser(
              model: fixture.model,
              source: fixture.source,
              initialPath: _Fixture.parent,
              initialName: '2026-10',
            ),
          ),
        );
        await _wait(tester, fixture, () => menu.evaluate().isNotEmpty);
        expect(folder, findsOneWidget);
        expect(fixture.store.all('media'), hasLength(1));

        // Use the real desktop folder-row action. Downloads and registration
        // run through the production model, worker, database and HTTP adapter.
        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(find.text('下载文件夹'), findsOneWidget);
        await tester.tap(find.text('下载文件夹'));
        await tester.pumpAndSettle();
        await _wait(
          tester,
          fixture,
          () =>
              fixture.model.downloads.entries.length == fixture.files.length &&
              fixture.model.downloads.entries.values.every(
                (entry) => !entry.isDirectory,
              ),
        );
        expect(folder, findsOneWidget);
        expect(fixture.model.downloads.completedCount, 0);
        expect(
          fixture.model.downloads.entries.values.map(
            (entry) => entry.remotePath,
          ),
          unorderedEquals(fixture.files.map((entry) => entry.path)),
        );
        expect(fixture.store.all('media'), hasLength(4));
        final summaries = AppLog.instance.entries
            .where((entry) => entry.scope == '文件夹下载')
            .toList();
        expect(summaries, hasLength(1));
        expect(summaries.single.message, contains('发现 4 个视频'));
        expect(summaries.single.message, contains('绑定 4 个'));
        expect(summaries.single.message, contains('新增 4 个任务'));
        expect(summaries.single.message, isNot(contains(_Fixture.title)));
        expect(
          summaries.single.message,
          isNot(contains(fixture.source['url'])),
        );
        expect(
          fixture.model.sourceMedia('dav', fixture.files.last.path)?.id,
          'known-episode',
        );

        fixture.release();
        await _wait(
          tester,
          fixture,
          () => fixture.model.downloads.completedCount == fixture.files.length,
        );
        expect(fixture.model.downloads.activeCount, 0);
        expect(
          AppLog.instance.entries.where((entry) => entry.scope == '文件夹下载'),
          hasLength(1),
        );
        expect(fixture.model.downloads.taskIds, hasLength(4));
        expect(fixture.downloaded, unorderedEquals(fixture.content.keys));
        expect(fixture.listed, contains('/share/${_Fixture.parent}'));
        expect(fixture.listed, contains('/share/${_Fixture.folder}'));
        await tester.runAsync(() async {
          for (final entry in fixture.model.downloads.entries.values) {
            expect(
              await File(entry.localPath).readAsBytes(),
              fixture.content['/share/${entry.remotePath}'],
            );
          }
        });
        expect(tester.takeException(), isNull);
      } finally {
        fixture.release();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(fixture.close);
      }
    }, _RealHttp()),
  );
}

Future<void> _wait(
  WidgetTester tester,
  _Fixture fixture,
  bool Function() ready,
) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    final failed = fixture.model.downloads.entries.values
        .where((entry) => entry.status == OfflineDownloadStatus.failed)
        .firstOrNull;
    if (failed != null) fail(failed.error);
    if (clock.elapsed > const Duration(seconds: 15)) {
      fail(
        'Folder action did not finish. Listings: ${fixture.listed}; '
        'downloads: ${fixture.model.downloads.entries.values.map((entry) => (entry.remotePath, entry.status))}',
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Fixture {
  static const parent = '2026-10/';
  static const title = '归还者的魔法要特别 第二季';
  static const folder = '$parent$title/';
  final Directory directory;
  final AppStore store;
  final HttpServer server;
  final Map<String, dynamic> source;
  final List<SourceEntry> files;
  final Map<String, List<int>> content;
  final listed = <String>[];
  final downloaded = <String>[];
  final transferGate = Completer<void>();
  final handlers = <Future<void>>{};
  late final model = AppModel(store, directory, backgroundWork: false);

  _Fixture(this.directory, this.store, this.server, this.source, this.files)
    : content = {
        for (var index = 0; index < files.length; index++)
          '/share/${files[index].path}': List<int>.generate(
            files[index].size,
            (offset) => (offset + index) % 251,
          ),
      } {
    server.listen((request) {
      late Future<void> handler;
      handler = _handle(request).whenComplete(() => handlers.remove(handler));
      handlers.add(handler);
    });
  }

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'source-folder-download-',
    );
    final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = <String, dynamic>{
      'id': 'dav',
      'kind': 'webdav',
      'label': 'DAV',
      'url': 'http://127.0.0.1:${server.port}/share/',
    };
    // E15 and E16 match the reported files. E13-E14 are synthetic siblings.
    // Only the final listed file, E16, is already imported and cached.
    final files = [
      for (var episode = 13; episode <= 16; episode++)
        SourceEntry(
          name: '$title - E$episode [ANi] [繁体].mp4',
          path: '$folder$title - E$episode [ANi] [繁体].mp4',
          size: 4096,
        ),
    ];
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [source]);
    store.save('media', 'known-episode', {
      'title': files.last.name,
      'fileName': files.last.name,
      'series': '归还者的魔法要特别',
      'episode': '16',
      'season': '2',
      'size': files.last.size,
    });
    store.setLocal('location:known-episode', {
      'id': 'known-episode',
      'source': 'dav',
      'path': files.last.path,
      'size': files.last.size,
    });
    persistDirectoryPreview(
      store,
      'dav',
      folder,
      DirectoryPreview(
        collection: identifyDirectory(folder, [files.last]),
        context: 'old-listing',
        fingerprint: 'one-episode',
        updatedAt: 1,
        modified: 0,
      ),
    );
    return _Fixture(directory, store, server, source, files);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path);
    try {
      if (request.method == 'PROPFIND') {
        listed.add(path);
        final children = switch (path) {
          '/share/' => ['/share/$parent'],
          '/share/$parent' => ['/share/$folder'],
          '/share/$folder' => content.keys.toList(),
          _ => null,
        };
        if (children == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.statusCode = HttpStatus.multiStatus;
          final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
          for (final child in [path, ...children]) {
            xml.write(
              '<d:response><d:href>${Uri(path: child)}</d:href>'
              '<d:propstat><d:prop><d:resourcetype>'
              '${child.endsWith('/') ? '<d:collection/>' : ''}'
              '</d:resourcetype><d:getcontentlength>4096</d:getcontentlength>'
              '</d:prop></d:propstat></d:response>',
            );
          }
          request.response.write('$xml</d:multistatus>');
        }
      } else if (content[path] case final bytes?) {
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.headers.set('etag', '"menu-episode-v1"');
        request.response.contentLength = bytes.length;
        if (request.method == 'GET') {
          downloaded.add(path);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes 0-${bytes.length - 1}/${bytes.length}',
          );
          await transferGate.future;
          request.response.add(bytes);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } on HttpException {
      // Leaving the parent row's menu may cancel an optional preview request.
    } on SocketException {
      // The browser can discard an in-flight preview without affecting downloads.
    }
  }

  void release() {
    if (!transferGate.isCompleted) transferGate.complete();
  }

  Future<void> close() async {
    release();
    await model.downloads.close();
    model.dispose();
    await server.close(force: true);
    await Future.wait(List<Future<void>>.of(handlers));
    store.dispose();
    await directory.delete(recursive: true);
  }
}
