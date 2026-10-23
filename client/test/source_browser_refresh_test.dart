import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _WebDavModel extends AppModel {
  final String address;
  int reconciliations = 0;
  int preparations = 0;
  int completedCollections = 0;
  _WebDavModel(super.store, super.documents, this.address)
    : super(backgroundWork: false);

  @override
  LibraryCatalog get catalog => _trackedCatalog;
  late final _trackedCatalog = LibraryCatalog(
    store,
    strategy: () => 'off',
    prepareDirectory: (source, path, context, entries, cancel) async {
      final prepared = await super.catalog.prepareDirectory!(
        source,
        path,
        context,
        entries,
        cancel,
      );
      preparations++;
      return prepared;
    },
    persistDirectory: super.catalog.persistDirectory,
    readDirectory: super.catalog.readDirectory,
  );

  @override
  Future<SourceAdapter> adapter(String id) async =>
      HttpOverrides.runWithHttpOverrides(
        () => HttpSource(address, webdav: true),
        _RealHttp(),
      );

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) {
    reconciliations++;
    return super.synchronizeDirectoryEntriesInBackground(
      sourceId,
      path,
      entries,
      anchorId: anchorId,
      cancel: cancel,
    );
  }

  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    final result = await super.synchronizeCollectionInBackground(
      sourceId,
      value,
      importMissing: importMissing,
      anchorId: anchorId,
      cancel: cancel,
    );
    completedCollections++;
    return result;
  }
}

String _listing(String directory, int count) {
  final result = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  void entry(String path, bool folder) {
    result.write(
      '<d:response><d:href>${Uri(path: path)}</d:href>'
      '<d:propstat><d:prop><d:resourcetype>'
      '${folder ? '<d:collection/>' : ''}</d:resourcetype>'
      '<d:getcontentlength>42</d:getcontentlength>'
      '</d:prop></d:propstat></d:response>',
    );
  }

  entry(directory, true);
  if (directory == '/dav/') {
    entry('/dav/Series/', true);
  } else {
    for (var episode = 1; episode <= count; episode++) {
      entry(
        '/dav/Series/Example S01E${episode.toString().padLeft(2, '0')}.mkv',
        false,
      );
    }
  }
  return '$result</d:multistatus>';
}

Future<void> _settle(WidgetTester tester, bool Function() complete) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (complete()) return;
  }
  fail('Source listing and its background metadata did not settle.');
}

List<SourceEntry> _videos(int count) => [
  for (var episode = 1; episode <= count; episode++)
    SourceEntry(
      name: 'Example S01E0$episode.mkv',
      path: 'Series/Example S01E0$episode.mkv',
    ),
];

class _ControlledModel extends AppModel {
  _ControlledModel(super.store, super.documents) : super(backgroundWork: false);
  List<SourceEntry> listing = _videos(1);
  Completer<List<SourceEntry>>? pending;
  bool failing = false;
  bool folders = false;
  Completer<List<SourceEntry>>? folderPending;
  final paths = <String>[];
  Completer<void>? snapshotGate;
  bool snapshotWaiting = false;
  bool cancelSnapshot = false;
  int snapshotReads = 0;
  int connections = 0;
  Completer<SourceAdapter>? connectionGate;
  int requests = 0, activeRequests = 0, maxActive = 0, closed = 0, stats = 0;
  @override
  Future<SourceAdapter> adapter(String id) async {
    connections++;
    return await (connectionGate?.future ?? Future.value(_Connection(this)));
  }

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    snapshotReads++;
    if (cancelSnapshot) throw const Cancelled();
    final snapshot = await super.loadLibrarySnapshot(
      query: query,
      cancel: cancel,
    );
    final gate = snapshotGate;
    if (gate != null) {
      snapshotWaiting = true;
      await gate.future;
      snapshotWaiting = false;
    }
    return snapshot;
  }
}

class _Connection extends SourceAdapter {
  final _ControlledModel owner;
  bool reading = false;
  _Connection(this.owner);
  @override
  Future<List<SourceEntry>> list(String path) async {
    owner.paths.add(path);
    owner.requests++;
    owner.activeRequests++;
    if (owner.activeRequests > owner.maxActive) {
      owner.maxActive = owner.activeRequests;
    }
    reading = true;
    try {
      if (owner.failing) throw const AppFailure('offline');
      if (owner.folders && path.isEmpty) {
        return const [
          SourceEntry(name: 'Series', path: 'Series', directory: true),
        ];
      }
      if (owner.folders && owner.folderPending != null) {
        return await owner.folderPending!.future;
      }
      return await (owner.pending?.future ?? Future.value(owner.listing));
    } finally {
      if (reading) owner.activeRequests--;
      reading = false;
    }
  }

  @override
  Future<SourceEntry> stat(String path) async {
    owner.stats++;
    return owner.listing.first;
  }

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
  @override
  Future<void> close() async {
    owner.closed++;
    if (reading) owner.activeRequests--;
    reading = false;
  }
}

class _AutomaticCatalogTransport implements JsonTransport {
  bool failing = true;
  bool episodesFailing = false;
  bool secondEpisode = false;
  int searches = 0;
  int episodeRequests = 0;
  Completer<Map<String, dynamic>>? episodeGate;
  CancelToken? episodeCancel;
  @override
  Future<Map<String, dynamic>> send(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (uri.path.startsWith('/search/subject/')) {
      searches++;
      if (failing) throw const AppFailure('temporary catalogue failure');
      return {
        'list': [_subject],
      };
    }
    if (uri.path == '/v0/episodes') {
      episodeRequests++;
      episodeCancel = cancel;
      if (episodeGate != null) return episodeGate!.future;
      if (episodesFailing) throw const AppFailure('temporary episode failure');
      return {
        'data': [
          {'sort': 1, 'name_cn': '第一集的资料'},
          if (secondEpisode) {'sort': 2, 'name_cn': '第二集的资料'},
        ],
      };
    }
    return _subject;
  }

  static const _subject = {
    'id': 7,
    'type': 2,
    'name': 'Example',
    'name_cn': '自动识别的系列',
    'platform': 'TV',
    'date': '2025-01-01',
    'summary': '目录打开后自动加载的作品简介',
  };
}

class _AutomaticModel extends _ControlledModel {
  _AutomaticModel(super.store, super.documents);
  final transport = _AutomaticCatalogTransport();
  int reconciliations = 0;
  @override
  LibraryCatalog get catalog => _automaticCatalog;
  late final _automaticCatalog = LibraryCatalog(
    store,
    strategy: () => preferences.metadataStrategy,
    transport: transport,
  );

  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) {
    reconciliations++;
    return super.synchronizeDirectoryEntriesInBackground(
      sourceId,
      path,
      entries,
      anchorId: anchorId,
      cancel: cancel,
    );
  }
}

void main() {
  testWidgets(
    'existing partial series information does not suppress a failed lookup retry',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'source-existing-partial-',
      );
      final store = AppStore(':memory:');
      final model = _AutomaticModel(store, root)..listing = _videos(2);
      final collection = identifyDirectory('Series', model.listing)!
          .withMetadata(_AutomaticCatalogTransport._subject, const {
            '1': '第一集的资料',
          });
      await model.synchronizeCollectionInBackground(
        'nas',
        collection,
        importMissing: true,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('已收录 2 集'), findsOneWidget);
        final searches = model.transport.searches;
        expect(searches, greaterThan(0));
        model.transport
          ..failing = false
          ..secondEpisode = true;
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(model.transport.searches, greaterThan(searches));
        expect(
          model.media
              .where((record) => record.data['episode'] == '2')
              .single
              .data['episodeTitle'],
          '第二集的资料',
        );
        expect(model.reconciliations, 1);
        expect(store.records('progress'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'automatic folder details keep the subject while episode titles retry',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('source-auto-episodes-');
      final store = AppStore(':memory:');
      final model = _AutomaticModel(store, root);
      model.transport
        ..failing = false
        ..episodesFailing = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('自动识别的系列'), findsOneWidget);
        expect(model.media.single.data['episodeTitle'], isNull);
        expect(model.transport.episodeRequests, 1);
        final searches = model.transport.searches;
        model.transport.episodesFailing = false;
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(find.text('自动识别的系列'), findsOneWidget);
        expect(model.media.single.data['episodeTitle'], '第一集的资料');
        expect(model.transport.episodeRequests, 2);
        expect(model.transport.searches, searches);
        expect(model.reconciliations, 1);
        expect(store.records('progress'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'slow automatic metadata stays single flight and pause cancels without a frame',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('source-auto-pause-');
      final store = AppStore(':memory:');
      final model = _AutomaticModel(store, root)..transport.failing = false;
      final gate = model.transport.episodeGate =
          Completer<Map<String, dynamic>>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('已收录 1 集'), findsOneWidget);
        expect(model.transport.episodeRequests, 1);
        final token = model.transport.episodeCancel!;
        await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(model.requests, 1);
        expect(model.transport.episodeRequests, 1);
        expect(token.cancelled, isFalse);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // Lifecycle cancellation must finish without another Flutter frame.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(token.cancelled, isTrue);
        gate.complete({'data': []});
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(model.requests, 1);
        expect(model.transport.episodeRequests, 1);
        model.transport.episodeGate = null;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(model.transport.episodeRequests, 2);
        expect(find.text('自动识别的系列'), findsOneWidget);
        expect(model.media.single.data['episodeTitle'], '第一集的资料');
        expect(model.reconciliations, 1);
        expect(store.records('progress'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete({'data': []});
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'automatic folder metadata retries unchanged files with backoff without reimporting',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('source-auto-retry-');
      final store = AppStore(':memory:');
      final model = _AutomaticModel(store, root);
      var plays = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
              onPlay: (_) async => plays++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('已收录 1 集'), findsOneWidget);
        final firstSearches = model.transport.searches;
        expect(firstSearches, greaterThan(0));
        await tester.pump(const Duration(seconds: 59));
        expect(model.transport.searches, firstSearches);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final secondSearches = model.transport.searches;
        expect(secondSearches, greaterThan(firstSearches));
        await tester.pump(const Duration(seconds: 119));
        expect(model.transport.searches, secondSearches);
        model.transport.failing = false;
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('自动识别的系列'), findsOneWidget);
        expect(model.media.single.data['episodeTitle'], '第一集的资料');
        expect(model.reconciliations, 1);
        expect(plays, 0);
        expect(store.records('progress'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'enabling automatic metadata retries the visible unchanged folder',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('source-auto-config-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _AutomaticModel(store, root)..transport.failing = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(model.transport.searches, 0);
        expect(find.textContaining('已收录 1 集'), findsOneWidget);
        store.setLocal('settings', {'metadataStrategy': 'conservative'});
        model.changed();
        await tester.pumpAndSettle();
        expect(find.text('自动识别的系列'), findsOneWidget);
        expect(model.reconciliations, 1);
        expect(store.records('progress'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('hidden initialization and model replacement defer connections', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('source-hidden-open-');
    final firstStore = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final secondStore = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final first = _ControlledModel(firstStore, root);
    final second = _ControlledModel(secondStore, root);
    Widget surface(AppModel model) => MaterialApp(
      home: SourceBrowser(
        model: model,
        initialPath: 'Series',
        source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    try {
      await tester.pumpWidget(surface(first));
      tester.binding.scheduleForcedFrame();
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(second));
      tester.binding.scheduleForcedFrame();
      await tester.pumpAndSettle();
      expect(first.connections, 0);
      expect(second.connections, 0);
      expect(first.requests, 0);
      expect(second.requests, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(first.connections, 0);
      expect(second.connections, 2);
      expect(second.requests, 1);
      expect(find.textContaining('已收录 1 集'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpWidget(surface(first));
      await tester.pumpAndSettle();
      expect(first.connections, 0);
      expect(second.connections, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(first.connections, 2);
      expect(first.requests, 1);
      expect(second.connections, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      first.dispose();
      second.dispose();
      firstStore.dispose();
      secondStore.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('initially inactive direct HTTP opens once when activated', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('source-inactive-http-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _ControlledModel(store, root);
    var active = false;
    late StateSetter update;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return SourceBrowser(
                model: model,
                active: active,
                source: const {'id': 'direct', 'kind': 'http'},
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.connections, 0);
      expect(model.stats, 0);
      update(() => active = true);
      await tester.pumpAndSettle();
      expect(model.stats, 1);
      final connections = model.connections;
      await tester.pump(const Duration(minutes: 2));
      expect(model.connections, connections);
      expect(model.stats, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('cancelled opening closes late and resumes without waiting', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('source-cancel-open-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _ControlledModel(store, root);
    final opening = model.connectionGate = Completer<SourceAdapter>();
    var active = true;
    late StateSetter update;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return SourceBrowser(
                model: model,
                active: active,
                initialPath: 'Series',
                source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(model.connections, 1);
      update(() => active = false);
      await tester.pumpAndSettle();
      expect(model.requests, 0);
      model.connectionGate = null;
      update(() => active = true);
      await tester.pumpAndSettle();
      expect(model.requests, 1);
      expect(find.textContaining('已收录 1 集'), findsOneWidget);
      final closed = model.closed;
      opening.complete(_Connection(model));
      await tester.pumpAndSettle();
      expect(model.closed, closed + 1);
      expect(model.requests, 1);
      expect(tester.takeException(), isNull);
    } finally {
      if (!opening.isCompleted) opening.complete(_Connection(model));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'cancelled metadata refresh waits for a new notification instead of spinning',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'source-metadata-cancel-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _ControlledModel(store, root);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SourceBrowser(
              model: model,
              initialPath: 'Series',
              source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        model.cancelSnapshot = true;
        final before = model.snapshotReads;
        model.changed();
        await tester.pumpAndSettle();
        expect(model.snapshotReads, before + 1);
        await tester.pump();
        expect(model.snapshotReads, before + 1);
        model.cancelSnapshot = false;
        model.changed();
        await tester.pumpAndSettle();
        expect(model.snapshotReads, before + 2);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'metadata finishing while hidden is applied on resume for direct HTTP',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'source-metadata-resume-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _ControlledModel(store, root);
      late StateSetter update;
      var active = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return SourceBrowser(
                  model: model,
                  active: active,
                  source: const {
                    'id': 'direct',
                    'kind': 'http',
                    'label': 'Video',
                  },
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final record = model.media.single;
        store.save('media', record.id, {
          ...record.data,
          'metadataTitle': '更新后的作品',
        });
        final gate = model.snapshotGate = Completer<void>();
        model.changed();
        await tester.pump();
        expect(model.snapshotWaiting, isTrue);
        update(() => active = false);
        await tester.pumpAndSettle();
        gate.complete();
        model.snapshotGate = null;
        await tester.pumpAndSettle();
        expect(find.text('更新后的作品'), findsNothing);
        update(() => active = true);
        await tester.pumpAndSettle();
        expect(find.text('更新后的作品'), findsOneWidget);
        expect(model.stats, 1);
      } finally {
        model.snapshotGate?.complete();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'cancelled folder previews retry on resume with an unchanged parent listing',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'source-preview-resume-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _ControlledModel(store, root)..folders = true;
      final pending = model.folderPending = Completer<List<SourceEntry>>();
      late StateSetter update;
      var active = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return SourceBrowser(
                  model: model,
                  active: active,
                  source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(model.paths.where((path) => path == 'Series'), hasLength(1));
        update(() => active = false);
        await tester.pumpAndSettle();
        pending.complete(_videos(1));
        await tester.pumpAndSettle();
        model.folderPending = null;
        expect(find.text('Example'), findsNothing);
        update(() => active = true);
        await tester.pumpAndSettle();
        expect(
          model.paths.where((path) => path == 'Series'),
          hasLength(1),
          reason:
              'The completed listing is reused while its cancelled metadata inspection retries.',
        );
        expect(find.text('Example'), findsOneWidget);
        expect(model.media, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete(_videos(1));
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'source refresh cancels hung connections without overlap or stale writes',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'source-refresh-cancel-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _ControlledModel(store, root);
      late StateSetter update;
      var active = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return SourceBrowser(
                  model: model,
                  active: active,
                  initialPath: 'Series',
                  source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(model.requests, 1);
        final pending = model.pending = Completer<List<SourceEntry>>();
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(model.requests, 2);
        await tester.pump(const Duration(minutes: 2));
        expect(model.requests, 2);
        update(() => active = false);
        await tester.pumpAndSettle();
        expect(model.activeRequests, 0);
        model.pending = null;
        model.listing = _videos(3);
        update(() => active = true);
        await tester.pumpAndSettle();
        expect(find.textContaining('已收录 3 集'), findsOneWidget);
        expect(model.requests, 3);
        expect(model.maxActive, 1);
        pending.complete(_videos(5));
        await tester.pumpAndSettle();
        expect(model.media, hasLength(3));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('source refresh backs off failures and resets after recovery', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('source-refresh-retry-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _ControlledModel(store, root);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SourceBrowser(
            model: model,
            initialPath: 'Series',
            source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      model.failing = true;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(model.requests, 2);
      await tester.pump(const Duration(seconds: 59));
      expect(model.requests, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(model.requests, 3);
      await tester.pump(const Duration(seconds: 119));
      expect(model.requests, 3);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(model.requests, 4);
      model.failing = false;
      model.listing = _videos(2);
      await tester.pump(const Duration(seconds: 240));
      await tester.pumpAndSettle();
      expect(model.requests, 5);
      expect(find.textContaining('已收录 2 集'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(model.requests, 6);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('direct HTTP video does not poll stat or a directory', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('source-refresh-direct-');
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _ControlledModel(store, root);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: SourceBrowser(
            model: model,
            source: const {'id': 'direct', 'kind': 'http', 'label': 'Video'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.stats, 1);
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(model.stats, 1);
      expect(model.requests, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'real WebDAV source revalidates cached folders and refreshes only while visible',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      late Directory root;
      late AppStore store;
      late HttpServer server;
      late _WebDavModel model;
      var available = 1;
      final requests = <String>[];
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('source-refresh-webdav-');
        store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          request.response.statusCode = 207;
          request.response.write(_listing(request.uri.path, available));
          await request.response.close();
        });
        model = _WebDavModel(
          store,
          root,
          'http://127.0.0.1:${server.port}/dav/',
        );
        await model.loadLibrarySnapshot();
      });
      final navigator = GlobalKey<NavigatorState>();
      late StateSetter update;
      var active = true;
      var browserBuilds = 0;
      final oldRebuild = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        oldRebuild?.call(element, builtOnce);
        if (element.widget is SourceBrowser) browserBuilds++;
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: GlassPalette.theme(),
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return SourceBrowser(
                  model: model,
                  active: active,
                  source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
                );
              },
            ),
          ),
        );
        final folder = find.byKey(const ValueKey('Series/'));
        await _settle(tester, () => folder.evaluate().isNotEmpty);
        await tester.tap(folder);
        await _settle(
          tester,
          () => find.textContaining('已收录 1 集').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('返回'));
        await _settle(tester, () => folder.evaluate().isNotEmpty);
        available = 3;
        final beforeCollections = model.completedCollections;
        final beforeReopen = requests
            .where((path) => path == '/dav/Series/')
            .length;
        await tester.tap(folder);
        await _settle(
          tester,
          () => find.textContaining('已收录 3 集').evaluate().isNotEmpty,
        );
        expect(
          requests.where((path) => path == '/dav/Series/').length,
          greaterThan(beforeReopen),
        );
        await _settle(
          tester,
          () => model.completedCollections > beforeCollections,
        );
        await tester.runAsync(() => model.loadLibrarySnapshot());
        await tester.pumpAndSettle();
        final reconciliations = model.reconciliations;
        final beforeSame = requests.length;
        final beforePreparation = model.preparations;
        final beforeBuilds = browserBuilds;
        var notifications = 0;
        void changed() => notifications++;
        model.addListener(changed);
        await tester.pump(const Duration(seconds: 30));
        await _settle(
          tester,
          () =>
              requests.length > beforeSame &&
              model.preparations > beforePreparation,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        expect(model.reconciliations, reconciliations);
        expect(browserBuilds, beforeBuilds);
        expect(notifications, 0);
        model.removeListener(changed);

        available = 4;
        await tester.pump(const Duration(seconds: 30));
        await _settle(
          tester,
          () => find.textContaining('已收录 4 集').evaluate().isNotEmpty,
        );
        update(() => active = false);
        await tester.pumpAndSettle();
        final hiddenRequests = requests.length;
        available = 5;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, hiddenRequests, reason: '$requests');
        update(() => active = true);
        await tester.pump();
        await _settle(
          tester,
          () => find.textContaining('已收录 5 集').evaluate().isNotEmpty,
        );

        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        final coveredRequests = requests.length;
        available = 6;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, coveredRequests);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await _settle(
          tester,
          () => find.textContaining('已收录 6 集').evaluate().isNotEmpty,
        );

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        final pausedRequests = requests.length;
        available = 7;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, pausedRequests);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await _settle(
          tester,
          () => find.textContaining('已收录 7 集').evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox());
        final closedRequests = requests.length;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, closedRequests);
        expect(tester.takeException(), isNull);
      } finally {
        debugOnRebuildDirtyWidget = oldRebuild;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          store.dispose();
          await server.close(force: true);
          await root.delete(recursive: true);
        });
      }
    },
  );
}
