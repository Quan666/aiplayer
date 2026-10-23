import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _Catalog extends LibraryCatalog {
  _Catalog(super.store, {super.onPoster, super.aiFallback});

  Map<String, dynamic>? subject;

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async => subject;

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async => {};
}

class _Model extends AppModel {
  _Model(super.store, super.documents, this.artwork)
    : fakeCatalog = _Catalog(store),
      super(backgroundWork: false);

  final PosterCache artwork;
  final _Catalog fakeCatalog;

  @override
  PosterCache get posterCache => artwork;

  @override
  LibraryCatalog get catalog => fakeCatalog;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _Model model;
  late PosterCache cache;
  late HttpServer server;
  late Completer<void> requested;
  late List<int> png;
  Completer<void>? responseGate;
  var requests = 0;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('metadata-posters-');
    store = AppStore(':memory:');
    png = await File('assets/branding/app_icon.png').readAsBytes();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requested = Completer<void>();
    responseGate = null;
    requests = 0;
    server.listen((request) async {
      requests++;
      if (!requested.isCompleted) requested.complete();
      await responseGate?.future;
      if (request.uri.path == '/broken') {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.add(png);
      }
      await request.response.close();
    });
    cache = PosterCache(
      directory: Directory('${directory.path}/posters'),
      createClient: () =>
          HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()),
    );
    model = _Model(store, directory, cache);
  });

  tearDown(() async {
    if (responseGate?.isCompleted == false) responseGate!.complete();
    model.dispose();
    cache.close();
    await server.close(force: true);
    store.dispose();
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> subject({bool broken = false}) => {
    'id': 7,
    'provider': 'bangumi',
    'mediaType': 'tv',
    'name': 'Example',
    'images': {
      'large':
          'http://127.0.0.1:${server.port}/${broken ? 'broken' : 'poster'}',
    },
  };

  SyncRecord add(String id, {String episode = '1'}) {
    store.save('media', id, {
      'fileName': 'Example S01E$episode.mkv',
      'series': 'Example',
      'season': '1',
      'episode': episode,
    });
    return store.get('media', id)!;
  }

  for (final path in ['ordinary', 'manual', 'AI']) {
    test(
      '$path identification downloads unseen posters without waiting',
      () async {
        final first = add('one'), second = add('two', episode: '2');
        final metadata = subject();
        final url = '${metadata['images']['large']}';
        responseGate = Completer<void>();

        switch (path) {
          case 'ordinary':
            model.fakeCatalog.subject = metadata;
            await model.refreshMetadata().timeout(const Duration(seconds: 2));
          case 'manual':
            model.applyBangumi('Example', metadata);
          case 'AI':
            for (final record in [first, second]) {
              expect(
                await model
                    .identifyMediaWithAi(
                      record,
                      cancel: CancelToken(),
                      match: AiMetadataMatch(
                        AiMediaIdentity(
                          fileName: '${record.data['fileName']}',
                          name: 'Example',
                          season: '1',
                          episode: '${record.data['episode']}',
                          confidence: 1,
                        ),
                        [metadata],
                        metadata,
                      ),
                    )
                    .timeout(const Duration(seconds: 2)),
                isTrue,
              );
            }
        }

        expect(store.get('media', first.id)!.data['poster'], url);
        expect(store.get('media', second.id)!.data['poster'], url);
        // No MediaArtwork or other widget has been mounted and no explicit
        // cache read has occurred: identification itself started this download.
        await requested.future.timeout(const Duration(seconds: 2));
        expect(requests, 1);
        expect(cache.resolvedFile(url), isNull);
        responseGate!.complete();
        final file = await cache.load(url);
        expect(file, isNotNull);
        expect(await file!.readAsBytes(), png);
        expect(requests, 1);

        cache.close();
        cache = PosterCache(
          directory: cache.directory,
          createClient: () => throw StateError('Restarted offline'),
        );
        expect((await cache.load(url))?.path, file.path);
        expect(requests, 1);
      },
    );
  }

  test(
    'an unavailable poster does not undo successful identification',
    () async {
      final record = add('one');
      final metadata = subject(broken: true);
      model.fakeCatalog.subject = metadata;
      await model.refreshMetadata();
      await requested.future.timeout(const Duration(seconds: 2));
      expect(await cache.load('${metadata['images']['large']}'), isNull);
      expect(store.get('media', record.id)!.data['bangumiId'], '7');
      expect(model.metadataTasks.single.matched, 1);
      expect(model.metadataTasks.single.error, isEmpty);
    },
  );

  for (final viaAi in [false, true]) {
    test(
      'confirmed ${viaAi ? 'AI' : 'ordinary'} directories prefetch before import',
      () async {
        final metadata = subject();
        final entries = [
          for (var episode = 1; episode <= 2; episode++)
            SourceEntry(
              name: 'Example S01E0$episode.mkv',
              path: '/Example/Example S01E0$episode.mkv',
            ),
        ];
        final catalog = _Catalog(
          store,
          onPoster: (url) => unawaited(cache.load(url)),
          aiFallback: viaAi
              ? (_, path, files, _) async =>
                    identifyDirectory(path, files)!.withMetadata(metadata, {})
              : null,
        )..subject = viaAi ? null : metadata;
        final collection = await catalog.inspect('local', '/Example', entries);
        expect(collection?.poster, metadata['images']['large']);
        expect(model.media, isEmpty);
        await requested.future.timeout(const Duration(seconds: 2));
        expect(await cache.load(collection!.poster), isNotNull);
        await catalog.inspect('local', '/Example', entries);
        expect(requests, 1);
      },
    );
  }
}
