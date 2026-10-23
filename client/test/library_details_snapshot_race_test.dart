import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CommitOnDetailsPush extends NavigatorObserver {
  final VoidCallback commit;
  _CommitOnDetailsPush(this.commit);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) commit();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('details adopt episodes committed after the card snapshot', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('details-snapshot-race-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = AppModel(store, root, backgroundWork: false);
    addTearDown(() {
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    });
    void saveEpisode(int episode) {
      store.save('media', 'episode-$episode', {
        'title': 'Example S01E0$episode.mkv',
        'fileName': 'Example S01E0$episode.mkv',
        'series': 'Example',
        'season': '1',
        'episode': '$episode',
        'bangumiId': '7',
      });
    }

    saveEpisode(1);
    final observer = _CommitOnDetailsPush(() {
      // A sync or metadata worker can commit while the modal route is being
      // opened. This is a real AppModel: no mocked episode loader or snapshot.
      saveEpisode(2);
      model.changed();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        navigatorObservers: [observer],
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('details:episode-1')));
    await tester.pumpAndSettle();

    final current = await model.loadLibrarySnapshot();
    expect(current.episodesFor(current.byId['episode-1']!), hasLength(2));
    final overview = tester.widget<MediaDetailsOverview>(
      find.byType(MediaDetailsOverview),
    );
    expect(overview.records.map((record) => record.id), [
      'episode-1',
      'episode-2',
    ]);
    expect(find.textContaining('已收录 2 集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
