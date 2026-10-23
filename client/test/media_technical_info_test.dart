import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  setUp(() => store = AppStore(':memory:'));
  tearDown(() => store.dispose());

  test('native container and codec aliases use consistent names', () {
    expect(videoContainerLabel('mkv'), 'Matroska');
    expect(videoContainerLabel('matroska,webm'), 'Matroska');
    expect(videoContainerLabel('mov,mp4,m4a,3gp,3g2,mj2'), 'MP4 / MOV');
    expect(videoCodecLabel('h264'), 'H.264');
    expect(videoCodecLabel('hevc'), 'H.265 / HEVC');
    expect(videoContainerLabel(''), isEmpty);
    expect(videoCodecLabel(''), isEmpty);
  });

  SyncRecord record({
    String id = 'one',
    Map<String, dynamic> extra = const {},
  }) {
    store.save('media', id, {
      'title': 'Example S01E03.1080p.mkv',
      'fileName': 'Example S01E03.1080p.mkv',
      'series': 'Example',
      'metadataTitle': '正式作品',
      'season': '1',
      'episode': '3',
      'size': 1073741824,
      ...extra,
    });
    return store.get('media', id)!;
  }

  test(
    'unplayed files show only known size, extension and an explicit filename hint',
    () {
      final media = record();
      final info = MediaTechnicalInfo.forRecord(store, media);
      expect(info.label, 'MKV · 1080p（文件名标注） · 1.00 GiB');
      expect(info.codec, isEmpty);
      expect(info.bitrate, isNull);
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.duration, isNull);
      expect(store.local('technical:one'), isNull);
    },
  );

  test(
    'verified file facts replace filename guesses and repeated samples do not rewrite',
    () {
      final media = record();
      const sampled = MediaTechnicalInfo(
        container: 'Matroska',
        codec: 'H.265 / HEVC',
        width: 3840,
        height: 2160,
        bitrate: 12500000,
        duration: 125.5,
      );
      expect(sampled.save(store, media), isTrue);
      expect(sampled.save(store, media), isFalse);
      final info = MediaTechnicalInfo.forRecord(store, media);
      expect(
        info.label,
        'Matroska · H.265 / HEVC · 3840 × 2160 · 视频约 12.5 Mb/s · 1.00 GiB',
      );
      expect(info.duration, 125.5);
      expect(info.resolutionHint, isEmpty);
      expect(store.get('media', media.id)!.data.containsKey('codec'), isFalse);
    },
  );

  test(
    'replacing a file invalidates cached facts even for the same media id',
    () {
      final media = record();
      store.setLocal('location:one', {
        'source': 'nas',
        'path': 'one.mkv',
        'size': 100,
        'modified': 1,
      });
      const MediaTechnicalInfo(
        codec: 'H.264',
        width: 1920,
        height: 1080,
        bitrate: 8000000,
      ).save(store, media);
      for (final next in [
        {'source': 'nas', 'path': 'one.mkv', 'size': 101, 'modified': 1},
        {'source': 'nas', 'path': 'one.mkv', 'size': 100, 'modified': 2},
        {
          'source': 'nas',
          'path': 'replacement.mkv',
          'size': 100,
          'modified': 1,
        },
      ]) {
        store.setLocal('location:one', next);
        final info = MediaTechnicalInfo.forRecord(store, media);
        expect(info.codec, isEmpty);
        expect(info.bitrate, isNull);
        expect(info.width, isNull);
      }
    },
  );

  test('verified specifications survive reopening local storage', () {
    final root = Directory.systemTemp.createTempSync('aiplayer-spec-cache-');
    var saved = AppStore('${root.path}/test.db');
    try {
      saved.save('media', 'cached', {
        'title': 'Example.mp4',
        'fileName': 'Example.mp4',
        'size': 1024,
      });
      const MediaTechnicalInfo(
        container: 'MP4 / MOV',
        codec: 'AV1',
        width: 1920,
        height: 1080,
        bitrate: 2000000,
        duration: 60.5,
      ).save(saved, saved.get('media', 'cached')!);
      saved.dispose();
      saved = AppStore('${root.path}/test.db');
      final restored = MediaTechnicalInfo.forRecord(
        saved,
        saved.get('media', 'cached')!,
      );
      expect(
        restored.label,
        'MP4 / MOV · AV1 · 1920 × 1080 · 视频约 2.0 Mb/s · 1.0 KiB',
      );
      expect(restored.duration, 60.5);
    } finally {
      saved.dispose();
      root.deleteSync(recursive: true);
    }
  });

  test(
    'cached decoder dimensions are reused and unavailable numeric values stay unknown',
    () {
      final media = record(extra: {'fileName': 'video.mp4', 'size': 0});
      expect(
        const MediaTechnicalInfo(
          width: -1,
          height: 0,
          bitrate: -1,
          duration: double.nan,
        ).save(store, media),
        isFalse,
      );
      final info = MediaTechnicalInfo.forRecord(
        store,
        media,
        dimensions: (width: 720, height: 1280),
        duration: 20.5,
      );
      expect(info.label, 'MP4 · 720 × 1280');
      expect(info.duration, 20.5);
      expect(info.bitrate, isNull);
      expect(info.size, isNull);
    },
  );

  test(
    'season labels hide the default season while keeping specials and confirmed multiple seasons',
    () {
      expect(mediaSeasonLabel('1'), isEmpty);
      expect(mediaSeasonLabel('01', totalSeasons: 1), isEmpty);
      expect(mediaSeasonLabel('1', totalSeasons: 2), '第 1 季');
      expect(mediaSeasonLabel('2'), '第 2 季');
      expect(mediaSeasonLabel('0'), '特别篇');
      expect(mediaDisplayTitle(record()), '正式作品 · 第 3 集');
      expect(
        mediaDisplayTitle(record(extra: {'season': '0'})),
        '正式作品 · 特别篇 · 第 3 集',
      );
      expect(
        MediaCollectionDetails.fromRecords([
          record(extra: {'totalSeasons': 3}),
        ]).seasonLabel,
        '第 1 季',
      );
    },
  );

  testWidgets(
    'single video details show its recognized title, episode and cached specification',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-single-spec-');
      final model = AppModel(store, root);
      final media = record();
      const MediaTechnicalInfo(
        codec: 'H.264',
        width: 1920,
        height: 1080,
        bitrate: 5000000,
      ).save(store, media);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: MediaDetailsHeader(
                model: model,
                details: MediaCollectionDetails.fromRecords([media]),
                records: [media],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('正式作品 · 第 3 集'), findsOneWidget);
        expect(
          find.textContaining('H.264 · 1920 × 1080 · 视频约 5.0 Mb/s'),
          findsOneWidget,
        );
        expect(find.textContaining('第 1 季'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'alternate resources for one episode remain distinguishable in library details',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-alternate-spec-',
      );
      final model = AppModel(store, root);
      final first = record(id: 'a');
      final second = record(
        id: 'b',
        extra: {'fileName': 'other.mp4', 'size': 2147483648},
      );
      const MediaTechnicalInfo(
        codec: 'H.264',
        width: 1920,
        height: 1080,
      ).save(store, first);
      const MediaTechnicalInfo(
        codec: 'AV1',
        width: 3840,
        height: 2160,
      ).save(store, second);
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('details:a')));
        await tester.pumpAndSettle();
        final rows = find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'series-episode:',
              ),
        );
        expect(rows, findsOneWidget);
        await tester.tap(
          find.descendant(
            of: rows,
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择视频版本'));
        await tester.pumpAndSettle();
        expect(
          find
              .textContaining('MKV · H.264 · 1920 × 1080 · 1.00 GiB')
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .textContaining('MP4 · AV1 · 3840 × 2160 · 2.00 GiB')
              .hitTestable(),
          findsOneWidget,
        );
        Navigator.of(
          tester.element(find.textContaining('MP4 · AV1').hitTestable()),
        ).pop();
        await tester.pumpAndSettle();
        expect(find.text('已收录 1 集 · 2 个视频'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );
}
