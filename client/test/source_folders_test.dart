import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'folder menu starts recursive recognition for the current directory',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'source-recognition-entry-',
      );
      final store = AppStore('${directory.path}/library.db')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final model = _RecognitionBrowserModel(store, directory);
      try {
        await tester.runAsync(() => model.loadLibrarySnapshot());
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'local', 'kind': 'local', 'label': 'Local'},
              initialPath: directory.path,
              initialName: '当前文件夹',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('文件夹选项'));
        await tester.pumpAndSettle();
        expect(find.text('识别此文件夹及子文件夹'), findsOneWidget);
        await tester.tap(find.text('识别此文件夹及子文件夹'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 500 && model.recognizingDirectory; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(model.recognizingDirectory, false);
        expect(model.status, '此文件夹及子文件夹中没有视频。');
        expect(model.directoryRecognitionProgress.folders, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'folder and video menus keep AI inside the manual matching sheet',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-source-metadata-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final model = _FolderModel(store, directory);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.text('第一季'));
        await tester.pumpAndSettle();
        expect(find.text('重新识别影视资料'), findsOneWidget);
        expect(find.text('AI 自动识别'), findsNothing);
        await tester.tap(find.text('手动搜索影视资料'));
        await tester.pumpAndSettle();
        expect(find.text('匹配影视资料'), findsOneWidget);
        final query = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '作品名称',
        );
        await tester.enterText(query, '手动输入作品名');
        expect(tester.widget<TextField>(query).controller?.text, '手动输入作品名');
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第一季'));
        await tester.pumpAndSettle();
        final remote = model.sourceMedia('one', 'Season1/01.mkv')!;
        await tester.longPress(find.text(model.displayTitle(remote)));
        await tester.pumpAndSettle();
        expect(find.text('重新识别影视资料'), findsOneWidget);
        expect(find.text('手动搜索影视资料'), findsOneWidget);
        expect(find.text('AI 自动识别'), findsNothing);
        expect(find.text('收藏文件夹'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        final id = model.addMedia(
          'local',
          const SourceEntry(name: '本地样片.mp4', path: '/local/sample.mp4'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('本地视频'));
        await tester.pumpAndSettle();
        await tester.longPress(
          find.text(model.displayTitle(store.get('media', id)!)),
        );
        await tester.pumpAndSettle();
        expect(find.text('AI 自动识别'), findsNothing);
        await tester.tap(find.text('手动搜索影视资料'));
        await tester.pumpAndSettle();
        expect(find.text('匹配影视资料'), findsOneWidget);
        await tester.tap(find.text('AI 自动识别'));
        await tester.pumpAndSettle();
        expect(find.text('匹配影视资料'), findsOneWidget);
        expect(find.text('请先在设置 → AI 翻译中配置模型。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'series folders show each video progress and resume the most recently played episode',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-folder-progress-',
      );
      final store = AppStore(':memory:');
      store.setLocal('settings', {'metadataStrategy': 'off'});
      final model = _SeriesModel(store, directory);
      final ids = [
        for (final entry in _SeriesAdapter.entries)
          model.addMedia('one', entry),
      ];
      for (var index = 0; index < ids.length; index++) {
        store.save(
          'progress',
          model.progressKey(store.get('media', ids[index])!),
          {
            'position': index == 0 ? 20 : 50,
            'duration': 100,
            'updatedAt': '2026-10-21T12:00:0$index.000Z',
          },
        );
      }
      final elsewhere = model.addMedia(
        'one',
        const SourceEntry(
          name: '示例动画 S01E03.mkv',
          path: '其他目录/示例动画 S01E03.mkv',
        ),
      );
      store.save(
        'progress',
        model.progressKey(store.get('media', elsewhere)!),
        {
          'position': 70,
          'duration': 100,
          'updatedAt': '2026-10-22T12:00:00.000Z',
        },
      );
      String? played;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': '动画'},
              initialPath: '示例动画 S01/',
              onPlay: (media) async => played = media.id,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MediaDetailsOverview), findsOneWidget);
        expect(find.byType(MediaDetailsContinue), findsOneWidget);
        expect(find.byType(MediaDetailsPlaylistHeader), findsOneWidget);
        expect(find.byType(MediaDetailsEpisodeTile), findsNWidgets(ids.length));
        expect(find.text('播放列表'), findsOneWidget);
        expect(find.byTooltip('排序与显示'), findsOneWidget);
        for (var index = 0; index < ids.length; index++) {
          final row = find.byKey(ValueKey(_SeriesAdapter.entries[index].path));
          expect(
            find.descendant(
              of: row,
              matching: find.textContaining(
                index == 0 ? '00:20 / 01:40 · 20%' : '00:50 / 01:40 · 50%',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.textContaining('MKV')),
            findsOneWidget,
          );
        }
        expect(find.textContaining('第 2 集'), findsAtLeastNWidgets(1));
        await tester.tap(find.byKey(const ValueKey('series-continue')));
        await tester.pumpAndSettle();
        expect(played, ids.last);
        expect(
          (model.progressFor(store.get('media', ids.first)!)?['position']),
          20,
        );
        await tester.tap(find.byTooltip('视频选项').first);
        await tester.pumpAndSettle();
        expect(find.text('重新识别影视资料'), findsOneWidget);
        expect(find.text('手动搜索影视资料'), findsOneWidget);
        Navigator.of(tester.element(find.text('重新识别影视资料'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('匹配海报与简介'));
        await tester.pumpAndSettle();
        expect(find.text('2 个视频'), findsOneWidget);
        expect(find.text('3 个视频'), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'series episode subtitles stay visible before and after playback',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-folder-titles-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _SeriesModel(store, directory);
      const series = '这是一部名称很长的动画作品但不应该挤占每集小标题';
      final ids = [
        for (final entry in _SeriesAdapter.entries)
          model.addMedia('one', entry),
      ];
      for (var index = 0; index < ids.length; index++) {
        store.save('media', ids[index], {
          ...store.get('media', ids[index])!.data,
          'metadataTitle': series,
          'bangumiId': 123,
        });
        store.setLocal('episodeTitle:${ids[index]}', '小标题 ${index + 1}');
      }
      String? played;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': '动画'},
              initialPath: '示例动画 S01/',
              onPlay: (media) async {
                played = media.id;
                store.setLocal('episodeTitle:${media.id}', '播放后更新的小标题');
                model.changed();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(series), findsOneWidget);
        expect(find.text('示例动画 S01'), findsNothing);
        expect(find.byTooltip('返回'), findsOneWidget);
        await tester.tap(find.byTooltip('文件夹选项'));
        await tester.pumpAndSettle();
        expect(find.text('当前目录：示例动画 S01/'), findsOneWidget);
        Navigator.of(tester.element(find.text('当前目录：示例动画 S01/'))).pop();
        await tester.pumpAndSettle();
        expect(find.text('第 1 集 · 小标题 1'), findsOneWidget);
        expect(find.text('第 2 集 · 小标题 2'), findsOneWidget);
        expect(find.textContaining('$series ·'), findsNothing);
        await tester.tap(find.text('第 1 集 · 小标题 1'));
        await tester.pumpAndSettle();
        expect(played, ids.first);
        expect(find.text('第 1 集 · 播放后更新的小标题'), findsOneWidget);
        expect(find.textContaining('$series ·'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'long-press favorites open their subfolder from the source root and can be removed',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-favorites-ui-',
      );
      final store = AppStore(':memory:');
      final model = _FolderModel(store, directory);
      store.setLocal('sources', [
        {'id': 'one', 'kind': 'smb', 'label': '我的 NAS'},
      ]);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('我的 NAS'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('第一季'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏文件夹'));
        await tester.pumpAndSettle();
        expect(SourceFavorites(store).contains('one', 'Season1/'), true);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        await tester.tap(find.text('第一季'));
        await tester.pumpAndSettle();
        expect(find.text('第01集.mkv'), findsOneWidget);
        expect(find.text('第一季'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        await tester.tap(find.byTooltip('收藏选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消收藏'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsNothing);
        expect(SourceFavorites(store).all, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'favorite back navigation stops at its entry folder and preserves ordinary source state',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-favorite-navigation-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        })
        ..setLocal('sources', [
          {'id': 'one', 'kind': 'webdav', 'label': '我的 NAS'},
        ])
        ..setLocal('sourceBrowser:one', {
          'paths': [
            {'path': 'Library/', 'name': '资料库'},
          ],
          'offsets': <String, double>{},
        });
      final model = _NestedFolderModel(store, directory);
      SourceFavorites(store).toggle(
        const SourceFavorite(
          sourceId: 'one',
          path: 'Library/Shows/Season1/',
          name: '收藏第一季',
        ),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏第一季'));
        await tester.pumpAndSettle();
        expect(find.text('花絮'), findsOneWidget);
        await tester.tap(find.text('花絮'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('访谈'));
        await tester.pumpAndSettle();
        expect(find.text('特典.mkv'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('花絮'), findsOneWidget);
        expect(find.text('访谈'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('收藏第一季'), findsOneWidget);
        expect(find.text('花絮'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        expect(find.text('花絮'), findsNothing);
        await tester.tap(find.text('收藏第一季'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        expect((store.local('sourceBrowser:one') as Map)['paths'], [
          {'path': 'Library/', 'name': '资料库'},
        ]);
        await tester.tap(
          find.descendant(
            of: find.byType(ReorderableDelayedDragStartListener),
            matching: find.text('我的 NAS'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('资料库'), findsOneWidget);
        expect(find.text('剧集'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsNothing);
        expect(find.text('我的 NAS'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'hidden entries react to preferences and current sorting can apply to all folders',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-hidden-ui-',
      );
      final store = AppStore(':memory:');
      final model = _HiddenModel(store, directory);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(brightness: Brightness.dark),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': '文件夹'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('.hidden'), findsNothing);
        expect(find.text('Episode.mkv'), findsOneWidget);
        await model.updatePreferences({'hideHiddenFiles': false});
        await tester.pumpAndSettle();
        expect(find.text('.hidden'), findsOneWidget);
        await tester.tap(find.byTooltip('排序与显示'));
        await tester.pumpAndSettle();
        expect(
          find.ancestor(
            of: find.text('降序'),
            matching: find.byType(GlassSurface),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('降序'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用到所有文件夹'));
        await tester.pumpAndSettle();
        expect(
          model.directorySorting('directorySort:another:Shows/').descending,
          isTrue,
        );
        expect(
          model.directorySorting('directorySort:local:imports').descending,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'file icons distinguish supported media, subtitles, images and unknown files',
    () {
      expect(sourceFileIcon('video.mkv'), Icons.movie_outlined);
      expect(sourceFileIcon('zh-Hans.ass'), Icons.subtitles_outlined);
      expect(sourceFileIcon('poster.jpg'), Icons.image_outlined);
      expect(sourceFileIcon('audio.flac'), Icons.audio_file_outlined);
      expect(sourceFileIcon('unknown.bin'), Icons.insert_drive_file_outlined);
    },
  );
  testWidgets(
    'returning to a directory restores scroll and keeps its own sort preferences',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-directory-state-',
      );
      final store = AppStore(':memory:');
      final model = _NavigationModel(store, directory);
      final source = {'id': 'one', 'kind': 'webdav', 'label': '文件夹'};
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(model: model, source: source),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('第20季'),
          350,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        final before = tester
            .widget<ListView>(find.byType(ListView))
            .controller!
            .offset;
        expect(before, greaterThan(0));
        await tester.tap(find.text('第20季'));
        await tester.pumpAndSettle();
        expect(find.text('第01集.mkv'), findsOneWidget);
        expect(find.text('字幕.ass'), findsNothing);
        await tester.tap(find.byTooltip('排序与显示'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('降序'));
        await tester.pumpAndSettle();
        expect(
          (store.local('directorySort:one:Season20/') as Map)['descending'],
          true,
        );
        expect(store.local('directorySort:one:'), isNull);
        Navigator.pop(tester.element(find.text('降序')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        final restored = tester
            .widget<ListView>(find.byType(ListView))
            .controller!
            .offset;
        expect(restored, closeTo(before, 1));
        expect(find.text('第20季'), findsOneWidget);
        expect(
          (store.local('sourceBrowser:one') as Map)['offsets'][''],
          closeTo(before, 1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'editing a source preserves identity, order and stored credentials',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'source:one': 'saved-password',
      });
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-source-edit-',
      );
      final store = AppStore(':memory:');
      final model = _FolderModel(store, directory);
      store.setLocal('settings', {'autoDiscover': false});
      store.setLocal('sources', [
        {
          'id': 'one',
          'kind': 'smb',
          'label': 'NAS',
          'host': 'nas.local:1445',
          'share': 'videos',
        },
        {
          'id': 'two',
          'kind': 'http',
          'label': '视频',
          'url': 'https://example.com/video.mp4',
        },
      ]);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('来源选项').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑来源'));
        await tester.pumpAndSettle();
        Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
        );
        expect(tester.widget<TextField>(field('端口')).controller!.text, '1445');
        expect(
          tester.widget<TextField>(field('密码（可选）')).controller!.text,
          'saved-password',
        );
        expect(tester.widget<TextField>(field('密码（可选）')).obscureText, true);
        await tester.ensureVisible(field('服务器地址'));
        await tester.enterText(field('服务器地址'), 'new-nas.local');
        final save = find.widgetWithText(TextButton, '保存');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(model.sources.map((source) => source['id']), ['one', 'two']);
        expect(model.sources.first['host'], 'new-nas.local');
        expect(model.sources.first['port'], 1445);
        expect(model.sources.first.containsKey('password'), false);
        expect(await model.secrets.read(key: 'source:one'), 'saved-password');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'folder navigation stays in the page and deleting requires confirmation',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'source:one': 'saved-password',
      });
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-source-folders-',
      );
      final store = AppStore(':memory:');
      final model = _FolderModel(store, directory);
      store.setLocal('settings', {'autoDiscover': false});
      store.setLocal('sources', [
        {
          'id': 'one',
          'kind': 'smb',
          'label': '我的 NAS',
          'host': 'nas.local',
          'share': 'videos',
        },
      ]);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
              bottomNavigationBar: const Text('底部导航保留'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地视频'), findsOneWidget);
        expect(find.byTooltip('移除来源'), findsNothing);
        await tester.tap(find.text('我的 NAS'));
        await tester.pumpAndSettle();
        expect(find.text('第一季'), findsOneWidget);
        expect(find.text('底部导航保留'), findsOneWidget);
        expect(find.text('根目录'), findsNothing);
        await tester.tap(find.text('第一季'));
        await tester.pumpAndSettle();
        expect(find.text('第01集.mkv'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('第一季'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('来源选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除来源…'));
        await tester.pumpAndSettle();
        expect(find.text('移除来源？'), findsOneWidget);
        expect(model.sources, hasLength(1));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(model.sources, hasLength(1));
        await tester.tap(find.byTooltip('来源选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除来源…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除'));
        await tester.pumpAndSettle();
        expect(model.sources, isEmpty);
        expect(await model.secrets.read(key: 'source:one'), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'connection test reads the unsaved configuration and shows actionable errors',
    (tester) async {
      Map<String, dynamic>? tested;
      String? password;
      final adapter = _DirectoryAdapter(fail: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourceEditorPage(
                      initial: const {
                        'kind': 'webdav',
                        'url': 'https://nas.local:8443/dav/',
                        'password': 'private-password',
                      },
                      connector: (configuration, secret) async {
                        tested = configuration;
                        password = secret;
                        return adapter;
                      },
                    ),
                  ),
                ),
                child: const Text('配置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('配置'));
      await tester.pumpAndSettle();
      final test = find.text('测试连接');
      await tester.ensureVisible(test);
      await tester.pumpAndSettle();
      await tester.tap(test);
      await tester.pumpAndSettle();
      expect(tested?['port'], 8443);
      expect(tested?['password'], isNull);
      expect(password, 'private-password');
      expect(find.text('连接测试失败'), findsOneWidget);
      expect(find.textContaining('HTTP 401'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('private-password'),
        ),
        findsNothing,
      );
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      expect(adapter.closed, true);
      expect(find.byType(SourceDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _FolderModel extends AppModel {
  _FolderModel(super.store, super.documents);
  @override
  Future<SourceAdapter> adapter(String id) async => _DirectoryAdapter();
}

class _RecognitionBrowserModel extends AppModel {
  _RecognitionBrowserModel(super.store, super.documents)
    : super(backgroundWork: false);
  @override
  Future<SourceAdapter> adapter(String id) async => _DirectoryAdapter();
}

class _NestedFolderModel extends AppModel {
  _NestedFolderModel(super.store, super.documents);
  @override
  Future<SourceAdapter> adapter(String id) async => _NestedFolderAdapter();
}

class _NestedFolderAdapter extends _DirectoryAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => switch (path) {
    '' => [const SourceEntry(name: '资料库', path: 'Library/', directory: true)],
    'Library/' => [
      const SourceEntry(name: '剧集', path: 'Library/Shows/', directory: true),
    ],
    'Library/Shows/' => [
      const SourceEntry(
        name: '第一季',
        path: 'Library/Shows/Season1/',
        directory: true,
      ),
    ],
    'Library/Shows/Season1/' => [
      const SourceEntry(
        name: '花絮',
        path: 'Library/Shows/Season1/Extras/',
        directory: true,
      ),
    ],
    'Library/Shows/Season1/Extras/' => [
      const SourceEntry(
        name: '访谈',
        path: 'Library/Shows/Season1/Extras/Interviews/',
        directory: true,
      ),
    ],
    _ => [SourceEntry(name: '特典.mkv', path: '${path}special.mkv')],
  };
}

class _SeriesModel extends AppModel {
  _SeriesModel(super.store, super.documents);
  @override
  Future<SourceAdapter> adapter(String id) async => _SeriesAdapter();
}

class _SeriesAdapter extends _DirectoryAdapter {
  static const entries = [
    SourceEntry(
      name: '示例动画 S01E01.mkv',
      path: '示例动画 S01/示例动画 S01E01.mkv',
      size: 100,
    ),
    SourceEntry(
      name: '示例动画 S01E02.mkv',
      path: '示例动画 S01/示例动画 S01E02.mkv',
      size: 200,
    ),
  ];
  @override
  Future<List<SourceEntry>> list(String path) async => entries;
}

class _HiddenModel extends AppModel {
  _HiddenModel(super.store, super.documents);
  @override
  Future<SourceAdapter> adapter(String id) async => _HiddenAdapter();
}

class _HiddenAdapter extends _DirectoryAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => const [
    SourceEntry(name: '.hidden', path: '.hidden/', directory: true),
    SourceEntry(name: 'Episode.mkv', path: 'Episode.mkv'),
  ];
}

class _DirectoryAdapter extends SourceAdapter {
  final bool fail;
  bool closed = false;
  _DirectoryAdapter({this.fail = false});
  @override
  Future<List<SourceEntry>> list(String path) async {
    if (fail) throw const AppFailure('HTTP 401 · 认证失败，请检查用户名和密码。', 401);
    return path.isEmpty
        ? [const SourceEntry(name: '第一季', path: 'Season1/', directory: true)]
        : [const SourceEntry(name: '第01集.mkv', path: 'Season1/01.mkv')];
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: '视频', path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _NavigationModel extends AppModel {
  _NavigationModel(super.store, super.documents);
  @override
  Future<SourceAdapter> adapter(String id) async => _NavigationAdapter();
}

class _NavigationAdapter extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => path.isEmpty
      ? [
          for (var i = 1; i <= 40; i++)
            SourceEntry(
              name: '第${i.toString().padLeft(2, '0')}季',
              path: 'Season$i/',
              directory: true,
            ),
        ]
      : [
          SourceEntry(name: '第01集.mkv', path: '${path}01.mkv'),
          SourceEntry(name: '字幕.ass', path: '${path}sub.ass'),
        ];
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: '视频', path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}
