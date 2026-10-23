import 'dart:async';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/playback/seek_preview.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

SeekPreviewFrame frame(Duration position) =>
    SeekPreviewFrame(position, Uint8List.fromList([1, 2, 3]));

Future<void> waitUntil(bool Function() ready) async {
  final deadline = Stopwatch()..start();
  while (!ready()) {
    if (deadline.elapsed > const Duration(seconds: 3)) {
      fail('Preview did not reach the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class UnavailableSource extends SourceAdapter {
  final Future<void> Function() dispose;
  UnavailableSource(this.dispose);
  @override
  Future<List<SourceEntry>> list(String path) async => [];
  @override
  Future<SourceEntry> stat(String path) async => throw const AppFailure('离线');
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
  @override
  Future<void> close() => dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a drag queued during slow cleanup restarts after the source closes',
    () async {
      final release = Completer<void>();
      var opens = 0;
      var closing = false;
      final preview = SeekPreviewController(
        path: 'unused',
        openSource: () async {
          final first = ++opens == 1;
          return UnavailableSource(() async {
            if (first) {
              closing = true;
              await release.future;
            }
          });
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await preview.close();
      });
      preview.request(const Duration(seconds: 5));
      await waitUntil(() => closing);
      preview.end();
      preview.request(const Duration(seconds: 10));
      preview.request(const Duration(seconds: 12));
      expect(preview.status, SeekPreviewStatus.unavailable);
      expect(opens, 1);
      release.complete();
      await waitUntil(() => opens == 2);
      await waitUntil(() => preview.status == SeekPreviewStatus.unavailable);
    },
  );

  SeekPreviewController controller(
    SeekPreviewCapture capture, {
    Duration timeout = const Duration(seconds: 2),
    void Function(Object)? onError,
  }) => SeekPreviewController(
    openSource: () => throw StateError('Injected capture must not open media'),
    path: 'unused',
    capture: capture,
    requestTimeout: timeout,
    onError: onError,
  );

  test(
    'continuous dragging publishes frames and drains only the latest target',
    () async {
      final first = Completer<SeekPreviewFrame>();
      final requested = <Duration>[];
      final shown = <Duration>[];
      final preview = controller((target, cancel) {
        requested.add(target);
        return requested.length == 1
            ? first.future
            : Future.value(frame(target));
      });
      preview.addListener(() {
        if (preview.value != null) shown.add(preview.value!.position);
      });
      addTearDown(preview.close);
      preview.request(const Duration(seconds: 5));
      expect(preview.status, SeekPreviewStatus.loading);
      await waitUntil(() => requested.isNotEmpty);
      for (var second = 6; second <= 12; second++) {
        preview.request(Duration(seconds: second));
      }
      first.complete(frame(const Duration(seconds: 5)));
      await waitUntil(
        () => preview.value?.position == const Duration(seconds: 12),
      );
      expect(requested, [
        const Duration(seconds: 5),
        const Duration(seconds: 12),
      ]);
      expect(shown, contains(const Duration(seconds: 5)));
      expect(preview.status, SeekPreviewStatus.ready);
      preview.request(const Duration(milliseconds: 12400));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        requested.length,
        2,
        reason: 'Reuse an already captured half-second bucket',
      );
      preview.request(const Duration(seconds: 20));
      preview.request(const Duration(seconds: 12));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        requested.length,
        2,
        reason: 'Returning to a cached frame clears the queued seek',
      );
      expect(preview.value!.position, const Duration(seconds: 12));
    },
  );

  test('reversing a drag discards an obsolete queued position', () async {
    final first = Completer<SeekPreviewFrame>();
    final requested = <Duration>[];
    final preview = controller((target, cancel) {
      requested.add(target);
      return first.future;
    });
    addTearDown(preview.close);
    preview.request(const Duration(seconds: 5));
    await waitUntil(() => requested.isNotEmpty);
    preview.request(const Duration(seconds: 10));
    preview.request(const Duration(seconds: 5));
    first.complete(frame(const Duration(seconds: 5)));
    await waitUntil(() => preview.value != null);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(requested, [const Duration(seconds: 5)]);
    expect(preview.value!.position, const Duration(seconds: 5));
  });

  test(
    'a stalled capture leaves loading and can recover on the next drag',
    () async {
      var calls = 0;
      CancelToken? stalled;
      final errors = <Object>[];
      final preview = controller(
        (target, cancel) {
          calls++;
          if (calls == 1) {
            stalled = cancel;
            return Completer<SeekPreviewFrame>().future;
          }
          return Future.value(frame(target));
        },
        timeout: const Duration(milliseconds: 300),
        onError: errors.add,
      );
      addTearDown(preview.close);
      preview.request(const Duration(seconds: 7));
      await waitUntil(() => preview.status == SeekPreviewStatus.unavailable);
      expect(stalled!.cancelled, true);
      expect(errors, hasLength(1));
      preview.request(const Duration(seconds: 8));
      expect(preview.status, SeekPreviewStatus.unavailable);
      expect(
        calls,
        1,
        reason:
            'A disconnected source must not be retried on every pointer event',
      );
      preview.end();
      expect(preview.status, SeekPreviewStatus.idle);
      preview.request(const Duration(seconds: 9));
      await waitUntil(() => preview.value != null);
      expect(preview.value!.position, const Duration(seconds: 9));
    },
  );

  test(
    'a late capture after ending a drag never replaces the next frame',
    () async {
      final first = Completer<SeekPreviewFrame>();
      var calls = 0;
      final errors = <Object>[];
      final preview = controller((target, cancel) {
        return ++calls == 1 ? first.future : Future.value(frame(target));
      }, onError: errors.add);
      addTearDown(preview.close);
      preview.request(const Duration(seconds: 4));
      await waitUntil(() => calls == 1);
      preview.end();
      preview.request(const Duration(seconds: 20));
      await waitUntil(
        () => preview.value?.position == const Duration(seconds: 20),
      );
      first.complete(frame(const Duration(seconds: 4)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(preview.value!.position, const Duration(seconds: 20));
      expect(errors, isEmpty);
    },
  );

  test(
    'closing cancels hung work without waiting for the capture future',
    () async {
      CancelToken? active;
      var notifications = 0;
      final late = Completer<SeekPreviewFrame>();
      final preview = controller((target, cancel) {
        active = cancel;
        return late.future;
      });
      preview.addListener(() => notifications++);
      preview.request(const Duration(seconds: 3));
      await waitUntil(() => active != null);
      await preview.close().timeout(const Duration(seconds: 1));
      expect(active!.cancelled, true);
      final before = notifications;
      late.complete(frame(const Duration(seconds: 3)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifications, before);
      await preview.close();
    },
  );
}
