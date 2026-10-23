import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late AppModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-history-removal-');
    store = AppStore(':memory:');
    model = AppModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  SyncRecord add(String id, {String series = '测试作品', String episode = ''}) {
    store.save('media', id, {
      'title': '$series $episode.mkv',
      'series': series,
      'season': episode.isEmpty ? '' : '1',
      'episode': episode,
      'size': 100,
      'duration': 120,
    });
    final media = store.get('media', id)!;
    store.applyRemote(
      SyncRecord(
        kind: 'progress',
        id: model.progressKey(media),
        version: 1,
        data: {
          'position': 30,
          'duration': 120,
          'updatedAt': '2026-10-22T00:00:0${id}Z',
        },
      ),
    );
    return media;
  }

  test(
    'history removal tombstones only the current file version and preserves the library',
    () {
      final previous = add('1', episode: '1');
      final target = add('2', episode: '2');
      final other = add('3', series: '另一作品');
      final file = File('${root.path}/episode.mkv')
        ..writeAsBytesSync([1, 2, 3]);
      final location = {'source': 'local', 'path': file.path, 'size': 3};
      store.setLocal('location:${target.id}', location);
      store.setLocal('sources', [
        {'id': 'nas', 'label': '我的 NAS', 'type': 'webdav'},
      ]);
      store.setLocal('preview:${target.id}', {'path': '/preview.jpg'});
      store.save('watched', model.watchedKey(target), {'watched': true});
      store.save('match', target.id, {'subjectId': '42'});
      store.applyRemote(
        SyncRecord(
          kind: 'progress',
          id: model.progressKey(target),
          version: 1,
          data: {
            'position': 60,
            'duration': 120,
            'updatedAt': '2026-10-22T00:00:09Z',
          },
        ),
      );
      final remote = AppStore(':memory:');
      addTearDown(remote.dispose);
      for (final progress in store.records('progress')) {
        remote.applyRemote(progress);
      }
      var notifications = 0;
      model.addListener(() => notifications++);

      model.removePlaybackHistory(target);

      final deleted = store.get('progress', '${target.id}:3')!;
      expect(deleted.deleted, true);
      expect(deleted.dirty, true);
      expect(
        deleted.data,
        isEmpty,
        reason: 'Direct resume readers must see no position.',
      );
      expect(store.pending.where((r) => r.kind == 'progress'), isEmpty);
      expect(model.progressFor(target), isNull);
      expect(model.progressFor(previous)?['position'], 30);
      expect(model.progressFor(other)?['position'], 30);
      expect(store.get('progress', '${target.id}:100')?.deleted, false);
      expect(model.recentMedia().map((r) => r.id), [other.id, previous.id]);
      expect(model.media.map((r) => r.id), ['1', '2', '3']);
      expect(store.get('media', target.id)?.data, target.data);
      expect(store.local('location:${target.id}'), location);
      expect(model.sources.single['id'], 'nas');
      expect(store.local('preview:${target.id}'), {'path': '/preview.jpg'});
      expect(store.get('watched', model.watchedKey(target))?.data, {
        'watched': true,
      });
      expect(store.get('match', target.id)?.data, {'subjectId': '42'});
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(notifications, 1);

      // Device-local file history never removes the shared remote entry.
      expect(remote.get('progress', deleted.id)?.deleted, false);
      expect(remote.get('progress', deleted.id)?.data['position'], 60);

      model.removePlaybackHistory(target);
      expect(notifications, 1);
      expect(store.get('progress', deleted.id)?.revision, deleted.revision);
      store.save('progress', deleted.id, {'position': 5, 'duration': 120});
      expect(model.progressFor(target)?['position'], 5);
      expect(store.get('progress', deleted.id)?.deleted, false);
    },
  );

  for (final expanded in [false, true]) {
    testWidgets(
      '${expanded ? 'expanded history' : 'continue watching'} long press removes only its episode and reveals the previous episode',
      (tester) async {
        final previous = add('1', episode: '1');
        final latest = add('2', episode: '2');
        try {
          await tester.pumpWidget(AIPlayerApp(model: model));
          await tester.pumpAndSettle();
          if (expanded) {
            await tester.tap(find.text('继续观看'));
            await tester.pumpAndSettle();
            expect(find.text('观看历史'), findsOneWidget);
          }
          final card = find.byKey(ValueKey('history:${latest.id}'));
          expect(card, findsOneWidget);
          expect(find.byKey(ValueKey('history:${previous.id}')), findsNothing);
          await tester.longPress(card);
          await tester.pumpAndSettle();
          final remove = find.text('移除这条观看记录');
          expect(remove, findsOneWidget);
          expect(find.text(model.displayTitle(latest)), findsOneWidget);
          expect(model.progressFor(latest), isNotNull);
          expect(find.text('关联此设备上的视频位置'), findsNothing);

          // Dismissing the menu has no effect on the resume point.
          Navigator.of(tester.element(remove)).pop();
          await tester.pumpAndSettle();
          expect(model.progressFor(latest), isNotNull);
          await tester.longPress(card);
          await tester.pumpAndSettle();
          await tester.tap(find.text('移除这条观看记录'));
          await tester.pumpAndSettle();
          expect(model.progressFor(latest), isNull);
          expect(model.progressFor(previous), isNotNull);
          expect(find.byKey(ValueKey('history:${latest.id}')), findsNothing);
          expect(
            find.byKey(ValueKey('history:${previous.id}')),
            findsOneWidget,
          );
          expect(model.media.length, 2);

          await tester.longPress(
            find.byKey(ValueKey('history:${previous.id}')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('移除这条观看记录'));
          await tester.pumpAndSettle();
          expect(model.recentMedia(), isEmpty);
          expect(model.media.length, 2);
          expect(
            find.text(expanded ? '暂无观看历史' : '继续观看'),
            expanded ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}
