import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/metadata_match_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _Catalog extends LibraryCatalog {
  _Catalog(super.store);
  @override
  Future<List<Map<String, dynamic>>> search(
    String title, {
    String? source,
    CancelToken? cancel,
  }) async => [
    {
      'id': 1,
      'provider': 'bangumi',
      'name_cn': '星海漫游',
      'name': 'A Journey Through the Stars',
      'date': '2026-04-01',
    },
    {
      'id': 2,
      'provider': 'tmdb',
      'mediaType': 'tv',
      'name_cn': '星海漫游 第二季',
      'name': 'A Journey Through the Stars II',
      'date': '2026-10-01',
    },
    {
      'id': 3,
      'provider': 'tmdb',
      'mediaType': 'movie',
      'name_cn': '星海漫游：归途',
      'name': 'The Journey Home',
      'date': '2025-12-12',
    },
  ];
}

class _Model extends AppModel {
  _Model(super.store, super.documents);
  late final _fakeCatalog = _Catalog(store);
  @override
  LibraryCatalog get catalog => _fakeCatalog;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'render the metadata bottom sheet at phone size using a fake catalogue',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await (FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load();
      final root = await Directory.systemTemp.createTemp(
        'metadata-sheet-gallery-',
      );
      final store = AppStore('${root.path}/test.db')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final model = _Model(store, root);
      final boundaryKey = GlobalKey();
      final insets = ValueNotifier<double>(0);
      const size = Size(390, 844);
      for (var episode = 1; episode <= 3; episode++) {
        store.save('media', 'episode-$episode', {
          'title': '星海漫游 S01E0$episode.mkv',
          'fileName': '星海漫游 S01E0$episode.mkv',
          'series': '星海漫游',
          'season': '1',
          'episode': '$episode',
        });
      }
      Future<void> capture(String name) async {
        await tester.pump();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File('${Directory.current.path}/../artifacts/$name');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }

      try {
        await binding.setSurfaceSize(size);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: ValueListenableBuilder<double>(
              valueListenable: insets,
              builder: (_, bottom, child) => MediaQuery(
                data: MediaQueryData(
                  size: size,
                  devicePixelRatio: 1,
                  viewInsets: EdgeInsets.only(bottom: bottom),
                ),
                child: child!,
              ),
              child: AIPlayerApp(model: model),
            ),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          showMetadataMatchDialog(
            tester.element(find.text('我的影视库')),
            model,
            '星海漫游',
            season: '1',
            mediaIds: {'episode-1', 'episode-2', 'episode-3'},
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索资料'));
        await tester.pumpAndSettle();
        expect(find.text('星海漫游：归途'), findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('metadata-match-sheet')))
              .height,
          lessThan(600),
          reason: 'Three candidates should not leave a large empty lower half.',
        );
        expect(tester.takeException(), isNull);
        await capture('metadata-bottom-sheet.png');
        insets.value = 300;
        await tester.pumpAndSettle();
        expect(tester.getCenter(find.text('关闭')).dy, lessThan(544));
        expect(tester.takeException(), isNull);
        await capture('metadata-bottom-sheet-keyboard-inset.png');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await binding.setSurfaceSize(null);
        insets.dispose();
        model.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
