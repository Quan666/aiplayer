import 'dart:async';

import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Capacity extends ValueNotifier<int> {
  _Capacity() : super(0);
  bool get observed => hasListeners;
}

Widget _view(
  ValueNotifier<int> capacity,
  List<FutureOr<bool> Function()> requests, {
  bool active = true,
}) => MaterialApp(
  home: TickerMode(
    enabled: active,
    child: Row(
      children: [
        for (final request in requests)
          SizedBox(
            width: 100,
            height: 100,
            child: MediaArtwork(
              tryRequestPreview: request,
              previewCapacity: capacity,
            ),
          ),
      ],
    ),
  ),
);

void main() {
  testWidgets('only rejected previews retry when queue capacity is released', (
    tester,
  ) async {
    final capacity = _Capacity();
    var acceptedCalls = 0, rejectedCalls = 0;
    var full = true;
    await tester.pumpWidget(
      _view(capacity, [
        () {
          acceptedCalls++;
          return true;
        },
        () {
          rejectedCalls++;
          return !full;
        },
      ]),
    );
    await tester.pumpAndSettle();
    expect(acceptedCalls, 1);
    expect(rejectedCalls, 1);
    expect(capacity.observed, isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
    full = false;
    capacity.value++;
    await tester.pumpAndSettle();
    expect(acceptedCalls, 1);
    expect(rejectedCalls, 2);
    expect(capacity.observed, isFalse);
    capacity.value++;
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    capacity.dispose();
  });

  testWidgets(
    'paused previews detach capacity without a frame and retry on resume',
    (tester) async {
      final capacity = _Capacity();
      var calls = 0, full = true;
      await tester.pumpWidget(
        _view(capacity, [
          () {
            calls++;
            return !full;
          },
        ]),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(capacity.observed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(capacity.observed, isFalse);
      full = false;
      capacity.value++;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(capacity.observed, isFalse);
      await tester.pumpWidget(const SizedBox());
      capacity.dispose();
    },
  );

  testWidgets(
    'capacity released during an asynchronous admission is not lost',
    (tester) async {
      final capacity = _Capacity();
      final first = Completer<bool>();
      var calls = 0;
      await tester.pumpWidget(
        _view(capacity, [() => ++calls == 1 ? first.future : true]),
      );
      await tester.pumpAndSettle();
      capacity.value++;
      first.complete(false);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(capacity.observed, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
      capacity.dispose();
    },
  );

  testWidgets('disposing rejected artwork releases the capacity listener', (
    tester,
  ) async {
    final capacity = _Capacity();
    await tester.pumpWidget(_view(capacity, [() => false]));
    await tester.pumpAndSettle();
    expect(capacity.observed, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(capacity.observed, isFalse);
    await tester.pumpAndSettle();
    capacity.value++;
    expect(tester.binding.hasScheduledFrame, isFalse);
    capacity.dispose();
  });

  testWidgets('hidden artwork releases capacity and retries once when shown', (
    tester,
  ) async {
    final capacity = _Capacity();
    var calls = 0, full = true;
    bool request() {
      calls++;
      return !full;
    }

    await tester.pumpWidget(_view(capacity, [request]));
    await tester.pumpAndSettle();
    expect(capacity.observed, isTrue);
    await tester.pumpWidget(_view(capacity, [request], active: false));
    await tester.pumpAndSettle();
    expect(capacity.observed, isFalse);
    full = false;
    capacity.value++;
    expect(calls, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(_view(capacity, [request]));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(capacity.observed, isFalse);
    await tester.pumpWidget(const SizedBox());
    capacity.dispose();
  });
}
