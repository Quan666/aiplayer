import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_file_details.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/media_file_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DetailsModel extends AppModel {
  int opens = 0;
  _DetailsModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async => store.all('media');

  @override
  void ensureMediaPreview(String id) {}

  @override
  Future<SourceAdapter> adapter(String id) async {
    opens++;
    throw const AppFailure('文件不可访问');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaFileDetails details([String name = 'Episode.mp4']) => MediaFileDetails(
    fileName: name,
    size: 4096,
    format: 'MP4',
    properties: {'时长': '00:23:45.120'},
    tracks: [
      MediaFileTrackDetails(
        type: 'video',
        id: 1,
        properties: {'编码': 'H.264', '分辨率': '1920 × 1080'},
      ),
      MediaFileTrackDetails(
        type: 'audio',
        id: 2,
        properties: {'编码': 'AAC', '采样率': '48000 Hz'},
      ),
      MediaFileTrackDetails(
        type: 'sub',
        id: 3,
        properties: {'编码': 'ASS', '语言': '中文'},
      ),
    ],
    metadata: {'encoder': 'fixture-encoder'},
  );

  Future<void> open(
    WidgetTester tester,
    MediaFileDetailsLoader load, {
    Listenable? invalidation,
    Object Function()? revision,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showGlassBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => MediaFileDetailsSheet(
                  load: load,
                  invalidation: invalidation,
                  revision: revision,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'live details show all tracks and container metadata in a lazy list',
    (tester) async {
      var reads = 0;
      final pending = Completer<MediaFileDetails>();
      await open(tester, (_) {
        reads++;
        return pending.future;
      });
      expect(reads, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.complete(details());
      await tester.pumpAndSettle();
      expect(find.text('Episode.mp4'), findsOneWidget);
      expect(find.text('MP4'), findsOneWidget);
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('file-parameter-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final value in ['H.264', '48000 Hz', '中文', 'fixture-encoder']) {
        await tester.scrollUntilVisible(
          find.text(value),
          150,
          scrollable: scrollable,
        );
        expect(find.text(value), findsOneWidget);
      }
      expect(reads, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing cancels pending work and ignores late completion', (
    tester,
  ) async {
    final pending = Completer<MediaFileDetails>();
    late CancelToken token;
    await open(tester, (cancel) {
      token = cancel;
      return pending.future;
    });
    await tester.tap(find.byTooltip('关闭文件详情'));
    await tester.pumpAndSettle();
    expect(token.cancelled, isTrue);
    pending.complete(details());
    await tester.pump();
    expect(find.byKey(const ValueKey('media-file-details')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background cancels and foreground resumes one fresh read', (
    tester,
  ) async {
    final requests = <Completer<MediaFileDetails>>[];
    final tokens = <CancelToken>[];
    await open(tester, (cancel) {
      tokens.add(cancel);
      final result = Completer<MediaFileDetails>();
      requests.add(result);
      return result.future;
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tokens.single.cancelled, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(requests, hasLength(2));
    requests.first.complete(details('stale.mp4'));
    requests.last.complete(details('current.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('current.mp4'), findsOneWidget);
    expect(find.text('stale.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'source revision cancels stale results without rereading unrelated updates',
    (tester) async {
      final invalidation = ChangeNotifier();
      var revision = 0, reads = 0;
      final pending = Completer<MediaFileDetails>();
      late CancelToken token;
      await open(
        tester,
        (cancel) {
          reads++;
          token = cancel;
          return reads == 1
              ? pending.future
              : Future.value(details('fresh.mkv'));
        },
        invalidation: invalidation,
        revision: () => revision,
      );
      invalidation.notifyListeners();
      await tester.pump();
      expect(token.cancelled, isFalse);
      revision++;
      invalidation.notifyListeners();
      await tester.pump();
      expect(token.cancelled, isTrue);
      pending.complete(details('stale.mp4'));
      await tester.pump();
      expect(find.text('stale.mp4'), findsNothing);
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('fresh.mkv'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      invalidation.dispose();
    },
  );

  testWidgets('library episode menu probes only after selecting file details', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync('file-details-menu-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _DetailsModel(store, directory);
    for (var number = 1; number <= 3; number++) {
      store.save('media', 'episode-$number', {
        'title': 'Series S01E0$number.mp4',
        'fileName': 'Series S01E0$number.mp4',
        'series': 'Series',
        'season': '1',
        'episode': '$number',
      });
      store.setLocal('location:episode-$number', {
        'source': 'local',
        'path': '${directory.path}/$number.mp4',
      });
    }
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: LibraryPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pumpAndSettle();
      final tile = find.byType(MediaDetailsEpisodeTile).first;
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      expect(model.opens, 0);
      await tester.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看文件详情'), findsOneWidget);
      expect(model.opens, 0);
      await tester.tap(find.text('查看文件详情'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-file-details')), findsOneWidget);
      expect(model.opens, 1);
      expect(store.all('progress'), isEmpty);
      expect(model.activePlaybackMediaId, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'resuming waits for the cancelled probe to retire before rereading',
    (tester) async {
      final cleanup = Completer<void>();
      final tokens = <CancelToken>[];
      var reads = 0, opens = 0;
      final service = MediaFileDetailsService(
        probe: (_, cancel) async {
          reads++;
          tokens.add(cancel);
          if (reads == 1) {
            await cancel.whenCancelled;
            await cleanup.future;
            throw const Cancelled();
          }
          return MediaFileProbeResult(container: 'mov,mp4');
        },
      );
      try {
        await open(tester, (cancel) async {
          await service.waitUntilIdle(cancel);
          return service.inspect(
            openSource: () async {
              opens++;
              return _FileDetailsLocalSource();
            },
            path: '/current.mp4',
            cancel: cancel,
          );
        });
        expect(reads, 1);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(tokens.single.cancelled, isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(reads, 1);
        expect(opens, 1);
        expect(find.textContaining('正在读取其它文件'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        cleanup.complete();
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(opens, 2);
        expect(find.text('current.mp4'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('重新读取'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!cleanup.isCompleted) cleanup.complete();
        await tester.pumpWidget(const SizedBox());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}

class _FileDetailsLocalSource extends LocalSource {
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: 'current.mp4', path: path, size: 1024);
}
