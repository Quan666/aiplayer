import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/playlist.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements JsonTransport {
  int requests = 0;
  final started = Completer<void>();
  Completer<void>? gate;
  CancelToken? token;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    requests++;
    token = cancel;
    if (!started.isCompleted) started.complete();
    if (gate != null) {
      await Future.any([
        gate!.future,
        if (cancel != null) cancel.whenCancelled,
      ]);
    }
    cancel?.check();
    return {
      'data': <dynamic>[],
      'list': <dynamic>[],
      'results': <dynamic>[],
      'total': 0,
    };
  }
}

class _ToggleModel extends AppModel {
  _ToggleModel(super.store, super.documents, this.transport)
    : super(backgroundWork: false);
  final _Transport transport;
  @override
  LibraryCatalog get catalog => controlled;
  late final controlled = LibraryCatalog(
    store,
    transport: transport,
    automaticEnabled: super.catalog.automaticEnabled,
    strategy: () => preferences.metadataStrategy,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stop in ['toggle', 'third-party', 'background', 'playback']) {
    test(
      'real model $stop cancels automatic recognition without another frame',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'automatic-stop-',
        );
        final store = AppStore(':memory:')
          ..setLocal('settings', {'autoIdentifyOnFolderOpen': true});
        final transport = _Transport()..gate = Completer<void>();
        final model = _ToggleModel(store, directory, transport);
        try {
          final work = model.catalog.resolve('Example', '1');
          final cancelled = expectLater(work, throwsA(isA<Cancelled>()));
          await transport.started.future;
          if (stop == 'toggle') {
            await model.updatePreferences({'autoIdentifyOnFolderOpen': false});
          } else if (stop == 'third-party') {
            await model.updatePreferences({
              'thirdPartyNetworkingEnabled': false,
            });
          } else if (stop == 'background') {
            model.setForeground(false);
          } else {
            model.activePlaybackMediaId = 'playing';
          }
          await cancelled;
          expect(transport.token!.cancelled, isTrue);
          final requests = transport.requests;
          transport.gate!.complete();
          if (stop == 'background') model.setForeground(true);
          if (stop == 'playback') model.activePlaybackMediaId = null;
          if (stop == 'third-party') {
            expect(await model.catalog.resolve('Another title', '1'), isNull);
            expect(transport.requests, requests);
            await model.updatePreferences({
              'thirdPartyNetworkingEnabled': true,
            });
          }
          await Future<void>.delayed(Duration.zero);
          expect(transport.requests, requests);
          expect(store.localEntries('subject-v5:'), isEmpty);
          if (stop == 'toggle') {
            expect(await model.catalog.resolve('Another title', '1'), isNull);
            expect(transport.requests, requests);
            transport.gate = null;
            await model.catalog.resolve('Manual lookup', '1', force: true);
            expect(transport.requests, greaterThan(requests));
          }
        } finally {
          model.dispose();
          store.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'passive disk-worker reconciliation does not import filename guesses',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'passive-directory-',
      );
      final store = await AppStore.open('${directory.path}/library.db');
      final model = AppModel(store, directory, backgroundWork: false);
      try {
        final parsed = await model.synchronizeDirectoryEntriesInBackground(
          'nas',
          'Show',
          const [
            SourceEntry(
              name: 'Example S01E01.mkv',
              path: 'Show/Example S01E01.mkv',
            ),
            SourceEntry(
              name: 'Example S01E02.mkv',
              path: 'Show/Example S01E02.mkv',
            ),
            SourceEntry(name: 'opaque.mkv', path: 'Show/opaque.mkv'),
          ],
        );
        expect(parsed, isNotNull);
        expect(parsed!.recognized, isFalse);
        expect(store.all('media'), isEmpty);
        expect(store.localEntries('location:'), isEmpty);
        expect(model.metadataTasks, isEmpty);
      } finally {
        model.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
  test('a preference write completing after disposal never rereads the closed UI database', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'preferences-disposal-',
    );
    final store = await AppStore.open('${directory.path}/library.db');
    final other = AppStore.openExisting(store.path);
    final model = AppModel(store, directory, backgroundWork: false);
    other.db.execute('BEGIN IMMEDIATE');
    final pending = model.updatePreferences({'autoIdentifyOnFolderOpen': true});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    model.dispose();
    store.dispose();
    other.db.execute('COMMIT');
    await pending;
    other.dispose();
    await directory.delete(recursive: true);
  });

  test('disabled automatic directory inspection is local, explicit lookup still works', () async {
    final store = AppStore(':memory:');
    final transport = _Transport();
    final catalog = LibraryCatalog(
      store,
      transport: transport,
      automaticEnabled: () => false,
    );
    try {
      await catalog.inspect('local', '/Example', const [
        SourceEntry(name: 'Example E01.mkv', path: '/Example/Example E01.mkv'),
      ]);
      expect(transport.requests, 0);
      expect(await catalog.resolve('Example', '1'), isNull);
      expect(transport.requests, 0);
      await catalog.resolve('Example', '1', force: true);
      expect(transport.requests, greaterThan(0));
    } finally {
      store.dispose();
    }
  });

  test(
    'revoking automatic permission cancels transport without another frame',
    () async {
      final store = AppStore(':memory:');
      var enabled = true;
      final transport = _Transport()..gate = Completer<void>();
      final catalog = LibraryCatalog(
        store,
        transport: transport,
        automaticEnabled: () => enabled,
      );
      try {
        final lookup = catalog.resolve('Example', '1');
        final cancelled = expectLater(lookup, throwsA(isA<Cancelled>()));
        await transport.started.future;
        enabled = false;
        catalog.cancelAutomaticRecognition();
        await cancelled;
        expect(transport.token!.cancelled, isTrue);
        final requests = transport.requests;
        enabled = true;
        await Future<void>.delayed(Duration.zero);
        expect(transport.requests, requests);
      } finally {
        store.dispose();
      }
    },
  );

  test('personal media registration avoids film library, auto-next and recognition', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('personal-media-');
    final store = await AppStore.open('${directory.path}/library.db');
    final model = AppModel(store, directory, backgroundWork: false);
    try {
      final first = await model.preparePersonalMediaForPlayback(
        'nas',
        const SourceEntry(
          name: 'Trip E01.mp4',
          path: '/Trip/Trip E01.mp4',
          size: 1,
        ),
      );
      await model.preparePersonalMediaForPlayback(
        'nas',
        const SourceEntry(
          name: 'Trip E02.mp4',
          path: '/Trip/Trip E02.mp4',
          size: 2,
        ),
      );
      expect(model.media, isEmpty);
      expect((await model.loadLibrarySnapshot()).media, isEmpty);
      expect(playbackPlaylist(model, first).map((item) => item.id), [first.id]);
      expect(await playbackNeighbors(store.path, first), (null, null));
      expect(model.automaticMetadataEnabled, isFalse);
      await model.updatePreferences({'metadataStrategy': 'off'});
      await model.updatePreferences({'autoIdentifyOnFolderOpen': true});
      expect(model.automaticMetadataEnabled, isTrue);
      expect(model.preferences.metadataStrategy, 'conservative');
      expect(model.metadataTasks, isEmpty);
    } finally {
      model.dispose();
      await model.flushMetadataTasks();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
}
