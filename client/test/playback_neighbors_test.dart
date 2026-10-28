import 'dart:io';

import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/playlist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'worker prepares neighbors and observes other connection edits and rollback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'media-neighbors-',
      );
      final store = await AppStore.open('${directory.path}/library.db');
      try {
        for (var episode = 1; episode <= 4; episode++) {
          store.save('media', '$episode', {
            'title': 'Example $episode',
            'series': 'Example',
            'episode': '$episode',
          });
          store.setLocal('location:$episode', {
            'source': 'local',
            'path': '/Example/$episode.mp4',
          });
        }
        final current = store.get('media', '2')!;
        var neighbors = await playbackNeighbors(store.path, current);
        expect((neighbors.$1?.id, neighbors.$2?.id), ('1', '3'));
        final writer = AppStore.openExisting(store.path);
        try {
          writer.db.execute("DELETE FROM local WHERE key='location:3'");
          neighbors = await playbackNeighbors(store.path, current);
          expect((neighbors.$1?.id, neighbors.$2?.id), ('1', '4'));
          writer.db.execute('BEGIN IMMEDIATE');
          writer.db.execute("DELETE FROM local WHERE key='location:1'");
          // A separate WAL reader retains the committed snapshot, without
          // waiting synchronously for the writer on the rendering isolate.
          neighbors = await playbackNeighbors(store.path, current);
          expect(neighbors.$1?.id, '1');
          writer.db.execute('ROLLBACK');
          neighbors = await playbackNeighbors(store.path, current);
          expect(neighbors.$1?.id, '1');
        } finally {
          writer.dispose();
        }
        neighbors = await playbackNeighbors(
          store.path,
          store.get('media', '1')!,
        );
        expect(neighbors.$1, isNull);
        neighbors = await playbackNeighbors(
          store.path,
          store.get('media', '4')!,
        );
        expect(neighbors.$2, isNull);
      } finally {
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
