import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _folder = '至高之力';
const _subject = {
  'provider': 'bangumi',
  'id': '42',
  'name': _folder,
  'name_cn': _folder,
  'mediaType': 'tv',
};

List<SourceEntry> _listing({bool extra = false}) => [
  for (var episode = 1; episode <= 3; episode++)
    SourceEntry(
      name: '$_folder - 0$episode.mkv',
      path: '$_folder/$_folder - 0$episode.mkv',
      size: episode,
      modified: 100,
    ),
  SourceEntry(
    name: extra ? '花絮.mkv' : 'opaque-final.mkv',
    path: '$_folder/${extra ? '花絮.mkv' : 'opaque-final.mkv'}',
    size: 4,
    modified: 100,
  ),
];

class _Model extends AppModel {
  final List<SourceEntry> entries;
  int completedCollections = 0, completedListings = 0;
  _Model(super.store, super.documents, this.entries)
    : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async => _Connection(entries);

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
    completedListings++;
    return result;
  }

  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final result = await super.synchronizeCollectionInBackground(
      sourceId,
      value,
      importMissing: importMissing,
      anchorId: anchorId,
      cancel: cancel,
    );
    completedCollections++;
    return result;
  }
}

class _NoCatalogMatches implements JsonTransport {
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    return {'list': <Object>[], 'results': <Object>[]};
  }
}

class _AiModel extends _Model {
  _AiModel(super.store, super.documents, super.entries);
  int aiCalls = 0;

  @override
  LibraryCatalog get catalog => _catalog;
  late final _catalog = LibraryCatalog(
    store,
    transport: _NoCatalogMatches(),
    strategy: () => 'conservative',
    tmdbNameAssist: () => false,
    prepareDirectory: super.catalog.prepareDirectory,
    persistDirectory: super.catalog.persistDirectory,
    readDirectory: super.catalog.readDirectory,
    episodeNamesCovered: super.catalog.episodeNamesCovered,
    aiFallback: (source, path, files, cancel) async {
      cancel?.check();
      if (path != _folder) return null;
      aiCalls++;
      return DirectoryCollection(
        title: _folder,
        season: '1',
        videos: files,
        identities: {
          for (var index = 0; index < entries.length; index++)
            entries[index].path: ReleaseName(_folder, '1', '${index + 1}'),
        },
        subject: _subject,
        episodeTitles: {
          for (var episode = 1; episode <= 4; episode++)
            '$episode': '第 $episode 集',
        },
      );
    },
  );
}

class _Connection extends SourceAdapter {
  final List<SourceEntry> entries;
  _Connection(this.entries);

  @override
  Future<List<SourceEntry>> list(String path) async => path.isEmpty
      ? const [
          SourceEntry(
            name: _folder,
            path: _folder,
            directory: true,
            modified: 100,
          ),
        ]
      : entries;

  @override
  Future<SourceEntry> stat(String path) async =>
      entries.firstWhere((entry) => entry.path == path);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();

  @override
  Future<void> close() async {}
}

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (done()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail(
    'Directory listing and its worker did not finish. Visible text: '
    '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
  );
}

class _Fixture {
  late Directory root;
  late AppStore store;
  late _Model model;

  Future<void> mount(
    WidgetTester tester, {
    required bool disk,
    int fourthEpisode = 4,
    bool extra = false,
    bool ai = false,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('source-identity-count-');
      store = AppStore(disk ? '${root.path}/library.db' : ':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final entries = _listing(extra: extra);
      for (var index = 0; index < (ai ? 0 : (extra ? 3 : 4)); index++) {
        final entry = entries[index];
        final id = 'episode-${index + 1}';
        store.save('media', id, {
          'fileName': entry.name,
          'title': entry.name,
          'series': _folder,
          'season': '1',
          'episode': '${index == 3 ? fourthEpisode : index + 1}',
          ...subjectMediaFields(_subject),
        });
        store.setLocal('location:$id', {
          'id': id,
          'source': 'nas',
          'path': entry.path,
          'size': entry.size,
          'modified': entry.modified,
        });
      }
      model = ai
          ? _AiModel(store, root, entries)
          : _Model(store, root, entries);
      await model.loadLibrarySnapshot();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SourceBrowser(
          model: model,
          source: const {'id': 'nas', 'kind': 'webdav'},
        ),
      ),
    );
    await _settle(tester, () => model.completedCollections > 0);
  }

  Future<void> refresh(WidgetTester tester, {bool parent = true}) async {
    final completed = model.completedCollections;
    var done = false;
    unawaited(
      tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh()
          .then((_) => done = true),
    );
    await _settle(
      tester,
      () => done && (!parent || model.completedCollections > completed),
    );
  }

  Future<void> enter(WidgetTester tester) async {
    final completed = model.completedListings;
    await tester.tap(find.byKey(const ValueKey(_folder)));
    await _settle(
      tester,
      () =>
          model.completedListings > completed &&
          find.byType(MediaDetailsOverview).evaluate().isNotEmpty,
    );
  }

  Future<void> back(WidgetTester tester) async {
    final completed = model.completedCollections;
    await tester.tap(find.byTooltip('返回'));
    await _settle(tester, () => model.completedCollections > completed);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    });
  }
}

void main() {
  for (final disk in [false, true]) {
    final storage = disk ? 'worker database' : 'memory database';

    testWidgets(
      '$storage keeps the complete AI episode list before and after import',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester, disk: disk, ai: true);
          final model = fixture.model as _AiModel;
          expect(find.text('4 集'), findsOneWidget);
          expect(fixture.store.records('media'), isEmpty);
          expect(model.aiCalls, 1);
          await fixture.refresh(tester);
          expect(find.text('4 集'), findsOneWidget);
          expect(fixture.store.records('media'), isEmpty);
          expect(model.aiCalls, 1);
          await fixture.enter(tester);
          await _settle(
            tester,
            () =>
                fixture.store.records('media').length == 4 &&
                find.textContaining('已收录 4 集').evaluate().isNotEmpty,
          );
          expect(
            fixture.model
                .sourceMedia('nas', '$_folder/opaque-final.mkv')
                ?.data['episode'],
            '4',
          );
          await fixture.back(tester);
          expect(find.text('4 集'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );

    testWidgets(
      '$storage counts a verified opaque fourth episode across navigation',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester, disk: disk);
          expect(find.text('4 集'), findsOneWidget);
          expect(fixture.store.get('media', 'episode-4')!.data['episode'], '4');
          await fixture.refresh(tester);
          expect(find.text('4 集'), findsOneWidget);
          await fixture.enter(tester);
          expect(find.textContaining('已收录 4 集'), findsOneWidget);
          expect(fixture.store.get('media', 'episode-4')!.data['episode'], '4');
          await fixture.back(tester);
          expect(find.text('4 集'), findsOneWidget);
          await fixture.refresh(tester);
          expect(find.text('4 集'), findsOneWidget);
          expect(fixture.store.records('media'), hasLength(4));
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );

    testWidgets(
      '$storage updates a corrected episode without changing the file listing',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester, disk: disk, fourthEpisode: 3);
          expect(find.text('3 集 · 4 个视频'), findsOneWidget);
          await fixture.enter(tester);
          expect(find.textContaining('已收录 3 集'), findsOneWidget);
          await tester.runAsync(() async {
            final record = fixture.store.get('media', 'episode-4')!;
            fixture.store.save('media', record.id, {
              ...record.data,
              'episode': '4',
            });
            fixture.store.setLocal('manualMetadata:${record.id}', true);
            fixture.model.changed();
          });
          await fixture.refresh(tester, parent: false);
          expect(find.textContaining('已收录 4 集'), findsOneWidget);
          await fixture.back(tester);
          expect(find.text('4 集'), findsOneWidget);
          await fixture.refresh(tester);
          expect(find.text('4 集'), findsOneWidget);
          expect(fixture.store.get('media', 'episode-4')!.data['episode'], '4');
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );

    testWidgets(
      '$storage reports an unrecognized extra video without inventing episode four',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester, disk: disk, extra: true);
          expect(find.text('4 个视频'), findsOneWidget);
          expect(find.text('4 集'), findsNothing);
          await fixture.refresh(tester);
          expect(find.text('4 个视频'), findsOneWidget);
          await fixture.enter(tester);
          expect(find.textContaining('已收录 4 集'), findsNothing);
          await fixture.back(tester);
          expect(find.text('4 个视频'), findsOneWidget);
          expect(
            fixture.store
                .records('media')
                .where((record) => record.data['episode'] == '4'),
            isEmpty,
          );
          expect(fixture.model.sourceMedia('nas', '$_folder/花絮.mkv'), isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }
}
