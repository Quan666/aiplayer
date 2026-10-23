import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/playlist.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CountingStore store;
  late AppModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = _CountingStore();
    model = AppModel(store, Directory.systemTemp, backgroundWork: false);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
  });

  SyncRecord episode(String id, String number, {String series = 'Example'}) {
    store.save('media', id, {
      'series': series,
      'episode': number,
      'title': '$series $number.mp4',
    });
    store.setLocal('location:$id', {
      'source': 'webdav',
      'path': '/$series/$id.mp4',
    });
    return store.get('media', id)!;
  }

  test(
    'revealing controls reuses indexed playlists without library queries',
    () {
      for (var i = 0; i < 2000; i++) {
        episode('$i', '${i % 100}', series: 'Series ${i ~/ 100}');
      }
      final first = store.get('media', '0')!;
      store.mediaReads = store.locationReads = store.singleLocationReads = 0;
      final items = playbackPlaylist(model, first);
      expect(items, hasLength(100));
      final next = items[1];
      for (var i = 0; i < 100; i++) {
        store.save('progress', 'test', {'position': i});
        store.setLocal('lastSync', i);
        expect(playbackPlaylist(model, first), same(items));
        expect(playbackPlaylist(model, next), same(items));
      }
      expect(store.mediaReads, 1);
      expect(store.locationReads, 1);
      expect(store.singleLocationReads, 0);
      expect(() => items.clear(), throwsUnsupportedError);
    },
  );

  test('library changes invalidate ordering, additions and removed files', () {
    final first = episode('one', '1');
    episode('ten', '10');
    episode('two', '2');
    List<String> ids() =>
        playbackPlaylist(model, first).map((e) => e.id).toList();
    expect(ids(), ['one', 'two', 'ten']);
    episode('three', '3');
    expect(ids(), ['one', 'two', 'three', 'ten']);
    store.removeLocal('location:two');
    expect(ids(), ['one', 'three', 'ten']);
    store.save('media', 'ten', {
      ...store.get('media', 'ten')!.data,
      'episode': '0',
    });
    expect(ids(), ['ten', 'one', 'three']);
    // Other desktop engines can update the same database directly.
    store.db.execute("DELETE FROM local WHERE key='location:three'");
    expect(ids(), ['ten', 'one']);
  });

  test('standalone files keep source and directory grouping', () {
    const file = SyncRecord(
      id: 'movie',
      kind: 'media',
      data: {'title': 'Movie'},
    );
    store.save('media', file.id, file.data);
    store.setLocal('location:movie', {
      'source': 'webdav',
      'path': '/Example/movie.mkv',
    });
    episode('episode', '1');
    final other = episode('other', '1', series: 'Other');
    store.setLocal('location:other', {
      'source': 'smb',
      'path': '/Example/other.mp4',
    });
    expect(playbackPlaylist(model, file).map((e) => e.id), [
      'movie',
      'episode',
    ]);
    store.removeLocal('location:movie');
    expect(playbackPlaylist(model, file).map((e) => e.id), ['movie']);
    store.removeLocal('location:other');
    expect(playbackPlaylist(model, other).map((e) => e.id), ['other']);
  });

  test(
    'duplicate episode records keep one destination and the active version',
    () {
      final first = episode('first', '1');
      final older = episode('old-two', '02');
      final detailed = episode('new-two', '2.0');
      store.save('media', detailed.id, {
        ...detailed.data,
        'season': '01.0',
        'episodeTitle': '开始攻打堡垒',
      });
      episode('third', '3');
      store.save('progress', model.progressKey(older), {'position': 60});
      final items = playbackPlaylist(model, first);
      expect(items.map((item) => item.id), ['first', 'new-two', 'third']);
      final selected = playbackPlaylist(model, older);
      expect(selected.map((item) => item.id), ['first', 'old-two', 'third']);
      expect(playbackPlaylist(model, older), same(selected));
      expect(
        store.get('progress', model.progressKey(older))!.data['position'],
        60,
      );
      expect(store.all('media'), hasLength(4));
    },
  );
}

class _CountingStore extends AppStore {
  _CountingStore() : super(':memory:');
  int mediaReads = 0, locationReads = 0, singleLocationReads = 0;
  @override
  List<SyncRecord> all(String kind) {
    if (kind == 'media') mediaReads++;
    return super.all(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    if (prefix == 'location:') locationReads++;
    return super.localEntries(prefix);
  }

  @override
  dynamic local(String key) {
    if (key.startsWith('location:')) singleLocationReads++;
    return super.local(key);
  }
}
