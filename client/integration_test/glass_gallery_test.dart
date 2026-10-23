import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Runs against the real Flutter desktop renderer. All library data is created
/// in a temporary database; no media servers, credentials or poster APIs are used.
///
/// From client/: xvfb-run -a flutter test integration_test/glass_gallery_test.dart
///   -d linux --no-pub
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'capture light and dark library, settings and sources on desktop and phone',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final font = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
      await font.load();
      final root = await Directory.systemTemp.createTemp(
        'aiplayer-glass-gallery-',
      );
      final store = AppStore('${root.path}/gallery.db');
      final model = AppModel(store, root);
      await model.updatePreferences({'autoDiscover': false});
      _populateGallery(model);
      final boundaryKey = GlobalKey();
      final artifacts = Directory('${Directory.current.path}/../artifacts');
      await artifacts.create(recursive: true);

      Future<void> showAt(Size size, ThemeMode mode) async {
        await tester.pumpWidget(const SizedBox());
        model.setThemeMode(mode);
        await binding.setSurfaceSize(size);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MediaQuery(
              data: MediaQueryData(size: size, devicePixelRatio: 1),
              child: AIPlayerApp(model: model),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> capture(String filename, {String? alias}) async {
        await tester.pump();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final content = bytes!.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        await File('${artifacts.path}/$filename').writeAsBytes(content);
        if (alias != null) {
          await File('${artifacts.path}/$alias').writeAsBytes(content);
        }
      }

      try {
        for (final appearance in [ThemeMode.light, ThemeMode.dark]) {
          final tone = appearance.name;
          for (final viewport in [
            (name: 'desktop', size: const Size(1440, 980)),
            (name: 'mobile', size: const Size(390, 844)),
          ]) {
            await showAt(viewport.size, appearance);
            expect(find.text('我的影视库'), findsOneWidget);
            expect(find.text('继续观看'), findsOneWidget);
            expect(
              Theme.of(tester.element(find.text('我的影视库'))).brightness,
              appearance == ThemeMode.light
                  ? Brightness.light
                  : Brightness.dark,
            );
            await capture(
              'library_${viewport.name}_$tone.png',
              alias: appearance == ThemeMode.light
                  ? 'library_${viewport.name}.png'
                  : null,
            );

            await tester.tap(find.text('设置').last);
            await tester.pumpAndSettle();
            expect(find.text('外观与文件'), findsOneWidget);
            final playbackChip = find.widgetWithText(ChoiceChip, '播放');
            await tester.tap(playbackChip);
            await tester.pumpAndSettle();
            expect(find.text('默认倍速'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await capture(
              'settings_${viewport.name}_$tone.png',
              alias: appearance == ThemeMode.light
                  ? 'settings_${viewport.name}.png'
                  : null,
            );

            final sourceLabel = find.text('来源').evaluate().isNotEmpty
                ? '来源'
                : '视频来源';
            await tester.tap(find.text(sourceLabel).last);
            await tester.pumpAndSettle();
            expect(find.text('本地视频'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await capture(
              'sources_${viewport.name}_$tone.png',
              alias: appearance == ThemeMode.light
                  ? 'sources_${viewport.name}.png'
                  : null,
            );
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await binding.setSurfaceSize(null);
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}

void _populateGallery(AppModel model) {
  const titles = [
    '星海漫游',
    '风与森林',
    '雨后的旧书店',
    '夏日列车',
    '月光邮差',
    '天际来信',
    '晴空奏鸣曲',
    '慢慢喜欢这世界',
  ];
  for (var i = 0; i < titles.length; i++) {
    for (var episode = 1; episode <= (i < 2 ? 4 : 2); episode++) {
      final id = 'gallery-$i-$episode';
      model.store.save('media', id, {
        'title': '${titles[i]} · 第 $episode 集',
        'series': titles[i],
        'fileName': 'Gallery-$i-S01E0$episode.mkv',
        'season': '1',
        'episode': '$episode',
        'size': 960000000 + episode,
        'duration': 1440,
      });
      final record = model.store.get('media', id)!;
      if (i < 2 && episode == 3) {
        model.store.save('progress', model.progressKey(record), {
          'position': i == 0 ? 612 : 354,
          'duration': 1440,
          'updatedAt': '2026-10-21T${12 - i}:00:00Z',
        });
      }
      if (i < 2 && episode < 3) {
        model.store.save('watched', model.watchedKey(record), {
          'watched': true,
        });
      }
    }
  }
  model.store.setLocal('sources', [
    {
      'id': 'gallery-nas',
      'kind': 'smb',
      'label': '家里的媒体库',
      'host': 'nas.local',
      'share': 'Anime',
      'user': 'viewer',
      'domain': '',
    },
    {
      'id': 'gallery-webdav',
      'kind': 'webdav',
      'label': '我的云端收藏',
      'url': 'https://media.example.test/dav/',
      'user': '',
    },
  ]);
}
