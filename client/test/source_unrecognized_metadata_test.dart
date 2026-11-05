import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _files = [
  SourceEntry(
    name: 'Example S01E01.mkv',
    path: 'Show/Example S01E01.mkv',
    size: 100,
  ),
  SourceEntry(
    name: 'Example S01E02.mkv',
    path: 'Show/Example S01E02.mkv',
    size: 100,
  ),
  SourceEntry(
    name: 'opaque-video.mkv',
    path: 'Show/opaque-video.mkv',
    size: 100,
  ),
];

class _Transport implements JsonTransport {
  int requests = 0;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    requests++;
    return {'list': <Object>[], 'data': <Object>[], 'total': 0};
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  final transport = _Transport();
  int aiRequests = 0;
  @override
  LibraryCatalog get catalog => tracked;
  late final tracked = LibraryCatalog(
    store,
    transport: transport,
    strategy: () => preferences.metadataStrategy,
    automaticEnabled: super.catalog.automaticEnabled,
    prepareDirectory: super.catalog.prepareDirectory,
    persistDirectory: super.catalog.persistDirectory,
    readDirectory: super.catalog.readDirectory,
    episodeNamesCovered: super.catalog.episodeNamesCovered,
    aiFallback: (_, _, _, _) async {
      aiRequests++;
      return null;
    },
  );
  @override
  Future<SourceAdapter> adapter(String id) async => _Source();
  @override
  bool tryEnsureSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    SourcePreviewBinding? binding,
  }) => false;
}

class _Source extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => _files;
  @override
  Future<SourceEntry> stat(String path) async =>
      _files.firstWhere((entry) => entry.path == path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

void main() {
  for (final prior in ['none', 'guessed', 'recognized']) {
    testWidgets(
      'auto OFF opens $prior folder without guessed detail or AI work',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = Directory.systemTemp.createTempSync(
          'unrecognized-folder-',
        );
        final store = AppStore(':memory:')
          ..setLocal('settings', {
            'autoIdentifyOnFolderOpen': false,
            'metadataStrategy': 'balanced',
            'aiMetadataEnabled': true,
            'autoDiscover': false,
          });
        if (prior != 'none') {
          store.save('media', 'old', {
            'title': _files.first.name,
            'fileName': _files.first.name,
            'series': 'Example',
            'season': '1',
            'episode': '1',
            'metadataTitle': prior == 'recognized' ? '真实缓存资料' : '不可信的翻译标题',
            if (prior == 'recognized') 'bangumiId': '42',
            'summary': prior == 'recognized' ? '已经识别的简介' : '仅有文本不是识别结果',
          });
          store.setLocal('location:old', {
            'id': 'old',
            'source': 'dav',
            'path': _files.first.path,
            'size': 100,
          });
        }
        final model = _Model(store, directory);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: GlassPalette.theme(),
              home: SourceBrowser(
                model: model,
                source: const {'id': 'dav', 'kind': 'webdav', 'label': 'NAS'},
                initialPath: 'Show',
                initialName: 'Show',
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(model.transport.requests, 0);
          expect(model.aiRequests, 0);
          expect(model.metadataTasks, isEmpty);
          if (prior == 'recognized') {
            expect(find.byType(MediaDetailsOverview), findsOneWidget);
            expect(find.text('真实缓存资料'), findsWidgets);
          } else {
            expect(find.byType(MediaDetailsOverview), findsNothing);
            expect(find.byType(MediaTitleTranslation), findsNothing);
            expect(find.text('不可信的翻译标题'), findsNothing);
            for (final file in _files) {
              expect(find.text(file.name), findsOneWidget);
            }
            expect(store.all('media'), hasLength(prior == 'none' ? 0 : 1));
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
