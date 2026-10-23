import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveHttp extends HttpOverrides {}

// Read-only external integration, explicitly enabled with a private local JSON
// config containing url, username, password and path. Only the supplied folder
// is listed. Committed fixtures and reports contain no source credentials.
void main() {
  final configPath = Platform.environment['AIPLAYER_LIVE_WEBDAV_CONFIG'];
  for (final seed in ['parsed', 'identified', 'stale-titles']) {
    final identified = seed != 'parsed';
    final staleTitles = seed == 'stale-titles';
    testWidgets(
      'live WebDAV library completes $seed single episode without playback',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
        late Directory root;
        late AppStore store;
        late AppModel model;
        late String directory;
        late List<SourceEntry> videos;
        const anchorId = 'live-library-anchor';
        const sourceId = 'live-library-webdav';
        final report = <String, Object?>{
          'environment': 'Flutter widget test with real HTTP and disk database',
          'entry': 'LibraryPage primary card with one stored episode',
          'model': 'production AppModel and LibraryCatalog',
          'identifiedSeed': identified,
          'staleEpisodeTitleCache': staleTitles,
          'automaticBackgroundMaintenance': false,
          'nativeVideoPreviews': false,
          'frameRateMeasured': false,
          'passed': false,
        };
        final elapsed = Stopwatch()..start();
        var setupStage = 'WebDAV listing';

        void stage(String value) {
          report['lastStage'] = value;
          debugPrintSynchronously('Live $seed: $value');
        }

        Future<void> saveReport() async {
          final output = Platform.environment['AIPLAYER_LIVE_WEBDAV_REPORT'];
          if (output == null || output.isEmpty) return;
          await tester.runAsync(
            () => File(
              '$output-$seed.json',
            ).writeAsString(const JsonEncoder.withIndent('  ').convert(report)),
          );
        }

        Future<void> waitFor(bool Function() ready, String stage) async {
          final waiting = Stopwatch()..start();
          debugPrintSynchronously('Live $seed: waiting for $stage');
          var loops = 0;
          while (!ready()) {
            if (waiting.elapsed > const Duration(seconds: 90)) {
              report['failedStage'] = stage;
              fail('Timed out waiting for $stage.');
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            if (loops == 0) {
              debugPrintSynchronously('Live $seed: first pump for $stage');
            }
            await tester.pump(const Duration(milliseconds: 25));
            if (loops++ == 0) {
              debugPrintSynchronously('Live $seed: first pump complete');
            }
          }
          debugPrintSynchronously('Live $seed: completed $stage');
        }

        await tester.runAsync(() async {
          final config =
              jsonDecode(await File(configPath!).readAsString())
                  as Map<String, dynamic>;
          FlutterSecureStorage.setMockInitialValues({
            'source:$sourceId': config['password'] as String,
          });
          root = await Directory.systemTemp.createTemp('live-library-open-');
          directory = (config['path'] as String)
              .replaceFirst(RegExp(r'^/+'), '')
              .replaceFirst(RegExp(r'/*$'), '/');
          store = AppStore('${root.path}/library.db')
            ..setLocal('sources', [
              {
                'id': sourceId,
                'kind': 'webdav',
                'label': 'Live WebDAV',
                'url': config['url'],
                'user': config['username'],
              },
            ]);
          model = AppModel(store, root, backgroundWork: false);
          final connection = await model.adapter(sourceId);
          try {
            videos =
                (await connection.list(directory))
                    .where((entry) => !entry.directory && isVideo(entry.name))
                    .toList()
                  ..sort((a, b) => a.name.compareTo(b.name));
          } finally {
            await connection.close();
          }
          expect(videos, hasLength(3));
          final first = videos.first;
          final identity = model.mediaIdentity(first);
          store.save('media', anchorId, {
            'title': first.name,
            'fileName': first.name,
            'series': identity.anime,
            'season': identity.season,
            'episode': identity.episode,
            'size': first.size,
            'duration': 0,
          });
          store.setLocal('location:$anchorId', {
            'id': anchorId,
            'source': sourceId,
            'path': first.path,
            'size': first.size,
            'modified': first.modified,
          });
          if (identified) {
            final collection = identifyDirectory(directory, videos)!;
            setupStage = 'catalogue subject';
            final subject = await model.catalog.resolve(
              collection.title,
              collection.season,
            );
            expect(subject, isNotNull);
            setupStage = 'catalogue episode names';
            final names = await model.catalog.episodeNames(
              '${subject!['id']}',
              subject: subject,
            );
            model.applyCollectionMetadata(
              anchorId,
              collection.withMetadata(subject, names),
              first,
            );
            if (staleTitles) {
              expect(subject['provider'] ?? 'bangumi', 'bangumi');
              expect(names['1'], isNotEmpty);
              final stale = {'1': names['1']!};
              store.setLocal(
                'catalog-v1:bangumi:episodes:${subject['id']}',
                stale,
              );
              // Disk-backed CatalogCache reads the store before its memory
              // fallback. Assert the stale fixture is observable, rather than
              // accidentally testing the freshly downloaded complete names.
              final cached = await model.catalog.episodeNames(
                '${subject['id']}',
                subject: subject,
              );
              expect(cached, stale);
              report['cachedEpisodeTitlesBeforeOpen'] = cached.length;
            }
          }
          final before = await model.loadLibrarySnapshot();
          expect(before.media, hasLength(1));
          if (identified) {
            expect(
              before.byId[anchorId]!.data['bangumiId'] ??
                  before.byId[anchorId]!.data['tmdbId'],
              isNotNull,
            );
          }
          expect(store.records('progress'), isEmpty);
          expect(
            await model.catalog.loadDirectoryPreview(sourceId, directory),
            isNull,
          );
          report['storedEpisodesBeforeOpen'] = before.media.length;
          report['directoryPreviewCachedBeforeOpen'] = false;
        });
        try {
          stage('seed prepared');
          final setupError = tester.takeException();
          if (setupError != null) {
            report['failedStage'] = 'seed setup: $setupStage';
            report['failureType'] = setupError.runtimeType.toString();
            throw setupError;
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: GlassPalette.theme(),
              home: LibraryPage(model: model),
            ),
          );
          final card = find.byKey(const ValueKey('play:$anchorId'));
          await waitFor(() => card.evaluate().isNotEmpty, 'library card');
          await tester.tap(card);
          stage('card opened');
          final header = find.byType(MediaDetailsOverview);
          await waitFor(
            () =>
                header.evaluate().isNotEmpty &&
                tester
                        .widget<MediaDetailsOverview>(header)
                        .details
                        .availableEpisodes ==
                    3,
            'all three episodes in the visible library details',
          );
          final complete = tester.widget<MediaDetailsOverview>(header);
          report['completeEpisodesMs'] = elapsed.elapsedMilliseconds;
          report['availableEpisodes'] = complete.details.availableEpisodes;
          report['episodeNumbers'] = complete.records
              .map((item) => '${item.data['episode']}')
              .toList();
          report['metadataPresentAtCompletion'] =
              complete.details.provider.isNotEmpty;
          expect(complete.records.map((item) => '${item.data['episode']}'), [
            '1',
            '2',
            '3',
          ]);
          await saveReport();
          stage('three records visible; waiting for episode metadata');
          await waitFor(() {
            if (header.evaluate().isEmpty) return false;
            final overview = tester.widget<MediaDetailsOverview>(header);
            return overview.details.provider.isNotEmpty &&
                overview.details.summary.isNotEmpty &&
                overview.records.every(
                  (item) =>
                      '${store.local('episodeTitle:${item.id}') ?? item.data['episodeTitle'] ?? ''}'
                          .isNotEmpty,
                );
          }, 'catalogue metadata and all episode titles');
          final enriched = tester.widget<MediaDetailsOverview>(header);
          stage('series metadata and all titles complete');
          report['enrichedMs'] = elapsed.elapsedMilliseconds;
          report['metadataTitle'] = enriched.details.title;
          report['metadataProvider'] = enriched.details.provider;
          report['summaryLength'] = enriched.details.summary.length;
          report['hasPoster'] = enriched.details.poster.isNotEmpty;
          report['episodeTitles'] = enriched.records
              .map(
                (item) =>
                    '${store.local('episodeTitle:${item.id}') ?? item.data['episodeTitle'] ?? ''}',
              )
              .toList();
          final list = find.byKey(const ValueKey('series-details-list'));
          final scrollable = find.descendant(
            of: list,
            matching: find.byType(Scrollable),
          );
          for (final item in enriched.records) {
            stage('scroll to episode ${item.data['episode']}');
            final tile = find.byKey(ValueKey('series-episode:${item.id}'));
            await tester.scrollUntilVisible(tile, 250, scrollable: scrollable);
            final title =
                '${store.local('episodeTitle:${item.id}') ?? item.data['episodeTitle']}';
            expect(
              find.descendant(of: tile, matching: find.textContaining(title)),
              findsOneWidget,
            );
          }
          report['allEpisodeRowsScrolledAndChecked'] = true;
          stage('all three rendered rows checked');
          LibrarySnapshot? snapshot;
          Object? snapshotError;
          await tester.runAsync(() async {
            // A scroll notification may already have requested this shared
            // snapshot inside FakeAsync. Keep pumping while its worker reply
            // settles instead of waiting for that fake-zone future in runAsync.
            unawaited(
              model.loadLibrarySnapshot().then<void>(
                (value) => snapshot = value,
                onError: (Object error) => snapshotError = error,
              ),
            );
          });
          await waitFor(
            () => snapshot != null || snapshotError != null,
            'post-scroll library snapshot',
          );
          if (snapshotError != null) throw snapshotError!;
          expect(snapshot!.media, hasLength(3));
          expect(snapshot!.preparationIsolate, isNot(Isolate.current.hashCode));
          expect(find.byType(PlayerPage), findsNothing);
          expect(store.records('progress'), isEmpty);
          report['snapshotPreparedInWorker'] = true;
          report['progressRecords'] = store.records('progress').length;
          expect(tester.takeException(), isNull);
          report['passed'] = true;
        } finally {
          report['seriesDiagnostics'] = AppLog.instance.entries
              .where((entry) => entry.scope.contains('系列'))
              .map(
                (entry) => {
                  'scope': entry.scope,
                  'message': entry.message.replaceAll(
                    RegExp(r'https?://\S+'),
                    '[redacted URL]',
                  ),
                },
              )
              .toList();
          stage('remove widget');
          await tester.pumpWidget(const SizedBox());
          stage('dispose model');
          model.dispose();
          await tester.pump(const Duration(seconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          stage('save report and close database');
          await saveReport();
          await tester.runAsync(() async {
            store.dispose();
            await root.delete(recursive: true);
          });
        }
      }, _LiveHttp()),
      skip: configPath == null || configPath.isEmpty,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
