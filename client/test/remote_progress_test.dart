import 'dart:async';

import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/remote_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'slow remote persistence retains only the latest pending snapshot',
    () async {
      final store = _SlowStore();
      addTearDown(store.dispose);
      var syncs = 0;
      final progress = RemotePlaybackProgress(
        store: store,
        progressId: 'video',
        watchedId: 'video',
        onSaved: () => syncs++,
        onError: (error) => fail('$error'),
      );
      final initial = progress.save(position: 1, duration: 100);
      for (var position = 2; position < 99; position++) {
        unawaited(progress.save(position: position.toDouble(), duration: 100));
      }
      final finalSave = progress.save(position: 99, duration: 100);
      expect(store.positions, [1]);
      store.firstWrite.complete();
      await Future.wait([initial, finalSave]);
      expect(store.positions, [1, 99]);
      expect(store.get('progress', 'video')!.data['position'], 99);
      expect(store.get('watched', 'video')!.data['watched'], isTrue);
      expect(syncs, 2);
    },
  );

  test(
    'a failed write does not discard a pending final remote position',
    () async {
      final store = _SlowStore()..failFirst = true;
      addTearDown(store.dispose);
      final errors = <Object>[];
      final progress = RemotePlaybackProgress(
        store: store,
        progressId: 'video',
        watchedId: 'video',
        onSaved: () {},
        onError: errors.add,
      );
      unawaited(progress.save(position: 10, duration: 100));
      final finalSave = progress.save(position: 70, duration: 100);
      store.firstWrite.complete();
      await finalSave;
      expect(errors, hasLength(1));
      expect(store.positions, [10, 70]);
      expect(store.get('progress', 'video')!.data['position'], 70);
    },
  );

  test(
    'transient and invalid remote positions never open storage work',
    () async {
      final store = _SlowStore();
      addTearDown(store.dispose);
      for (final enabled in [false, true]) {
        final progress = RemotePlaybackProgress(
          store: store,
          progressId: 'video',
          watchedId: 'video',
          enabled: enabled,
          onSaved: () => fail('Unexpected write'),
          onError: (error) => fail('$error'),
        );
        await progress.save(position: double.nan, duration: 100);
        await progress.save(position: 1, duration: double.infinity);
        await progress.save(position: 1, duration: 0);
        if (!enabled) await progress.save(position: 99, duration: 100);
      }
      expect(store.positions, isEmpty);
    },
  );
}

class _SlowStore extends AppStore {
  _SlowStore() : super(':memory:');
  final firstWrite = Completer<void>();
  final positions = <double>[];
  bool failFirst = false;

  @override
  Future<bool> savePlaybackProgress(
    String progressId,
    Map<String, dynamic> data, {
    String? watchedId,
  }) async {
    positions.add((data['position'] as num).toDouble());
    if (positions.length == 1) {
      await firstWrite.future;
      if (failFirst) throw StateError('Disk unavailable');
    }
    return super.savePlaybackProgress(progressId, data, watchedId: watchedId);
  }
}
