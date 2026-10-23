import 'dart:io';
import 'dart:isolate';

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
  for (final (count, mixed) in [(2, false), (300, false), (2, true)]) {
    testWidgets(
      'first open uses verified identities for $count opaque filenames, mixed=$mixed',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        late Directory root, folder;
        late AppStore store;
        late _ObservedModel model;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('known-first-open-');
          folder = await Directory('${root.path}/Series').create();
          store = AppStore('${root.path}/library.db')
            ..setLocal('settings', {'metadataStrategy': 'off'});
          for (var episode = 1; episode <= count; episode++) {
            // These names deliberately carry no parsable episode evidence.
            // Existing verified identities are sufficient; playback is not.
            final name = 'filename$episode.mkv';
            await File('${folder.path}/$name').writeAsBytes([1]);
            store.save('media', '$episode', {
              'title': name,
              'fileName': name,
              'series': 'Series',
              'season': '1',
              'episode': '$episode',
              'bangumiId': mixed ? '$episode' : '7',
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
            expect(overview.details.availableEpisodes, count);
            expect(overview.records, hasLength(count));
          }
          expect(plays, 0);
          expect(store.records('progress'), isEmpty);
          expect(store.all('media'), hasLength(count));
          final snapshot = (await tester.runAsync(
            () => model.loadLibrarySnapshot(),
          ))!;
          expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
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
