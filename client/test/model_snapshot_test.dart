import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _SnapshotStore store;
  late AppModel model;

  setUp(() {
    store = _SnapshotStore();
    model = AppModel(store, Directory.systemTemp, backgroundWork: false);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
  });

  test(
    'unchanged model reads reuse decoded snapshots through unrelated writes',
    () {
      store.save('media', 'video', {
        'title': 'Original',
        'genres': ['Action'],
      });
      store.setLocal('settings', {
        'volume': 60,
        'shortcuts': {'playPause': 'P'},
      });
      store.setLocal('sources', [
        {
          'id': 'nas',
          'options': {'port': 445},
        },
      ]);
      final media = model.media;
      model.settings;
      model.sources;
      store.resetReads();

      for (var i = 0; i < 20; i++) {
        store.setLocal('preview:$i', {'path': '/$i.jpg'});
        store.save('progress', 'video:0', {'position': i});
        expect(model.media, same(media));
        expect(model.settings['volume'], 60);
        expect(model.sources.single['id'], 'nas');
      }

      expect(store.mediaReads, 0);
      expect(store.settingReads, 0);
      expect(store.sourceReads, 0);
      expect(() => media.clear(), throwsUnsupportedError);
      expect(
        () => media.single.data['title'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => (media.single.data['genres'] as List).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('settings and source drafts remain deeply detached from snapshots', () {
    store.setLocal('settings', {
      'shortcuts': {'playPause': 'P'},
    });
    store.setLocal('sources', [
      {
        'id': 'nas',
        'options': {'port': 445},
      },
    ]);
    final settings = model.settings;
    final sources = model.sources;
    (settings['shortcuts'] as Map)['playPause'] = 'X';
    (sources.single['options'] as Map)['port'] = 999;
    sources.clear();

    expect(model.settings['shortcuts'], {'playPause': 'P'});
    expect(model.sources.single['options'], {'port': 445});
    store.setLocal('settings', settings);
    expect(model.settings['shortcuts'], {'playPause': 'X'});
  });

  test('managed edits, direct SQL and rollback refresh model snapshots', () {
    store.save('media', 'video', {'title': 'Original'});
    store.setLocal('sources', [
      {'id': 'original'},
    ]);
    store.setLocal('settings', {'volume': 60});
    final original = model.media;
    model.sources;
    model.settings;

    expect(
      () => store.transaction(() {
        store.save('media', 'video', {'title': 'Temporary'});
        store.setLocal('sources', [
          {'id': 'temporary'},
        ]);
        store.setLocal('settings', {'volume': 20});
        expect(model.media.single.data['title'], 'Temporary');
        expect(model.sources.single['id'], 'temporary');
        expect(model.settings['volume'], 20);
        throw StateError('rollback');
      }),
      throwsStateError,
    );

    expect(model.media.single.data['title'], 'Original');
    expect(model.media, isNot(same(original)));
    expect(model.sources.single['id'], 'original');
    expect(model.settings['volume'], 60);
    store.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
      '{"title":"SQL"}',
      'media',
      'video',
    ]);
    store.db.execute('UPDATE local SET value=? WHERE key=?', [
      '[{"id":"sql"}]',
      'sources',
    ]);
    expect(model.media.single.data['title'], 'SQL');
    expect(model.sources.single['id'], 'sql');
    store.save('media', 'video', {}, deleted: true);
    expect(model.media, isEmpty);
  });

  test(
    'external worker progress preserves media but content commits refresh it',
    () {
      final directory = Directory.systemTemp.createTempSync('model-snapshot-');
      final primary = AppStore('${directory.path}/app.db');
      final worker = AppStore.openExisting(primary.path);
      final reader = AppModel(primary, directory, backgroundWork: false);
      addTearDown(() {
        reader.dispose();
        worker.dispose();
        primary.dispose();
        directory.deleteSync(recursive: true);
      });
      primary.save('media', 'video', {'title': 'Original'});
      primary.setLocal('settings', {'volume': 60});
      primary.setLocal('sources', [
        {'id': 'original'},
      ]);
      final initial = reader.media;
      reader.settings;
      reader.sources;

      worker.save('progress', 'video:0', {'position': 10});
      expect(reader.media, same(initial));
      worker.transaction(() {
        worker.save('media', 'video', {'title': 'External'});
        worker.setLocal('settings', {'volume': 30});
        worker.setLocal('sources', [
          {'id': 'external'},
        ]);
      });
      expect(reader.media.single.data['title'], 'External');
      expect(reader.settings['volume'], 30);
      expect(reader.sources.single['id'], 'external');
    },
  );

  test(
    'unchanged preferences and source order do not notify listeners',
    () async {
      store.setLocal('settings', {'volume': 60});
      store.setLocal('sources', [
        {'id': 'a'},
        {'id': 'b'},
      ]);
      var notifications = 0;
      model.addListener(() => notifications++);
      await model.updatePreferences({'volume': 60});
      model.reorderSources(['a', 'b']);
      expect(notifications, 0);
      await model.updatePreferences({'volume': 70});
      expect(notifications, 1);
      await model.updatePreferences({'volume': 70});
      expect(notifications, 1);
      await model.resetPreferences();
      expect(notifications, 2);
      await model.resetPreferences();
      expect(notifications, 2);
      model.reorderSources(['b', 'a']);
      expect(notifications, 3);
    },
  );
}

class _SnapshotStore extends AppStore {
  int mediaReads = 0, settingReads = 0, sourceReads = 0;
  _SnapshotStore() : super(':memory:');

  void resetReads() => mediaReads = settingReads = sourceReads = 0;

  @override
  List<SyncRecord> all(String kind) {
    if (kind == 'media') mediaReads++;
    return super.all(kind);
  }

  @override
  dynamic local(String key) {
    if (key == 'settings') settingReads++;
    if (key == 'sources') sourceReads++;
    return super.local(key);
  }
}
