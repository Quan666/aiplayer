import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _poster = 'https://layout.invalid/local-app-cover.png';
const _stories = [
  (
    name: 'short',
    series: '某暗部的少女共栖',
    episode: '道具（ITEM）',
    number: 1,
    rating: 7.1,
    total: 14,
    genres: <String>[],
    summary:
        '位于东京西部的巨大学园都市。'
        '在这座人口多达230万，其中约八成都是学生的城市，实施着为开发超能力而设计的特殊课程，'
        '学生们的能力从无能力（Level 0）到超能力（Level 5），被划分为六个等级。',
  ),
  (
    name: 'long',
    series: '被放逐的作弊赋予魔术师享受随心所欲的第二人生。',
    episode: '陪两年没出门的伙伴去道歉，对方居然端出兔子造型苹果，那意思就是原谅了吧。',
    number: 3,
    rating: 9.5,
    total: 12,
    genres: ['动画', '喜剧', '动作冒险', 'Sci-Fi & Fantasy'],
    summary:
        '强化赋予魔术师雷恩，某天突然被公会流放。但他非但没有绝望，'
        '反而觉得“现在我什么都能做了”，于是收回了之前赋予在公会成员装备上的大量强化点数，'
        '作为冒险者踏上了崭新的人生道路。聚集在他身边的，有同伴被杀尽而封闭内心的天才冒险者。',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late AppModel model;

  setUpAll(() async {
    await Future.wait([
      (FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load(),
      (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load(),
    ]);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('details-header-layout-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = AppModel(store, directory);
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  for (final story in _stories) {
    for (final scenario in [
      (width: 390.0, scale: 1.0, poster: true),
      (width: 320.0, scale: 1.0, poster: true),
      (width: 320.0, scale: 2.0, poster: true),
      (width: 390.0, scale: 2.0, poster: true),
      (width: 390.0, scale: 1.0, poster: false),
      (width: 1080.0, scale: 1.0, poster: true),
    ]) {
      testWidgets('${story.name} details stay compact at ${scenario.width}px, '
          'text scale ${scenario.scale}, poster ${scenario.poster}', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(scenario.width, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        store.save('media', 'layout-episode', {
          'series': story.series,
          'metadataTitle': story.series,
          'title': 'Example S01E0${story.number}.mp4',
          'season': '1',
          'episode': '${story.number}',
          'episodeTitle': story.episode,
          'duration': 1420,
          'size': 315516518,
        });
        final record = store.get('media', 'layout-episode')!;
        const MediaTechnicalInfo(
          container: 'MP4 / MOV',
          codec: 'H.264',
          width: 1920,
          height: 1080,
        ).save(store, record);
        store.save('progress', model.progressKey(record), {
          'position': 53,
          'duration': 1420,
          'updatedAt': '2026-10-23T07:20:00Z',
        });
        if (scenario.poster) {
          // Exercise the real cache and decoder with a bundled local image;
          // no remote request or permanently disabled artwork placeholder.
          await tester.runAsync(() async {
            await model.posterCache.restore(
              _poster,
              await File('assets/branding/app_icon.png').readAsBytes(),
            );
          });
          await tester.pumpWidget(
            MaterialApp(theme: GlassPalette.theme(), home: const SizedBox()),
          );
          final context = tester.element(find.byType(SizedBox).last);
          await tester.runAsync(
            () => precacheImage(
              artworkImage(model.posterCache.resolvedFile(_poster)!, 128),
              context,
            ),
          );
        }
        final boundary = GlobalKey();
        var matches = 0;
        var plays = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(scenario.width, 1000),
                  textScaler: TextScaler.linear(scenario.scale),
                ),
                child: SingleChildScrollView(
                  child: RepaintBoundary(
                    key: boundary,
                    child: ColoredBox(
                      color: GlassPalette.theme().scaffoldBackgroundColor,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            MediaDetailsHeader(
                              model: model,
                              records: [record],
                              details: MediaCollectionDetails(
                                title: story.series,
                                poster: scenario.poster ? _poster : '',
                                summary: story.summary,
                                provider: '',
                                rating: story.rating,
                                totalEpisodes: story.total,
                                year: '2026',
                                availableEpisodes: 1,
                                videoCount: 1,
                                genres: [
                                  ...story.genres,
                                  if (scenario.scale > 1)
                                    'An unusually long category for narrow displays',
                                ],
                              ),
                              onMatch: () => matches++,
                            ),
                            MediaDetailsContinue(
                              model: model,
                              latest: record,
                              onPlay: (_) => plays++,
                            ),
                            MediaDetailsPlaylistHeader(onSort: () {}),
                            MediaDetailsEpisodeTile(
                              model: model,
                              item: record,
                              onPlay: () => plays++,
                              showTechnical: false,
                              trailing: IconButton(
                                onPressed: () {},
                                icon: const Icon(Icons.more_vert),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (scenario.poster) {
          expect(
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((image) => image.image != null),
            isTrue,
            reason: 'The preview must contain decoded local artwork.',
          );
        }
        expect(tester.takeException(), isNull);

        final header = tester.getRect(find.byType(MediaDetailsHeader));
        final title = find.text(story.series);
        expect(title, findsOneWidget);
        expect(tester.widget<Text>(title).maxLines, isNull);
        expect(tester.widget<Text>(title).overflow, isNull);
        final titleRect = tester.getRect(title);
        final rating = tester.getRect(find.text('评分 ${story.rating}'));
        final availability = tester.getRect(find.text('已收录 1 集'));
        if (scenario.poster) {
          final artwork = tester.getRect(
            find.descendant(
              of: find.byType(MediaDetailsHeader),
              matching: find.byType(MediaArtwork),
            ),
          );
          expect(titleRect.left, greaterThan(artwork.right));
          if (story.name == 'short' &&
              scenario.width == 390 &&
              scenario.scale == 1) {
            expect(rating.left, greaterThan(artwork.right));
            expect(rating.top, lessThan(artwork.bottom));
            expect(availability.left, greaterThan(artwork.right));
            expect(availability.bottom, lessThanOrEqualTo(artwork.bottom + 24));
          }
          if (rating.top < artwork.bottom) {
            expect(rating.left, greaterThan(artwork.right));
          } else {
            expect(rating.left, lessThanOrEqualTo(header.left + 28));
          }
        } else {
          expect(titleRect.left, header.left);
          expect(availability.left, header.left);
        }
        for (final content in [
          find.textContaining('MP4 · H.264 · 1920 × 1080'),
          find.text(story.summary),
        ]) {
          expect(tester.getRect(content).left, header.left);
          final box = tester.renderObject<RenderBox>(content);
          expect(box.constraints.maxWidth, header.width);
        }
        for (final label in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(MediaDetailsHeader),
            matching: find.byType(Text),
          ),
        )) {
          final rect = tester.getRect(find.byWidget(label));
          expect(rect.left, greaterThanOrEqualTo(header.left - .01));
          expect(rect.right, lessThanOrEqualTo(header.right + .01));
        }
        final match = find.byTooltip('匹配海报与简介');
        expect(tester.getRect(match).right, closeTo(header.right, 4));
        await tester.tap(match);
        expect(matches, 1);

        if (scenario.scale == 1) {
          final summary = tester.getRect(find.text(story.summary));
          final expand = tester.getRect(
            find.widgetWithText(TextButton, '展开简介'),
          );
          final resume = tester.getRect(
            find.byKey(const ValueKey('series-continue')),
          );
          final playlist = tester.getRect(
            find.byType(MediaDetailsPlaylistHeader),
          );
          final episode = tester.getRect(find.byType(MediaDetailsEpisodeTile));
          expect(expand.top - summary.bottom, inInclusiveRange(0, 4));
          expect(resume.top - header.bottom, inInclusiveRange(0, 6));
          expect(playlist.top - resume.bottom, inInclusiveRange(0, 6));
          expect(episode.top - playlist.bottom, inInclusiveRange(0, 4));
          if (story.name == 'short' && scenario.width == 390) {
            expect(episode.bottom - header.top, lessThan(510));
          }
          await tester.tap(find.byKey(const ValueKey('series-continue')));
          expect(plays, 1);
        }

        final preview = Platform.environment['DETAILS_LAYOUT_PREVIEW_DIR'];
        if (preview != null && scenario.poster) {
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '$preview/${story.name}-${scenario.width.toInt()}-${scenario.scale.toInt()}x.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
