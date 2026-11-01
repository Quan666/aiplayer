import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _ObservedModel extends AppModel {
  int completedListings = 0;

  _ObservedModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final collection = await super.synchronizeDirectoryEntriesInBackground(
      sourceId,
      path,
      entries,
      anchorId: anchorId,
      cancel: cancel,
    );
    completedListings++;
    return collection;
  }
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (ready()) return;
  }
  fail('Timed out waiting for $description.');
}

void main() {
  for (final (count, mixed, movie) in [
    (2, false, false),
    (300, false, false),
    (2, true, false),
    (2, false, true),
    (2, true, true),
  ]) {
    testWidgets(
      'first open uses verified identities for $count files, mixed=$mixed, movie=$movie',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        late Directory root, folder;
        late AppStore store;
        late _ObservedModel model;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('known-first-open-');
          final title = movie ? 'GROTESQQQUE -グロテスク-' : 'Series';
          folder = await Directory('${root.path}/$title').create();
          store = AppStore('${root.path}/library.db')
            ..setLocal('settings', {'metadataStrategy': 'off'});
          for (var episode = 1; episode <= count; episode++) {
            // Neither opaque episode names nor movie versions have episode
            // evidence; verified identities must make their details available.
            final name = movie
                ? '$title [北宇治字幕组] [${episode == 1 ? '简体' : '繁体'}].mkv'
                : 'filename$episode.mkv';
            await File('${folder.path}/$name').writeAsBytes([1]);
            // Recognizing one version must import its unrecognized sibling.
            if (movie && !mixed && episode == 2) continue;
            store.save('media', '$episode', {
              'title': name,
              'fileName': name,
              'series': title,
              'season': movie ? '' : '1',
              'episode': movie ? '' : '$episode',
              'bangumiId': mixed ? '$episode' : '7',
              if (movie) 'metadataType': 'movie',
              'metadataTitle': '已识别系列',
            });
            store.setLocal('location:$episode', {
              'id': '$episode',
              'source': 'local',
              'path': '${folder.path}/$name',
              'size': 1,
            });
          }
          model = _ObservedModel(store, root);
          await model.loadLibrarySnapshot();
        });
        var plays = 0;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: GlassPalette.theme(),
              home: SourceBrowser(
                model: model,
                source: const {
                  'id': 'local',
                  'kind': 'local',
                  'label': 'Local',
                },
                initialPath: folder.path,
                onPlay: (_) async => plays++,
              ),
            ),
          );
          await _wait(
            tester,
            () => model.completedListings > 0,
            'the source listing',
          );
          if (!mixed) {
            await _wait(
              tester,
              () => find.byType(MediaDetailsOverview).evaluate().isNotEmpty,
              'the worker-prepared collection details',
            );
          }
          await tester.pumpAndSettle();
          expect(
            find.byType(MediaDetailsOverview),
            mixed ? findsNothing : findsOneWidget,
          );
          if (!mixed) {
            final overview = tester.widget<MediaDetailsOverview>(
              find.byType(MediaDetailsOverview),
            );
            expect(overview.details.title, '已识别系列');
            expect(overview.details.availableEpisodes, movie ? 0 : count);
            expect(overview.details.videoCount, count);
            expect(overview.records, hasLength(count));
          }
          expect(plays, 0);
          expect(store.records('progress'), isEmpty);
          expect(store.all('media'), hasLength(count));
          final snapshot = (await tester.runAsync(
            () => model.loadLibrarySnapshot(),
          ))!;
          expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
          if (movie && !mixed) {
            final versions = store.records('media');
            for (final item in versions) {
              final filename = '${item.data['fileName']}';
              expect(
                find.descendant(
                  of: find.byKey(ValueKey('${folder.path}/$filename')),
                  matching: find.text(filename),
                ),
                findsOneWidget,
              );
            }
            // Library details must keep the same visible version labels as
            // source details, while their overview keeps the official title.
            final sheet = showLibraryMediaDetails(
              tester.element(find.byType(SourceBrowser)),
              model: model,
              snapshot: snapshot,
              anchor: versions.first,
              onPlay: (_) => plays++,
            );
            await tester.pumpAndSettle();
            for (final item in versions) {
              expect(
                find.descendant(
                  of: find.byKey(ValueKey('series-episode:${item.id}')),
                  matching: find.text('${item.data['fileName']}'),
                ),
                findsOneWidget,
              );
            }
            final overview = tester.widget<MediaDetailsOverview>(
              find.descendant(
                of: find.byKey(const ValueKey('series-details-list')),
                matching: find.byType(MediaDetailsOverview),
              ),
            );
            expect(overview.details.title, '已识别系列');
            Navigator.of(
              tester.element(find.byKey(const ValueKey('series-details-list'))),
            ).pop();
            await sheet;
            await tester.pumpAndSettle();
            expect(plays, 0);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            model.dispose();
            store.dispose();
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
