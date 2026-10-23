import 'dart:io';

import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final verified in [false, true]) {
    for (final folder in ['已改名文件夹', 'S02', '']) {
      test(
        '${verified ? 'identified' : 'parsed'} anchor completes numeric siblings in "$folder"',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'anchor-completion-',
          );
          final store = AppStore('${root.path}/library.db');
          final worker = DirectoryMetadataWorker(store.path);
          String path(String name) => folder.isEmpty ? name : '$folder/$name';
          final entries = [
            for (final name in [
              'Original Show S02E01.mkv',
              '02.mkv',
              'S02E03.mkv',
              'Original Show S02E04.mkv',
              'Another Show S02E05.mkv',
              '06.mkv',
            ])
              SourceEntry(name: name, path: path(name)),
          ];
          try {
            store.save('media', 'anchor', {
              'title': entries.first.name,
              'fileName': entries.first.name,
              'series': verified ? '识别后的名称' : 'Original Show',
              'season': '2',
              'episode': '1',
              if (verified) 'bangumiId': '42',
              if (verified) 'metadataTitle': '识别后的名称',
            });
            store.setLocal('location:anchor', {
              'id': 'anchor',
              'source': 'nas',
              'path': entries.first.path,
            });
            store.save('media', 'foreign', {
              'fileName': entries.last.name,
              'series': 'Unrelated identified show',
              'season': '2',
              'episode': '6',
              'bangumiId': '99',
            });
            store.setLocal('location:foreign', {
              'id': 'foreign',
              'source': 'nas',
              'path': entries.last.path,
            });
            store.setLocal('manualMetadata:foreign', true);
            final result = await worker.synchronizeListing(
              'nas',
              folder,
              entries,
              anchorId: 'anchor',
              hideHidden: true,
            );
            expect(result?.collection.videos.map((entry) => entry.name), [
              'Original Show S02E01.mkv',
              '02.mkv',
              'S02E03.mkv',
              'Original Show S02E04.mkv',
            ]);
            expect(result?.mediaIds, hasLength(4));
            final records = result!.mediaIds.map(
              (id) => store.get('media', id)!,
            );
            expect(records.map((record) => record.data['episode']), [
              '1',
              '2',
              '3',
              '4',
            ]);
            expect(records.map((record) => record.data['season']).toSet(), {
              '2',
            });
            expect(records.map((record) => record.data['series']).toSet(), {
              verified ? '识别后的名称' : 'Original Show',
            });
            expect(store.get('media', 'foreign')!.data['bangumiId'], '99');
            expect(store.records('media'), hasLength(5));
            expect(store.records('progress'), isEmpty);
          } finally {
            await worker.close();
            store.dispose();
            await root.delete(recursive: true);
          }
        },
      );
    }
  }

  test(
    'verified aliases and opaque siblings keep their saved identity',
    () async {
      final root = await Directory.systemTemp.createTemp('anchor-aliases-');
      final store = AppStore('${root.path}/library.db');
      final worker = DirectoryMetadataWorker(store.path);
      final entries = [
        for (final name in [
          'Original Show E01.mkv',
          '译名 E02.mkv',
          'Display Name S02E03.mkv',
          'opaque.mkv',
          'Original Show S03E05.mkv',
          'unknown.mkv',
        ])
          SourceEntry(name: name, path: 'renamed/$name'),
      ];
      try {
        for (final (id, index, episode) in [
          ('anchor', 0, '1'),
          ('opaque', 3, '4'),
        ]) {
          store.save('media', id, {
            'fileName': entries[index].name,
            'series': 'Display Name',
            'season': '2',
            'episode': episode,
            'bangumiId': '42',
            'metadataTitle': '译名',
            if (id == 'opaque') 'episodeTitle': '已保存的第四集',
          });
          store.setLocal('location:$id', {
            'id': id,
            'source': 'nas',
            'path': entries[index].path,
          });
        }
        final result = await worker.synchronizeListing(
          'nas',
          'renamed',
          entries,
          anchorId: 'anchor',
          hideHidden: true,
        );
        expect(result?.mediaIds, hasLength(4));
        expect(
          result?.collection.videos.map((entry) => entry.name),
          entries.take(4).map((entry) => entry.name),
        );
        expect(
          result?.collection.identities.values.map(
            (identity) => identity.episode,
          ),
          ['1', '2', '3', '4'],
        );
        expect(result?.collection.episodeTitles['4'], '已保存的第四集');
        expect(store.get('media', 'opaque')!.data['episode'], '4');
        expect(store.records('media'), hasLength(4));
      } finally {
        await worker.close();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
