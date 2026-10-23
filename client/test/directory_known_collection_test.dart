import 'dart:io';

import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final count in [2, 300]) {
    test(
      'worker restores $count identified files without parsing their names',
      () async {
        final root = await Directory.systemTemp.createTemp('known-directory-');
        final store = AppStore('${root.path}/library.db');
        final worker = DirectoryMetadataWorker(store.path);
        final entries = <SourceEntry>[];
        try {
          store.transaction(() {
            for (var i = 1; i <= count; i++) {
              final name = 'opaque${i.toRadixString(16)}.mkv';
              final path = 'folder/$name';
              entries.add(SourceEntry(name: name, path: path, size: 1));
              store.save('media', '$i', {
                'fileName': name,
                'title': name,
                'series': 'Identified series',
                'season': '2',
                'episode': '$i',
                ...subjectMediaFields({
                  'provider': 'bangumi',
                  'id': '42',
                  'name': '识别后的系列',
                }),
                'episodeTitle': '第 $i 集标题',
              });
              store.setLocal('location:$i', {
                'id': '$i',
                'source': 'nas',
                'path': path,
                'size': 1,
              });
              store.setLocal('episodeTitle:$i', '第 $i 集标题');
            }
          });
          final before = store.recordsRevision('media');
          final result = await worker.synchronizeListing(
            'nas',
            'folder',
            entries,
            hideHidden: true,
          );
          expect(result?.collection.title, 'Identified series');
          expect(result?.collection.season, '2');
          expect(result?.collection.subject?['id'], '42');
          expect(result?.collection.videos, hasLength(count));
          expect(result?.collection.episodeCount, count);
          expect(
            result?.collection.identities[entries.last.path]?.episode,
            '$count',
          );
          expect(result?.collection.episodeTitles['$count'], '第 $count 集标题');
          expect(result?.changed, false);
          expect(store.recordsRevision('media'), before);
          expect(store.records('progress'), isEmpty);

          // A different verified work, a removed record, or a newly discovered
          // opaque file cannot inherit the first video's identity.
          final last = store.get('media', '$count')!;
          store.save('media', last.id, {...last.data, 'bangumiId': '99'});
          expect(
            await worker.synchronizeListing(
              'nas',
              'folder',
              entries,
              hideHidden: true,
            ),
            isNull,
          );
          store.save('media', last.id, last.data);
          store.save('media', last.id, last.data, deleted: true);
          expect(
            await worker.synchronizeListing(
              'nas',
              'folder',
              entries,
              hideHidden: true,
            ),
            isNull,
          );
          store.save('media', last.id, last.data);
          expect(
            await worker.synchronizeListing('nas', 'folder', [
              ...entries,
              const SourceEntry(
                name: 'unknown.mkv',
                path: 'folder/unknown.mkv',
              ),
            ], hideHidden: true),
            isNull,
          );
          expect(store.records('media'), hasLength(count));
        } finally {
          await worker.close();
          store.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
