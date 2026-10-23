import 'dart:convert';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogTransport implements JsonTransport {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    calls++;
    if (uri.path.startsWith('/search/subject/')) {
      return {
        'list': [
          {'id': 7, 'name': 'Example'},
        ],
      };
    }
    return {'id': 7, 'name': 'Example', 'summary': 'Synopsis'};
  }
}

class _RecognitionModel extends AppModel {
  _RecognitionModel(super.store, super.documents);
  @override
  LibraryCatalog get catalog => _catalog;
  late final LibraryCatalog _catalog = LibraryCatalog(
    store,
    transport: _CatalogTransport(),
    strategy: () => 'off',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late AppModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-details-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = AppModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  SourceEntry video(String name) =>
      SourceEntry(name: name, path: '${root.path}/$name', size: 123);
  Map<String, dynamic> subject(int id) => {
    'id': id,
    'name_cn': '正式作品',
    'summary': 'A synopsis.',
    'rating': {'score': 8.8},
    'total_episodes': 12,
    'date': '2026-10-01',
    'genres': ['动画'],
  };

  test(
    'unchanged recognized folders do not rewrite records or rebuild listeners',
    () {
      final entries = [
        video('Example S01E01.mkv'),
        video('Example S01E02.mkv'),
      ];
      final collection = identifyDirectory(
        root.path,
        entries,
      )!.withMetadata(subject(7), {'1': '相逢', '2': '重逢'});
      var notifications = 0;
      model.addListener(() => notifications++);
      model.synchronizeCollection('local', collection, importMissing: true);
      expect(
        notifications,
        1,
        reason: 'bulk collection import sends one notification',
      );
      final revisions = {
        for (final record in model.media) record.id: record.revision,
      };
      model.synchronizeCollection('local', collection, importMissing: true);
      expect(notifications, 1);
      expect({
        for (final record in model.media) record.id: record.revision,
      }, revisions);
    },
  );

  test(
    'passive episode completion respects removal until explicit import or playback',
    () async {
      final entries = [
        video('Example S01E01.mkv'),
        video('Example S01E02.mkv'),
      ];
      for (final entry in entries) {
        File(entry.path).writeAsBytesSync([0]);
      }
      final collection = model.synchronizeCollection(
        'local',
        identifyDirectory(root.path, entries)!,
        importMissing: true,
      );
      final records = model.collectionRecords('local', collection);
      await model.removeMedia(records.last);
      expect(File(entries.last.path).existsSync(), isTrue);
      expect((await model.loadSeriesEpisodes(records.first)).length, 1);
      expect(model.media.length, 1);
      model.addMedia('local', entries.last);
      expect((await model.loadSeriesEpisodes(records.first)).length, 2);
    },
  );

  test(
    'manual recognition of a mixed folder resolves each series independently',
    () async {
      model.dispose();
      model = _RecognitionModel(store, root);
      final first = model.addMedia('local', video('Example S01E01.mkv'));
      final other = model.addMedia('local', video('Other S01E01.mkv'));
      final matched = await model.identifyMediaRecords([
        store.get('media', first)!,
        store.get('media', other)!,
      ]);
      expect(matched, isFalse);
      expect(store.get('media', first)?.data['bangumiId'], '7');
      expect(store.get('media', other)?.data['bangumiId'], isNull);
    },
  );

  test(
    'cached dimensions follow the content fingerprint and reject a replaced file',
    () {
      final entry = video('Example S01E01.mkv');
      final id = model.addMedia('local', entry);
      final record = store.get('media', id)!;
      model.recordMediaMetadata(id, duration: 10, width: 720, height: 1280);
      expect(model.mediaDimensions(record), (width: 720, height: 1280));
      model.addMedia(
        'local',
        SourceEntry(name: entry.name, path: entry.path, size: 456),
      );
      expect(model.mediaDimensions(record), isNull);
    },
  );

  test(
    'source metadata saves every episode and counts alternate encodes once',
    () {
      final videos = [
        video('Example S01E01.mkv'),
        video('Example S01E02.mkv'),
        video('Example S01E02.mp4'),
      ];
      final value = identifyDirectory(
        root.path,
        videos,
      )!.withMetadata(subject(7), {'1': '开始', '2': '相遇'});
      final resolved = model.synchronizeCollection(
        'local',
        value,
        importMissing: true,
      );
      final sourceRecords = model.collectionRecords('local', resolved);
      final fromSource = MediaCollectionDetails.fromRecords(sourceRecords);
      final fromLibrary = MediaCollectionDetails.fromRecords(
        model.seriesRecords(sourceRecords.first),
      );
      expect(model.media.length, 3);
      expect(fromSource.availableEpisodes, 2);
      expect(fromSource.videoCount, 3);
      expect(fromSource.availability, '已收录 2 集 · 3 个视频');
      expect(fromSource.title, fromLibrary.title);
      expect(fromSource.totalEpisodes, 12);
      expect(fromSource.summary, fromLibrary.summary);
      expect(model.episodeLabel(sourceRecords.last), contains('相遇'));
    },
  );

  test(
    'manual catalogue choice overrides directory lookup without touching other files',
    () {
      final videos = [video('Example S01E01.mkv'), video('Example S01E02.mkv')];
      final selected = model.addMedia('local', videos.first);
      final unrelated = model.addMedia(
        'local',
        SourceEntry(
          name: 'Example S01E03.mkv',
          path: '/other/Example S01E03.mkv',
        ),
      );
      model.applyBangumi('Example', subject(88), mediaIds: {selected});
      final resolved = model.synchronizeCollection(
        'local',
        identifyDirectory(root.path, videos)!.withMetadata(subject(7), {}),
        importMissing: true,
      );
      expect(resolved.subject?['id'], '88');
      expect(
        model
            .collectionRecords('local', resolved)
            .every((item) => item.data['bangumiId'] == '88'),
        isTrue,
      );
      expect(store.get('media', unrelated)?.data['bangumiId'], isNull);
    },
  );

  test(
    'conflicting verified identities remain separate during folder synchronization',
    () {
      final videos = [video('Example S01E01.mkv'), video('Example S01E02.mkv')];
      final ids = [for (final entry in videos) model.addMedia('local', entry)];
      for (var index = 0; index < ids.length; index++) {
        final record = store.get('media', ids[index])!;
        store.save('media', record.id, {
          ...record.data,
          ...subjectMediaFields(subject(index + 1)),
        });
      }
      model.synchronizeCollection(
        'local',
        identifyDirectory(root.path, videos)!.withMetadata(subject(7), {}),
      );
      expect(store.get('media', ids.first)?.data['bangumiId'], '1');
      expect(store.get('media', ids.last)?.data['bangumiId'], '2');
    },
  );

  test(
    'opening old library details discovers unplayed sibling episodes',
    () async {
      final first = video('Example S01E01.mkv'),
          second = video('Example S01E02.mkv');
      File(first.path).writeAsBytesSync([0]);
      File(second.path).writeAsBytesSync([0]);
      final id = model.addMedia('local', first);
      model.applyBangumi('Example', subject(7), mediaIds: {id});
      final records = await model.loadSeriesEpisodes(store.get('media', id)!);
      expect(records.map((item) => item.data['episode']), ['1', '2']);
      expect(records.every((item) => item.data['totalEpisodes'] == 12), isTrue);
    },
  );

  test(
    'explicit recognition works with automatic recognition disabled',
    () async {
      final transport = _CatalogTransport();
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        strategy: () => 'off',
      );
      expect(await catalog.resolve('Example', '1'), isNull);
      expect(transport.calls, 0);
      expect((await catalog.resolve('Example', '1', force: true))?['id'], 7);
      expect(transport.calls, greaterThan(0));
    },
  );

  testWidgets(
    'shared synopsis restores configured translation cache and can show original',
    (tester) async {
      const summary = 'An original synopsis.';
      final config = SubtitleAiConfig(model: 'chosen-model');
      store.setLocal('settings', {
        ...model.settings,
        'aiSubtitleModel': config.model,
      });
      final key =
          'summary-translation:${sha256.convert(utf8.encode(jsonEncode([summary, config.identity])))}';
      store.setLocal(key, '已缓存的简介翻译。');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaSummary(model: model, summary: summary),
          ),
        ),
      );
      await tester.tap(find.text('AI 翻译简介'));
      await tester.pumpAndSettle();
      expect(find.text('已缓存的简介翻译。'), findsOneWidget);
      expect(find.text('使用 AI 翻译简介'), findsNothing);
      await tester.tap(find.text('查看原文'));
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
      expect(find.text('查看译文'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
