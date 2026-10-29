import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _folder = SourceEntry(name: '混合文件夹', path: 'Collection', directory: true);
const _movie = SourceEntry(
  name: 'Current.mp4',
  path: 'Collection/Current.mp4',
  size: 10,
);
const _unrelatedFolders = [
  SourceEntry(name: '另一部电影', path: 'Collection/OtherMovie', directory: true),
  SourceEntry(name: '另一部剧集', path: 'Collection/OtherSeries', directory: true),
];
const _unrelatedVideos = [
  SourceEntry(
    name: 'Other Movie.mp4',
    path: 'Collection/Other Movie.mp4',
    size: 20,
  ),
  SourceEntry(
    name: 'Different Series S01E01.mkv',
    path: 'Collection/Different Series S01E01.mkv',
    size: 30,
  ),
];
const _opaqueEpisodes = [
  SourceEntry(name: 'opaque-a.mkv', path: 'Collection/opaque-a.mkv', size: 10),
  SourceEntry(name: 'opaque-b.mkv', path: 'Collection/opaque-b.mkv', size: 20),
];

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);

  List<SourceEntry> entries = const [_movie];
  final listings = <String>[];

  @override
  Future<SourceAdapter> adapter(String id) async => _Source(this);
}

class _Source extends SourceAdapter {
  _Source(this.model);
  final _Model model;

  @override
  Future<List<SourceEntry>> list(String path) async {
    model.listings.add(path);
    return switch (path) {
      '' => const [_folder],
      'Collection' => List.of(model.entries),
      _ => const [],
    };
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      model.entries.firstWhere((entry) => entry.path == path);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _Fixture {
  _Fixture(this.root, this.store, this.model, this.id);
  final Directory root;
  final AppStore store;
  final _Model model;
  final String id;

  static _Fixture create({bool series = false}) {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('mixed-collection-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _Model(store, root);
    model.entries = series ? _opaqueEpisodes : const [_movie];
    final ids = <String>[];
    for (var index = 0; index < model.entries.length; index++) {
      final id = model.addMedia('nas', model.entries[index]);
      ids.add(id);
      store.save('media', id, {
        ...store.get('media', id)!.data,
        if (series) ...{
          'series': 'Shared Series',
          'season': '1',
          'episode': '${index + 1}',
          'bangumiId': '7',
          'metadataTitle': '同一剧集',
        } else ...{
          'tmdbId': '7',
          'metadataType': 'movie',
          'metadataTitle': '已识别电影',
        },
      });
    }
    return _Fixture(root, store, model, ids.first);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: SourceBrowser(
          model: model,
          source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(_folder.path)));
    await tester.pumpAndSettle();
    expect(model.listings, contains(_folder.path));
    expect(find.byKey(ValueKey(model.entries.first.path)), findsOneWidget);
  }

  Future<void> changeMetadata(WidgetTester tester) async {
    store.save('media', id, {
      ...store.get('media', id)!.data,
      'metadataTitle': '更新后的电影资料',
    });
    model.changed();
    await tester.pumpAndSettle();
    expect(find.text('更新后的电影资料'), findsOneWidget);
  }

  Future<void> reopen(WidgetTester tester) async {
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaDetailsOverview), findsNothing);
    expect(find.text(_folder.name), findsOneWidget);
    await tester.tap(find.text(_folder.name));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  }
}

Future<void> _refresh(WidgetTester tester) async {
  final refresh = tester
      .widget<RefreshIndicator>(find.byType(RefreshIndicator))
      .onRefresh();
  await tester.pumpAndSettle();
  await refresh;
  await tester.pumpAndSettle();
}

void _expectMixedFolder(WidgetTester tester) {
  expect(find.byType(MediaDetailsOverview), findsNothing);
  expect(find.text(_folder.name), findsOneWidget);
  expect(find.byKey(ValueKey(_movie.path)), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final conflict in ['provider identity', 'season']) {
    testWidgets(
      'metadata notification removes a collection with conflicting $conflict',
      (tester) async {
        final fixture = _Fixture.create(series: true);
        // A manually matched first episode must not hide a verified conflict
        // in another file when the directory's metadata changes.
        fixture.store.setLocal('manualMetadata:${fixture.id}', true);
        try {
          await fixture.open(tester);
          final overview = tester.widget<MediaDetailsOverview>(
            find.byType(MediaDetailsOverview),
          );
          expect(overview.details.title, '同一剧集');
          expect(overview.records, hasLength(2));

          final second = fixture.model.sourceMedia(
            'nas',
            _opaqueEpisodes.last.path,
          )!;
          final changedTitle = conflict == 'season' ? '另一季' : '另一部剧集';
          fixture.store.save('media', second.id, {
            ...second.data,
            'bangumiId': conflict == 'season' ? '7' : '99',
            'season': conflict == 'season' ? '2' : '1',
            'metadataTitle': changedTitle,
          });
          fixture.model.changed();
          await tester.pumpAndSettle();

          void expectSeparateFiles() {
            expect(find.byType(MediaDetailsOverview), findsNothing);
            expect(find.text(_folder.name), findsOneWidget);
            expect(find.textContaining('同一剧集'), findsOneWidget);
            expect(find.textContaining(changedTitle), findsOneWidget);
            for (final entry in _opaqueEpisodes) {
              expect(find.byKey(ValueKey(entry.path)), findsOneWidget);
            }
            expect(
              fixture.store.get('media', fixture.id)!.data['bangumiId'],
              '7',
            );
            expect(
              fixture.store.get('media', second.id)!.data['metadataTitle'],
              changedTitle,
            );
            expect(tester.takeException(), isNull);
          }

          expectSeparateFiles();
          await _refresh(tester);
          expectSeparateFiles();
          await fixture.reopen(tester);
          expectSeparateFiles();
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  for (final (description, siblings) in [
    ('unrelated subfolders', _unrelatedFolders),
    ('unrelated videos', _unrelatedVideos),
  ]) {
    testWidgets(
      'one identified movie does not represent a folder with $description',
      (tester) async {
        final fixture = _Fixture.create();
        fixture.model.entries = [_movie, ...siblings];
        try {
          await fixture.open(tester);
          _expectMixedFolder(tester);

          // Only the movie is imported. A metadata update must not treat this
          // partial library snapshot as the directory's complete membership.
          await fixture.changeMetadata(tester);
          _expectMixedFolder(tester);
          await _refresh(tester);
          _expectMixedFolder(tester);
          await fixture.reopen(tester);
          _expectMixedFolder(tester);
          expect(fixture.store.records('progress'), isEmpty);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets(
    'a single movie keeps details until the directory becomes mixed',
    (tester) async {
      final fixture = _Fixture.create();
      try {
        await fixture.open(tester);
        expect(find.byType(MediaDetailsOverview), findsOneWidget);
        expect(
          tester
              .widget<MediaDetailsOverview>(find.byType(MediaDetailsOverview))
              .details
              .title,
          '已识别电影',
        );

        // A fresh mixed listing must replace a previously valid collection,
        // including its cached header and its poster in the parent directory.
        fixture.model.entries = [_movie, ..._unrelatedFolders];
        await _refresh(tester);
        _expectMixedFolder(tester);
        await fixture.changeMetadata(tester);
        _expectMixedFolder(tester);
        await fixture.reopen(tester);
        _expectMixedFolder(tester);
        expect(fixture.store.records('progress'), isEmpty);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}
