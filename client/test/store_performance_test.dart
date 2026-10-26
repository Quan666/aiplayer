import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unchanged local values do not write, mark edits or invalidate views', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    store.setLocal('settings', {'volume': 60, 'shortcuts': {'playPause': 'P'}});
    store.setLocal('location:v', {'id': 'v', 'source': 'nas', 'path': 'v.mkv'});
    final revision = store.localRevision;
    final edits = store.localEntries('syncModified:');
    final changes = store.db.select('SELECT total_changes() AS n').single['n'];
    for (var i = 0; i < 100; i++) {
      store.setLocal('settings', {'volume': 60, 'shortcuts': {'playPause': 'P'}});
      store.setLocal('location:v', {'id': 'v', 'source': 'nas', 'path': 'v.mkv'});
    }
    expect(store.db.select('SELECT total_changes() AS n').single['n'], changes);
    expect(store.localRevision, revision);
    expect(store.localEntries('syncModified:'), edits);
  });

  test('preferences survive unrelated writes and see edits, SQL and rollback', () {
    final store = AppStore(':memory:');
    final model = AppModel(store, Directory.systemTemp, backgroundWork: false);
    addTearDown(() {
      model.dispose();
      store.dispose();
    });
    store.setLocal('settings', {'volume': 60});
    final initial = model.preferences;
    for (var i = 0; i < 100; i++) {
      store.setLocal('preview:$i', {'path': '/$i.jpg'});
      expect(model.preferences, same(initial));
    }
    store.setLocal('settings', {'volume': 80});
    expect(model.preferences.volume, 80);
    expect(() => store.transaction(() {
      store.setLocal('settings', {'volume': 20});
      expect(model.preferences.volume, 20);
      throw StateError('rollback');
    }), throwsStateError);
    expect(model.preferences.volume, 80);
    store.db.execute('UPDATE local SET value=? WHERE key=?', ['{"volume":40}', 'settings']);
    expect(model.preferences.volume, 40);
    store.removeLocal('settings');
    expect(model.preferences.volume, 100);
  });

  test('prefix ranges keep literal wildcards, case and Unicode boundaries', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    const keys = ['a:', 'a:one', 'a;two', 'A:one', 'a%_[]:one', 'aXX:one', '影视:一', '影视:二', '影集:一', '\u{10ffff}', '\u{10ffff}last'];
    for (final key in keys) {
      store.setLocal('sync:$key', key);
    }
    for (final prefix in ['sync:a:', 'sync:a%_[]:', 'sync:影视:', 'sync:\u{10ffff}', 'sync:', 'missing:']) {
      expect(store.localEntries(prefix).keys.toSet(), {
        for (final key in keys) if ('sync:$key'.startsWith(prefix)) 'sync:$key',
      });
    }
    expect(store.localEntries('').keys, containsAll(keys.map((k) => 'sync:$k')));
  });

  test('targeted metadata changes never decode the unrelated library', () {
    final store = _CountingStore();
    final model = AppModel(store, Directory.systemTemp, backgroundWork: false);
    addTearDown(() {
      model.dispose();
      store.dispose();
    });
    store.save('media', 'target', {'series': 'Example', 'episode': '1'});
    store.db.execute('INSERT INTO records(kind,id,data) VALUES(?,?,?)',
        ['media', 'unrelated', 'not JSON']);
    model.applyBangumi('Example', {'id': '42', 'name': 'Official', 'type': 2}, mediaIds: {'target', 'missing'});
    expect(store.get('media', 'target')!.data['bangumiId'], '42');
    expect(store.mediaReads, 0);
  });

  test('startup repair yields and stops when a manual edit changes its donors', () async {
    final store = AppStore(':memory:');
    store.setLocal('settings', {'metadataStrategy': 'off'});
    store.save('media', 'donor', {
      'series': 'Example', 'episode': '1', 'bangumiId': '42',
    });
    for (var i = 0; i < 60; i++) {
      store.save('media', 'missing-$i', {'series': 'Example', 'episode': '${i + 2}'});
    }
    final model = AppModel(store, Directory.systemTemp, deferBackgroundWork: true);
    addTearDown(() {
      model.dispose();
      store.dispose();
    });
    var edited = false;
    model.addListener(() {
      if (edited) return;
      edited = true;
      final donor = store.get('media', 'donor')!;
      store.save('media', 'donor', {...donor.data, 'bangumiId': '99'});
    });
    await model.startBackgroundWork();
    expect(edited, true);
    expect(store.all('media').where((r) => r.data['bangumiId'] == '42'), hasLength(24));
    expect(store.all('media').where((r) => r.data['bangumiId'] == null), hasLength(36));
  });

  test('closing before deferred restoration preserves queued metadata tasks', () {
    final store = AppStore(':memory:');
    addTearDown(store.dispose);
    final saved = [{'id': 'pending', 'records': [{'id': 'v', 'revision': 1}]}];
    store.setLocal('metadata:pending-tasks', saved);
    final model = AppModel(store, Directory.systemTemp, deferBackgroundWork: true);
    model.dispose();
    expect(store.local('metadata:pending-tasks'), saved);
  });

  test('idle shutdown does not create a metadata checkpoint', () async {
    final store = AppStore(':memory:');
    final model = AppModel(store, Directory.systemTemp, deferBackgroundWork: true);
    await model.startBackgroundWork();
    expect(model.metadataTasks, isEmpty);
    model.dispose();
    await model.flushMetadataTasks();
    expect(store.local('metadata:pending-tasks'), isNull);
    expect(store.localModified('metadata:pending-tasks'), isNull);
    store.dispose();
  });

  test('deferred startup does no library work until the host is ready', () async {
    final store = _CountingStore();
    store.setLocal('settings', {'metadataStrategy': 'off'});
    final model = AppModel(store, Directory.systemTemp, deferBackgroundWork: true);
    addTearDown(() {
      model.dispose();
      store.dispose();
    });
    await Future<void>.delayed(Duration.zero);
    expect(store.mediaReads, 0);
    final starting = model.startBackgroundWork();
    expect(model.startBackgroundWork(), same(starting));
    await starting;
    expect(store.mediaReads, 1);
  });
}

class _CountingStore extends AppStore {
  int mediaReads = 0;
  _CountingStore() : super(':memory:');
  @override
  List<SyncRecord> all(String kind) {
    if (kind == 'media') mediaReads++;
    return super.all(kind);
  }
}
