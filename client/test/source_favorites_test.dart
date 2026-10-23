import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'folder favorites persist locally, normalize aliases and exclude deleted sources',
    () {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      final favorites = SourceFavorites(store);
      const first = SourceFavorite(
        sourceId: 'one',
        path: '动画/第一季/',
        name: '第一季',
      );
      expect(favorites.toggle(first), true);
      expect(SourceFavorites(store).all.single.path, first.path);
      expect(favorites.contains('one', '动画/第一季'), true);
      expect(favorites.contains('two', first.path), false);
      expect(store.pending, isEmpty); // SyncProfile stages remote shortcuts when synchronization runs.
      expect(
        favorites.toggle(
          const SourceFavorite(sourceId: 'one', path: '动画/第一季', name: '重命名'),
        ),
        false,
      );
      expect(favorites.all, isEmpty);
      favorites.toggle(first);
      favorites.toggle(
        const SourceFavorite(sourceId: 'one', path: '', name: 'NAS'),
      );
      favorites.toggle(
        const SourceFavorite(sourceId: 'two', path: '节目/', name: '节目'),
      );
      expect(favorites.available(['two']).map((entry) => entry.name), ['节目']);
      favorites.removeSource('one');
      expect(favorites.all.single.sourceId, 'two');
      expect(
        (store.local(SourceFavorites.storageKey) as List).single.keys.toSet(),
        {'sourceId', 'path', 'name'},
      );
    },
  );

  test(
    'invalid saved favorite records are ignored and duplicate paths collapse',
    () {
      final store = AppStore(':memory:');
      addTearDown(store.dispose);
      store.setLocal(SourceFavorites.storageKey, [
        {'sourceId': 'one', 'path': '动画/', 'name': '动画'},
        {'sourceId': 'one', 'path': '动画', 'name': '重复'},
        {'sourceId': '', 'path': '动画/', 'name': '无效'},
        {'sourceId': 'one', 'path': 1, 'name': '无效'},
        'corrupt',
      ]);
      expect(SourceFavorites(store).all.map((entry) => entry.name), ['动画']);
    },
  );
}
