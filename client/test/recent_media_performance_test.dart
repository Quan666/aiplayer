import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _HistoryStore store;
  late AppModel model;

  setUp(() {
    store = _HistoryStore();
    model = AppModel(store, Directory.systemTemp, backgroundWork: false);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
  });

  SyncRecord add(String id, {Map<String, dynamic> data = const {}}) {
    store.save('media', id, {'title': id, ...data});
    return store.get('media', id)!;
  }

  void progress(
    String id, {
    int position = 10,
    String updatedAt = '2026-10-23T00:00:00Z',
    bool deleted = false,
  }) => store.save('progress', id, {
    'position': position,
    'updatedAt': updatedAt,
  }, deleted: deleted);

  test('large history uses two batch reads and no per-video SQLite reads', () {
    for (var i = 0; i < 1000; i++) {
      add('$i');
      if (i % 100 == 0) progress('$i:0');
    }
    final items = model.media;
    store.resetReads();

    final recent = model.recentMedia(items: items, groupSeries: false);

    expect(recent, hasLength(10));
    expect(store.recordReads, 0);
    expect(store.localReads, 0);
    expect(store.progressBatches, 1);
    expect(store.locationBatches, 1);
  });

  test('history follows local file size, metadata size and zero fallback', () {
    final associated = add('a:version', data: {'size': 100});
    final metadata = add('metadata', data: {'size': 200});
    final zero = add('zero');
    store.setLocal('location:${associated.id}', {'size': 300});
    store.setLocal('location:${metadata.id}', {'source': 'nas'});
    progress('${associated.id}:100', updatedAt: '2026-10-24T00:00:00Z');
    progress('${associated.id}:300', updatedAt: '2026-10-21T00:00:00Z');
    progress('${metadata.id}:200', updatedAt: '2026-10-22T00:00:00Z');
    progress('${zero.id}:0');

    expect(model.recentMedia().map((item) => item.id), [
      zero.id,
      metadata.id,
      associated.id,
    ]);
    store.setLocal('location:${associated.id}', {'size': 0});
    expect(model.recentMedia().map((item) => item.id), [zero.id, metadata.id]);
    progress('${associated.id}:0', updatedAt: '2026-10-25T00:00:00Z');
    expect(model.recentMedia().first.id, associated.id);
    store.removeLocal('location:${associated.id}');
    expect(model.recentMedia().first.id, associated.id);
  });

  test('history omits deleted, transient, unwatched and orphaned videos', () {
    add('visible');
    add('tombstoned');
    add('unwatched');
    add('negative');
    add('temporary', data: {'transient': true});
    store.save('media', 'deleted', {'title': 'deleted'}, deleted: true);
    progress('visible:0');
    progress('tombstoned:0', deleted: true);
    progress('temporary:0');
    progress('deleted:0');
    progress('orphan:0');
    progress('unwatched:0', position: 0);
    progress('negative:0', position: -1);

    expect(model.recentMedia().map((item) => item.id), ['visible']);
    progress('tombstoned:0', updatedAt: '2026-10-24T00:00:00Z');
    expect(model.recentMedia().map((item) => item.id), [
      'tombstoned',
      'visible',
    ]);
  });

  test('history keeps timestamp order and ID ties before series grouping', () {
    final older = add('z', data: {'series': 'Series', 'episode': '1'});
    final newest = add('a', data: {'series': 'Series', 'episode': '2'});
    final separate = add('b');
    final missingTime = add('missing');
    progress('z:0', updatedAt: '2026-10-22T00:00:00Z');
    progress('b:0');
    progress('a:0');
    store.save('progress', 'missing:0', {'position': 1});
    final items = [older, separate, missingTime, newest];

    expect(
      model
          .recentMedia(items: items, groupSeries: false)
          .map((item) => item.id),
      ['a', 'b', 'z', 'missing'],
    );
    expect(model.recentMedia(items: items).map((item) => item.id), [
      'a',
      'b',
      'missing',
    ]);
    expect(model.recentMedia(items: [separate]).single.id, separate.id);
  });
}

class _HistoryStore extends AppStore {
  int recordReads = 0, localReads = 0, progressBatches = 0, locationBatches = 0;
  _HistoryStore() : super(':memory:');

  void resetReads() {
    recordReads = localReads = progressBatches = locationBatches = 0;
  }

  @override
  SyncRecord? get(String kind, String id) {
    recordReads++;
    return super.get(kind, id);
  }

  @override
  dynamic local(String key) {
    localReads++;
    return super.local(key);
  }

  @override
  List<SyncRecord> records(String kind) {
    if (kind == 'progress') progressBatches++;
    return super.records(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    if (prefix == 'location:') locationBatches++;
    return super.localEntries(prefix);
  }
}
