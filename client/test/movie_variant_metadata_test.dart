import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

const _title = 'GROTESQQQUE -グロテスク-';

class _Catalog extends LibraryCatalog {
  _Catalog(super.store);
  final queries = <(String, String)>[];

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    queries.add((title, season));
    return title == _title && season.isEmpty
        ? {
            'provider': 'bangumi',
            'id': '42',
            'mediaType': 'movie',
            'name': _title,
            'name_cn': 'GROTESQQQUE -怪异-',
          }
        : null;
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async => {};
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  late final fakeCatalog = _Catalog(store);
  @override
  LibraryCatalog get catalog => fakeCatalog;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cleaned grouping still reuses donors with a localized display title',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'release-metadata-donor-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _Model(store, root);
      addTearDown(() async {
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      });
      store.save('media', 'first', {
        'fileName': 'Original Title E01.mkv',
        'series': 'Original Title',
        'season': '',
        'episode': '1',
        'bangumiId': '7',
        'metadataTitle': '官方中文译名',
      });
      final second = model.addMedia(
        'local',
        const SourceEntry(
          name: 'Original Title E02.mkv',
          path: '/Original Title/Original Title E02.mkv',
        ),
      );
      expect(store.get('media', second)!.data['bangumiId'], '7');
      expect(store.get('media', second)!.data['metadataTitle'], '官方中文译名');
      expect(store.get('media', second)!.data['episode'], '2');
    },
  );

  test(
    'retry groups historical movie variants with the cleaned release title',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'movie-variant-metadata-',
      );
      final store = AppStore('${root.path}/library.db');
      final model = _Model(store, root);
      addTearDown(() async {
        model.dispose();
        await model.flushMetadataTasks();
        store.dispose();
        await root.delete(recursive: true);
      });
      for (final (id, group, language) in [
        ('simplified', '北宇治字幕组', '简体'),
        ('traditional', '北宇治字幕組', '繁体'),
      ]) {
        final fileName = '$_title [$group] [$language].mkv';
        store.save('media', id, {
          'title': fileName,
          'fileName': fileName,
          // Libraries imported before the parser fix retain this derived name.
          'series': '$_title [$group]',
          'season': '',
          'episode': '',
        });
      }
      final task = model.startMetadataTask(store.records('media'));
      await task.done;
      expect(task.error, isEmpty);
      expect(task.matched, 2);
      expect(model.fakeCatalog.queries, [(_title, '')]);
      for (final record in store.records('media')) {
        expect(record.data['bangumiId'], '42');
        expect(record.data['metadataType'], 'movie');
        expect(record.data['metadataTitle'], 'GROTESQQQUE -怪异-');
        expect(record.data['season'], isEmpty);
        expect(record.data['episode'], isEmpty);
      }
    },
  );
}
