import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _ObservedModel extends AppModel {
  final String address;
  final completedListings = <String, int>{};
  final parsedListings = <String, DirectoryCollection?>{};
  _ObservedModel(super.store, super.documents, this.address)
    : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async =>
      HttpOverrides.runWithHttpOverrides(
        () => HttpSource(address, webdav: true),
        _RealHttp(),
      );

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final result = await super.synchronizeDirectoryEntriesInBackground(
      sourceId,
      path,
      entries,
      anchorId: anchorId,
      cancel: cancel,
    );
    parsedListings[path] = result;
    completedListings[path] = (completedListings[path] ?? 0) + 1;
    return result;
  }
}

String _listing(String directory, List<String> children) {
  final result = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  void append(String path) {
    result.write(
      '<d:response><d:href>${Uri(path: path)}</d:href>'
      '<d:propstat><d:prop><d:resourcetype>'
      '${path.endsWith('/') ? '<d:collection/>' : ''}'
      '</d:resourcetype><d:getcontentlength>42</d:getcontentlength>'
      '</d:prop></d:propstat></d:response>',
    );
  }

  append(directory);
  for (final child in children) {
    append('$directory$child');
  }
  return '$result</d:multistatus>';
}

Future<void> _wait(WidgetTester tester, bool Function() finished) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (finished()) return;
  }
  fail('The real WebDAV listing or metadata worker did not complete.');
}

void main() {
  for (final (label, subfolder, names, expected) in [
    (
      'standard named episodes',
      '',
      ['Series S01E01.mkv', 'Series S01E02.mkv'],
      2,
    ),
    ('numeric episodes', '', ['01.mkv', '02.mkv'], 2),
    ('dot-separated episodes', '', ['Series.01.mkv', 'Series.02.mkv'], 2),
    ('single video named after its folder', '', ['Series.mkv'], 1),
    ('numeric episodes inside S01', 'S01', ['01.mkv', '02.mkv'], 2),
    ('numeric episodes inside 第1季', '第1季', ['01.mkv', '02.mkv'], 2),
    ('numeric episodes inside Season 2', 'Season 2', ['01.mkv', '02.mkv'], 2),
    (
      'named and numeric episodes inside a renamed folder',
      '已改名目录',
      ['02.mkv', 'Series S02E01.mkv', 'S02E03.mkv', 'Series E04.mkv'],
      4,
    ),
    ('one numeric episode', '', ['01.mkv'], 1),
    (
      'numeric episodes and a trailer',
      '',
      ['01.mkv', '02.mkv', 'trailer.mkv'],
      2,
    ),
  ]) {
    testWidgets('first open from an empty library shows details: $label', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      late Directory root;
      late AppStore store;
      late HttpServer server;
      late _ObservedModel model;
      final requests = <String>[];
      final target = subfolder.isEmpty ? 'Series/' : 'Series/$subfolder/';
      final folders = <String, List<String>>{
        '/dav/': ['Series/'],
        if (subfolder.isNotEmpty) '/dav/Series/': ['$subfolder/'],
        '/dav/$target': names,
      };
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('first-open-webdav-');
        store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final path = Uri.decodeComponent(request.uri.path);
          requests.add(path);
          final children = folders[path];
          request.response.statusCode = children == null ? 404 : 207;
          if (children != null) {
            request.response.write(_listing(path, children));
          }
          await request.response.close();
        });
        model = _ObservedModel(
          store,
          root,
          'http://127.0.0.1:${server.port}/dav/',
        );
        await model.loadLibrarySnapshot();
      });
      var plays = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
              onPlay: (_) async => plays++,
            ),
          ),
        );
        final parent = find.byKey(const ValueKey('Series/'));
        await _wait(tester, () => parent.evaluate().isNotEmpty);
        expect(store.all('media'), isEmpty);
        await tester.tap(parent);
        if (subfolder.isNotEmpty) {
          final child = find.byKey(ValueKey(target));
          await _wait(tester, () => child.evaluate().isNotEmpty);
          expect(store.all('media'), isEmpty);
          await tester.tap(child);
        }
        await _wait(tester, () => (model.completedListings[target] ?? 0) > 0);
        if (model.parsedListings[target] != null) {
          await _wait(
            tester,
            () => find.byType(MediaDetailsOverview).evaluate().isNotEmpty,
          );
        }
        await tester.pumpAndSettle();
        expect(plays, 0);
        expect(store.records('progress'), isEmpty);
        expect(
          find.byType(MediaDetailsOverview),
          findsOneWidget,
          reason:
              'target=$target; parsed=${model.parsedListings[target]?.title}; '
              'stored=${store.all('media').length}; requests=$requests',
        );
        expect(store.all('media'), hasLength(expected));
        expect(
          store
              .all('media')
              .every((record) => record.data['series'] == 'Series'),
          isTrue,
        );
        if (subfolder == 'Season 2') {
          expect(
            store.all('media').every((record) => record.data['season'] == '2'),
            isTrue,
          );
        }
        if (names.length == 1 && names.single == 'Series.mkv') {
          expect(
            '${store.all('media').single.data['episode'] ?? ''}',
            isEmpty,
            reason:
                'Opening a single named video must not fabricate episode 1.',
          );
        } else if (names.length > expected) {
          // An unrecognized extra keeps membership partial, so the header
          // reports every listed video without counting the trailer as an
          // episode or importing it into the library.
          expect(
            find.descendant(
              of: find.byType(MediaDetailsOverview),
              matching: find.text('${names.length} 个视频'),
            ),
            findsOneWidget,
          );
          expect(find.textContaining('已收录'), findsNothing);
          expect(model.sourceMedia('nas', '${target}trailer.mkv'), isNull);
          expect(
            store.all('media').map((record) => record.data['episode']).toSet(),
            {'1', '2'},
          );
        } else {
          expect(find.textContaining('已收录 $expected 集'), findsOneWidget);
        }
        if (subfolder == '已改名目录') {
          expect(
            store.all('media').map((record) => record.data['episode']).toSet(),
            {'1', '2', '3', '4'},
          );
          final lastEpisode = find.byKey(ValueKey('$target${names.last}'));
          await tester.scrollUntilVisible(
            lastEpisode,
            200,
            scrollable: find.byType(Scrollable).last,
          );
          expect(
            tester
                .widget<MediaDetailsEpisodeTile>(lastEpisode)
                .item
                .data['episode'],
            '4',
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          store.dispose();
          await server.close(force: true);
          await root.delete(recursive: true);
        });
      }
    });
  }

  for (final (label, basePath, title, season) in [
    ('named series source root', '/Series/', 'Series', '1'),
    ('season source root', '/Series/S02/', 'Series', '2'),
    ('unnamed season source root', '/S01/', null, '1'),
  ]) {
    testWidgets('first source click with numeric videos: $label', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      late Directory root;
      late AppStore store;
      late HttpServer server;
      late _ObservedModel model;
      final requests = <String>[];
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('first-open-webdav-root-');
        store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final path = Uri.decodeComponent(request.uri.path);
          requests.add(path);
          request.response.statusCode = path == basePath ? 207 : 404;
          if (path == basePath) {
            request.response.write(_listing(path, ['01.mkv', '02.mkv']));
          }
          await request.response.close();
        });
        final address = 'http://127.0.0.1:${server.port}$basePath';
        store.setLocal('sources', [
          {'id': 'nas', 'kind': 'webdav', 'label': 'NAS', 'url': address},
        ]);
        model = _ObservedModel(store, root, address);
        await model.loadLibrarySnapshot();
      });
      var plays = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourcesPage(
              model: model,
              onImport: () async {},
              onPlay: (_) async => plays++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.all('media'), isEmpty);
        expect(requests, isEmpty);
        await tester.tap(find.text('NAS'));
        await _wait(tester, () => (model.completedListings[''] ?? 0) > 0);
        if (title != null) {
          await _wait(
            tester,
            () => find.byType(MediaDetailsOverview).evaluate().isNotEmpty,
          );
        }
        await tester.pumpAndSettle();
        expect(plays, 0);
        expect(store.records('progress'), isEmpty);
        expect(requests, [basePath]);
        final records = store.all('media');
        if (title == null) {
          expect(find.byType(MediaDetailsOverview), findsNothing);
          expect(
            records,
            isEmpty,
            reason:
                'S01 without a named parent must not become a guessed series.',
          );
        } else {
          expect(find.byType(MediaDetailsOverview), findsOneWidget);
          expect(records, hasLength(2));
          expect(
            records.every((record) => record.data['series'] == title),
            isTrue,
          );
          expect(
            records.every(
              (record) => '${record.data['season'] ?? ''}'.isEmpty
                  ? season == '1'
                  : record.data['season'] == season,
            ),
            isTrue,
          );
          expect(find.textContaining('已收录 2 集'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          store.dispose();
          await server.close(force: true);
          await root.delete(recursive: true);
        });
      }
    });
  }
}
