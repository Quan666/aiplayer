import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (relative, firstName) in [
    ('Show', '01.mkv'),
    ('Show/Season 1', '01.mkv'),
    ('Show/S01', '01.mkv'),
    ('Show/第1季', '01.mkv'),
    ('Show/S01', 'Show S01E01.mkv'),
  ]) {
    test(
      'identified $firstName in $relative completes from real files',
      () async {
        final root = await Directory.systemTemp.createTemp('series-numeric-');
        final store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        final model = AppModel(store, root, backgroundWork: false);
        try {
          final folder = await Directory(
            '${root.path}/$relative',
          ).create(recursive: true);
          final entries = <SourceEntry>[];
          for (var episode = 1; episode <= 3; episode++) {
            final name = episode == 1 ? firstName : '0$episode.mkv';
            final file = await File(
              '${folder.path}/$name',
            ).writeAsBytes([episode]);
            entries.add(await LocalSource().stat(file.path));
          }
          final id = model.addMedia('local', entries.first);
          final seed = store.get('media', id)!;
          store.save('media', id, {
            ...seed.data,
            'series': 'Identified Show',
            'season': '1',
            'episode': '1',
            'bangumiId': '123',
            'metadataTitle': 'Identified Show',
          });
          final loaded = await model.loadSeriesEpisodes(
            store.get('media', id)!,
          );
          expect(loaded.map((record) => record.data['episode']), [
            '1',
            '2',
            '3',
          ]);
          expect(
            loaded.every((record) => record.data['bangumiId'] == '123'),
            isTrue,
          );
          expect(store.records('progress'), isEmpty);
        } finally {
          model.dispose();
          store.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'numeric completion preserves foreign matches and removed episodes',
    () async {
      final root = await Directory.systemTemp.createTemp('series-numeric-');
      final store = AppStore('${root.path}/library.db')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, root, backgroundWork: false);
      try {
        final folder = await Directory(
          '${root.path}/Show/S01',
        ).create(recursive: true);
        final entries = <SourceEntry>[];
        for (var episode = 1; episode <= 4; episode++) {
          final file = await File(
            '${folder.path}/0$episode.mkv',
          ).writeAsBytes([episode]);
          entries.add(await LocalSource().stat(file.path));
        }
        final selected = model.addMedia('local', entries.first);
        final foreign = model.addMedia('local', entries[1]);
        for (final (id, series, subject, episode) in [
          (selected, 'Identified Show', '123', '1'),
          (foreign, 'Another Show', '456', '2'),
        ]) {
          final record = store.get('media', id)!;
          store.save('media', id, {
            ...record.data,
            'series': series,
            'season': '1',
            'episode': episode,
            'bangumiId': subject,
          });
        }
        final removed = model.addMedia('local', entries[2]);
        await model.removeMedia(store.get('media', removed)!);

        final loaded = await model.loadSeriesEpisodes(
          store.get('media', selected)!,
        );
        expect(loaded.map((record) => record.data['episode']), ['1', '4']);
        expect(store.get('media', foreign)!.data['bangumiId'], '456');
        expect(store.get('media', removed)!.deleted, isTrue);
        expect(store.records('progress'), isEmpty);
      } finally {
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
