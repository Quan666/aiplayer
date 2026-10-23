import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScanSource extends SourceAdapter {
  bool closed = false;
  final entries = List.generate(
    60,
    (index) => SourceEntry(
      name: 'Show S01E${(index + 2).toString().padLeft(2, '0')}.mkv',
      path: 'show/${index + 2}.mkv',
      size: index + 10,
    ),
  );

  @override
  Future<List<SourceEntry>> list(String path) async => entries;
  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _ScanModel extends AppModel {
  final source = _ScanSource();
  int mediaReads = 0, imports = 0;
  int? failAt;
  _ScanModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  List<SyncRecord> get media {
    mediaReads++;
    return super.media;
  }

  @override
  Future<SourceAdapter> adapter(String id) async => source;
  @override
  String addMedia(
    String sourceId,
    SourceEntry entry, {
    String? associateId,
    bool notify = true,
  }) {
    if (++imports == failAt) throw StateError('failed import');
    return super.addMedia(
      sourceId,
      entry,
      associateId: associateId,
      notify: notify,
    );
  }
}

class _CountingStore extends AppStore {
  int bindingWrites = 0;
  _CountingStore() : super(':memory:');
  @override
  void setLocal(String key, dynamic value) {
    if (key == 'syncProfile:remoteMedia') bindingWrites++;
    super.setLocal(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _ScanModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('scan-performance-');
    store = _CountingStore()
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _ScanModel(store, directory);
    store.save('media', 'donor', {
      'title': 'Show S01E01.mkv',
      'series': 'Show',
      'season': '1',
      'episode': '1',
      'bangumiId': '123',
      'metadataTitle': 'Verified show',
    });
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'scan batches notifications and donor reads while yielding to input',
    () async {
      var notifications = 0;
      final visibleCounts = <int>[];
      model.addListener(() {
        notifications++;
        if (model.scanning && model.status.startsWith('已发现')) {
          Timer.run(() => visibleCounts.add(store.all('media').length));
        }
      });
      await model.scan('nas', '');
      expect(store.all('media'), hasLength(61));
      expect(
        store.all('media').every((r) => r.data['bangumiId'] == '123'),
        true,
      );
      expect(
        model.mediaReads,
        1,
        reason: 'own imports do not rescan the growing library',
      );
      expect(notifications, 5, reason: 'start, three batches and completion');
      expect(visibleCounts, [25, 49, 61]);
      expect(model.source.closed, true);
      expect((store as _CountingStore).bindingWrites, 3);
    },
  );

  test('scan sees a conflicting manual match between committed batches', () async {
    var edited = false;
    model.addListener(() {
      if (!edited && model.status.startsWith('已发现')) {
        edited = true;
        final donor = store.get('media', 'donor')!;
        store.save('media', donor.id, {...donor.data, 'bangumiId': '456'});
      }
    });
    await model.scan('nas', '');
    expect(model.mediaReads, 2);
    expect(store.all('media').where((r) => r.data['bangumiId'] == null), hasLength(36));
    expect(store.local('syncProfile:remoteMedia'), hasLength(60));
  });

  test(
    'cancel between batches preserves committed files and closes source',
    () async {
      final cancel = CancelToken();
      model.addListener(() {
        if (model.status.startsWith('已发现')) Timer.run(cancel.cancel);
      });
      await model.scan('nas', '', cancel: cancel);
      expect(store.all('media'), hasLength(25));
      expect(store.locations, hasLength(24));
      expect(model.status, contains('已取消'));
      expect(model.source.closed, true);
    },
  );

  test(
    'failed batch rolls back records and locations and clears donor snapshot',
    () async {
      model.failAt = 30;
      await model.scan('nas', '');
      expect(store.all('media'), hasLength(25));
      expect(store.locations, hasLength(24));
      expect(model.status, contains('未完成'));
      expect(model.source.closed, true);
      final donor = store.get('media', 'donor')!;
      store.save('media', donor.id, {...donor.data, 'bangumiId': '456'});
      // A standalone import still reads current data and sees ambiguous donors.
      final id = model.addMedia(
        'nas',
        const SourceEntry(name: 'Show S01E90.mkv', path: 'show/90.mkv'),
      );
      expect(store.get('media', id)!.data['bangumiId'], isNull);
    },
  );
}
