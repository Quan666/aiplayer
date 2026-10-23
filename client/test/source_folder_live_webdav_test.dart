import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveHttp extends HttpOverrides {}

// Explicit opt-in: the config is a private local JSON file with url, username,
// password and path. Only that directory is listed; credentials never enter
// test output or committed fixtures. Ordinary test runs skip external access.
void main() {
  final configPath = Platform.environment['AIPLAYER_LIVE_WEBDAV_CONFIG'];
  testWidgets(
    'live WebDAV first open imports and enriches a series without playback',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      late Directory root;
      late AppStore store;
      late AppModel model;
      late Map<String, dynamic> source;
      late String directory;
      var plays = 0;
      final report = <String, Object?>{
        'environment': 'Flutter widget test with real HTTP and disk database',
        'entry': 'SourceBrowser direct first entry to the supplied folder',
        'model': 'production AppModel and LibraryCatalog',
        'automaticBackgroundMaintenance': false,
        'nativeVideoPreviews': false,
        'frameRateMeasured': false,
      };
      final elapsed = Stopwatch()..start();

      Future<void> saveReport() async {
        final output = Platform.environment['AIPLAYER_LIVE_WEBDAV_REPORT'];
        if (output == null || output.isEmpty) return;
        await tester.runAsync(
          () => File(
            output,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report)),
        );
      }

      Future<void> waitFor(bool Function() ready, String stage) async {
        final waiting = Stopwatch()..start();
        while (!ready()) {
          if (waiting.elapsed > const Duration(seconds: 100)) {
            report['failedStage'] = stage;
            fail('Timed out waiting for $stage.');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
      }

      await tester.runAsync(() async {
        final config =
            jsonDecode(await File(configPath!).readAsString())
                as Map<String, dynamic>;
        FlutterSecureStorage.setMockInitialValues({
          'source:live-webdav': config['password'] as String,
        });
        root = await Directory.systemTemp.createTemp('live-first-open-');
        source = {
          'id': 'live-webdav',
          'kind': 'webdav',
          'label': 'Live WebDAV',
          'url': config['url'],
          'user': config['username'],
        };
        directory = (config['path'] as String)
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceFirst(RegExp(r'/*$'), '/');
        store = AppStore('${root.path}/library.db')
          ..setLocal('sources', [source]);
        model = AppModel(store, root, backgroundWork: false);
        final before = await model.loadLibrarySnapshot();
        expect(before.media, isEmpty);
        expect(store.records('progress'), isEmpty);
        report['emptyMediaBeforeOpen'] = true;
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: source,
              initialPath: directory,
              initialName: directory.split('/').where((x) => x.isNotEmpty).last,
              onPlay: (_) async => plays++,
            ),
          ),
        );
        final header = find.byType(MediaDetailsOverview);
        await waitFor(
          () => header.evaluate().isNotEmpty,
          'parsed series header',
        );
        final parsed = tester.widget<MediaDetailsOverview>(header);
        report['firstHeaderMs'] = elapsed.elapsedMilliseconds;
        report['firstTitle'] = parsed.details.title;
        report['firstHeaderAlreadyEnriched'] =
            parsed.details.provider.isNotEmpty;
        report['episodesAtFirstHeader'] = parsed.details.availableEpisodes;
        await saveReport();
        expect(parsed.details.availableEpisodes, 3);
        expect(parsed.records.map((item) => item.data['episode']), [
          '1',
          '2',
          '3',
        ]);
        expect(plays, 0);
        expect(store.records('progress'), isEmpty);

        await waitFor(() {
          if (header.evaluate().isEmpty) return false;
          final overview = tester.widget<MediaDetailsOverview>(header);
          return overview.details.provider.isNotEmpty &&
              overview.details.summary.isNotEmpty &&
              overview.details.poster.isNotEmpty;
        }, 'real catalogue metadata in the visible header');
        final enriched = tester.widget<MediaDetailsOverview>(header);
        report['enrichedHeaderMs'] = elapsed.elapsedMilliseconds;
        report['metadataTitle'] = enriched.details.title;
        report['metadataProvider'] = enriched.details.provider;
        report['summaryLength'] = enriched.details.summary.length;
        report['hasPoster'] = enriched.details.poster.isNotEmpty;
        report['availableEpisodes'] = enriched.details.availableEpisodes;
        report['catalogueIds'] = enriched.records
            .map((item) => item.data['bangumiId'] ?? item.data['tmdbId'])
            .toSet()
            .toList();
        expect(enriched.details.availableEpisodes, 3);
        expect(find.byType(PlayerPage), findsNothing);
        expect(plays, 0);
        expect(store.records('progress'), isEmpty);
        final snapshot = (await tester.runAsync(
          () => model.loadLibrarySnapshot(),
        ))!;
        expect(snapshot.media, hasLength(3));
        expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
        report['snapshotPreparedInWorker'] = true;
        report['playCalls'] = plays;
        report['progressRecords'] = store.records('progress').length;
        report['passed'] = true;
        expect(tester.takeException(), isNull);
      } finally {
        report['diagnostics'] = AppLog.instance.entries
            .map((entry) => {'scope': entry.scope, 'message': entry.message})
            .toList();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        // Production disposal cancels real poster transfers asynchronously.
        // Drain their bounded timeouts before Flutter checks its fake timers.
        await tester.pump(const Duration(seconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final output = Platform.environment['AIPLAYER_LIVE_WEBDAV_REPORT'];
          if (output != null && output.isNotEmpty) {
            await File(
              output,
            ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
          }
          store.dispose();
          await root.delete(recursive: true);
        });
      }
    }, _LiveHttp()),
    skip: configPath == null || configPath.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
