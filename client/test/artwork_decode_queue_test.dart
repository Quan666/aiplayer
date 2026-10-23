import 'dart:ui' as ui;

import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets(
    'paused without a frame stops native completion from refilling slots',
    (tester) async {
      final queue = ArtworkDecodeQueue(maxActive: 1);
      addTearDown(queue.dispose);
      final first = _ControlledProvider(), waiting = _ControlledProvider();
      for (final provider in [first, waiting]) {
        queue.request(
          provider,
          canStart: () => true,
          onStart: () {},
          onError: (_, _) {},
        );
      }
      await tester.pump();
      expect(first.loads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      first.completer.fail(StateError('completed in background'));
      await tester.idle();
      expect(waiting.loads, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(waiting.loads, 1);
      waiting.completer.fail(StateError('done'));
      await tester.pump();
    },
  );

  testWidgets('paused without a frame releases completed image listeners', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final image = (await tester.runAsync(() => createTestImage(cache: false)))!;
    addTearDown(image.dispose);
    final cache = PaintingBinding.instance.imageCache;
    final previousLimit = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 0;
    addTearDown(() => cache.maximumSizeBytes = previousLimit);
    final provider = _ControlledProvider(), background = _ControlledProvider();
    for (final request in [provider, background]) {
      queue.request(
        request,
        canStart: () => true,
        onStart: () {},
        onError: (_, _) {},
      );
    }
    await tester.pump();
    provider.completer.complete(image);
    expect(provider.completer.hasListeners, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    background.completer.complete(image);
    await tester.idle();
    expect(provider.completer.hasListeners, isFalse);
    expect(background.completer.hasListeners, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('starts after layout and bounds outstanding native decodes', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final image = (await tester.runAsync(() => createTestImage(cache: false)))!;
    addTearDown(image.dispose);
    final providers = List.generate(4, (_) => _ControlledProvider());
    final started = <int>[];
    final requests = [
      for (var i = 0; i < providers.length; i++)
        queue.request(
          providers[i],
          canStart: () => true,
          onStart: () {
            expectSync(
              PaintingBinding.instance.imageCache
                  .statusForKey(providers[i])
                  .pending,
              isTrue,
            );
            started.add(i);
          },
          onError: (error, stack) => fail('$error'),
        )!,
    ];
    expect(started, isEmpty);
    expect(providers.map((provider) => provider.loads), everyElement(0));

    await tester.pump();
    expect(started, [0, 1]);
    expect(requests.every((request) => request.isPending), isTrue);
    await tester.pump();
    expect(started, [0, 1]);

    providers[0].completer.complete(image);
    expect(requests[0].isPending, isFalse);
    expect(started, [0, 1]);
    // Native completion can fill the freed slot without waiting for a frame.
    await tester.idle();
    expect(started, [0, 1, 2]);

    providers[1].completer.complete(image);
    providers[2].completer.complete(image);
    await tester.pump();
    expect(started, [0, 1, 2, 3]);
    providers[3].completer.complete(image);
    await tester.pump();
    expect(requests.any((request) => request.isPending), isFalse);
  });

  testWidgets('cancelling an active decode cannot bypass the native limit', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue(maxActive: 1);
    addTearDown(queue.dispose);
    final first = _ControlledProvider();
    final second = _ControlledProvider();
    final errors = <Object>[];
    ArtworkDecodeRequest request(_ControlledProvider provider) => queue.request(
      provider,
      canStart: () => true,
      onStart: () {},
      onError: (error, stack) => errors.add(error),
    )!;
    final firstRequest = request(first);
    final secondRequest = request(second);
    await tester.pump();
    expect(first.loads, 1);
    firstRequest.cancel();
    expect(firstRequest.isPending, isFalse);
    await tester.pump();
    expect(second.loads, 0);

    first.completer.fail(StateError('cancelled decode'));
    expect(errors, isEmpty);
    await tester.pump();
    expect(second.loads, 1);
    expect(secondRequest.isPending, isTrue);
    second.completer.fail(StateError('visible decode'));
    expect(errors, hasLength(1));
    expect(secondRequest.isPending, isFalse);
    await tester.pump();
  });

  testWidgets('drops cancelled and newly hidden requests before resolving', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue(maxActive: 1);
    addTearDown(queue.dispose);
    final active = _ControlledProvider();
    final cancelled = _ControlledProvider();
    final hidden = _ControlledProvider();
    var visible = true;
    ArtworkDecodeRequest request(_ControlledProvider provider) => queue.request(
      provider,
      canStart: () => visible,
      onStart: () {},
      onError: (error, stack) {},
    )!;
    request(active);
    final cancelledRequest = request(cancelled);
    final hiddenRequest = request(hidden);
    await tester.pump();
    cancelledRequest.cancel();
    visible = false;
    active.completer.fail(StateError('done'));
    await tester.pump();
    expect(cancelled.loads, 0);
    expect(hidden.loads, 0);
    expect(cancelledRequest.isPending, isFalse);
    expect(hiddenRequest.isPending, isFalse);
  });

  testWidgets('bounds the pending queue and wakes callers as space opens', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue(maxActive: 1, maxPending: 2);
    addTearDown(queue.dispose);
    var capacityChanges = 0;
    queue.capacity.addListener(() => capacityChanges++);
    final active = _ControlledProvider();
    ArtworkDecodeRequest? request(_ControlledProvider provider) =>
        queue.request(
          provider,
          canStart: () => true,
          onStart: () {},
          onError: (error, stack) {},
        );
    expect(request(active), isNotNull);
    final waiting = request(_ControlledProvider())!;
    expect(request(_ControlledProvider()), isNull);
    expect(capacityChanges, 0);

    await tester.pump();
    expect(capacityChanges, 1);
    final last = request(_ControlledProvider())!;
    expect(request(_ControlledProvider()), isNull);
    waiting.cancel();
    await tester.pump();
    expect(capacityChanges, 2);
    last.cancel();
    active.completer.fail(StateError('done'));
    await tester.pump();
    expect(capacityChanges, 2);
  });

  testWidgets('visible images precede prefetch and retain one admission slot', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final providers = List.generate(5, (_) => _ControlledProvider());
    final started = <int>[];
    void request(int index, int priority) {
      queue.request(
        providers[index],
        canStart: () => true,
        priority: () => priority,
        onStart: () => started.add(index),
        onError: (error, stack) {},
      );
    }

    request(0, 1);
    request(1, 1);
    request(2, 0);
    request(3, 0);
    await tester.pump();
    expect(started, [2, 3]);
    providers[2].completer.fail(StateError('done'));
    await tester.idle();
    expect(started, [2, 3, 0]);
    providers[3].completer.fail(StateError('done'));
    await tester.idle();
    expect(started, [2, 3, 0]);

    request(4, 0);
    await tester.pump();
    expect(started, [2, 3, 0, 4]);
    providers[0].completer.fail(StateError('done'));
    await tester.idle();
    expect(started, [2, 3, 0, 4, 1]);
    providers[4].completer.fail(StateError('done'));
    providers[1].completer.fail(StateError('done'));
    await tester.pump();
  });

  testWidgets('checks changed viewport priority when a decode slot opens', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final providers = List.generate(5, (_) => _ControlledProvider());
    final priorities = [0, 0, 1, 1, 1];
    final started = <int>[];
    final requests = [
      for (var i = 0; i < providers.length; i++)
        queue.request(
          providers[i],
          canStart: () => true,
          priority: () => priorities[i],
          onStart: () => started.add(i),
          onError: (error, stack) {},
        )!,
    ];
    await tester.pump();
    expect(started, [0, 1]);
    priorities[2] = -1;
    priorities[4] = 0;
    providers[0].completer.fail(StateError('done'));
    await tester.idle();
    expect(started, [0, 1, 4]);
    expect(requests[2].isPending, isFalse);
    expect(providers[2].loads, 0);
    requests[3].cancel();
    providers[1].completer.fail(StateError('done'));
    providers[4].completer.fail(StateError('done'));
    await tester.pump();
  });

  testWidgets(
    'viewport promotion uses the spare slot before prefetch finishes',
    (tester) async {
      final queue = ArtworkDecodeQueue();
      addTearDown(queue.dispose);
      final providers = List.generate(3, (_) => _ControlledProvider());
      final priorities = [1, 1, 1];
      final started = <int>[];
      var priorityChecks = 0;
      ArtworkDecodeRequest request(int index) => queue.request(
        providers[index],
        canStart: () => true,
        priority: () {
          priorityChecks++;
          return priorities[index];
        },
        onStart: () => started.add(index),
        onError: (error, stack) {},
      )!;
      final prefetch = request(0);
      final promoted = request(1);
      await tester.pump();
      expect(started, [0]);
      priorities[1] = 0;
      promoted.refreshPriority();
      await tester.idle();
      expect(started, [0, 1]);
      expect(prefetch.isPending, isTrue);

      final waiting = request(2);
      await tester.pump();
      final checksBeforeRefresh = priorityChecks;
      waiting.refreshPriority();
      promoted.refreshPriority();
      await tester.idle();
      expect(priorityChecks, checksBeforeRefresh);
      expect(started, [0, 1]);

      waiting.cancel();
      providers[0].completer.fail(StateError('done'));
      providers[1].completer.fail(StateError('done'));
      waiting.refreshPriority();
      promoted.refreshPriority();
      await tester.idle();
      expect(priorityChecks, checksBeforeRefresh);
      expect(started, [0, 1]);
      await tester.pump();
    },
  );

  testWidgets('new requests still wait for their first layout', (tester) async {
    final queue = ArtworkDecodeQueue(maxActive: 1);
    addTearDown(queue.dispose);
    final active = _ControlledProvider();
    final fresh = _ControlledProvider();
    ArtworkDecodeRequest request(_ControlledProvider provider) => queue.request(
      provider,
      canStart: () => true,
      onStart: () {},
      onError: (error, stack) {},
    )!;

    request(active);
    await tester.pump();
    final freshRequest = request(fresh);
    active.completer.fail(StateError('done'));
    freshRequest.refreshPriority();
    await tester.idle();
    expect(fresh.loads, 0);
    await tester.pump();
    expect(fresh.loads, 1);
    fresh.completer.fail(StateError('done'));
    await tester.pump();
  });

  testWidgets('completion during build waits until layout has finished', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue(maxActive: 1);
    addTearDown(queue.dispose);
    final active = _ControlledProvider();
    final waiting = _ControlledProvider();
    final phases = <SchedulerPhase>[];
    for (final provider in [active, waiting]) {
      queue.request(
        provider,
        canStart: () => true,
        onStart: () => phases.add(tester.binding.schedulerPhase),
        onError: (error, stack) {},
      );
    }
    await tester.pump();
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          active.completer.fail(StateError('done'));
          expect(waiting.loads, 0);
          return const SizedBox();
        },
      ),
    );
    expect(waiting.loads, 1);
    expect(phases, everyElement(SchedulerPhase.postFrameCallbacks));
    waiting.completer.fail(StateError('done'));
    await tester.pump();
  });

  testWidgets('synchronous cache hits cannot drain the queue in a microtask', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final image = (await tester.runAsync(() => createTestImage(cache: false)))!;
    addTearDown(image.dispose);
    var starts = 0;
    for (var i = 0; i < 8; i++) {
      queue.request(
        _ControlledProvider(imageAtLoad: image),
        canStart: () => true,
        onStart: () => starts++,
        onError: (error, stack) => fail('$error'),
      );
    }
    await tester.pump();
    expect(starts, 2);
    await tester.idle();
    expect(starts, 2);
    await tester.pumpAndSettle();
    expect(starts, 8);
  });

  testWidgets('disposing the queue suppresses callbacks and pending starts', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue(maxActive: 1);
    final active = _ControlledProvider();
    final waiting = _ControlledProvider();
    var starts = 0;
    var errors = 0;
    for (final provider in [active, waiting]) {
      queue.request(
        provider,
        canStart: () => true,
        onStart: () => starts++,
        onError: (error, stack) => errors++,
      );
    }
    await tester.pump();
    queue.dispose();
    active.completer.fail(StateError('cancelled'));
    await tester.idle();
    await tester.pump();
    expect(starts, 1);
    expect(errors, 0);
    expect(waiting.loads, 0);
  });

  testWidgets('keeps an uncached frame alive until widgets can attach', (
    tester,
  ) async {
    final queue = ArtworkDecodeQueue();
    addTearDown(queue.dispose);
    final image = (await tester.runAsync(() => createTestImage(cache: false)))!;
    addTearDown(image.dispose);
    final cache = PaintingBinding.instance.imageCache;
    final previousLimit = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 0;
    addTearDown(() => cache.maximumSizeBytes = previousLimit);
    final provider = _ControlledProvider();
    queue.request(
      provider,
      canStart: () => true,
      onStart: () {},
      onError: (error, stack) => fail('$error'),
    );
    await tester.pump();
    provider.completer.complete(image);
    expect(provider.completer.hasListeners, isTrue);
    expect(cache.statusForKey(provider).live, isTrue);
    expect(cache.statusForKey(provider).keepAlive, isFalse);
    await tester.pump();
    expect(provider.completer.hasListeners, isFalse);
    expect(cache.statusForKey(provider).live, isFalse);
  });
}

class _ControlledProvider extends ImageProvider<_ControlledProvider> {
  _ControlledProvider({this.imageAtLoad});

  final ui.Image? imageAtLoad;
  final completer = _ControlledCompleter();
  int loads = 0;

  @override
  Future<_ControlledProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ControlledProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    final image = imageAtLoad;
    if (image != null) completer.complete(image);
    return completer;
  }
}

class _ControlledCompleter extends ImageStreamCompleter {
  void complete(ui.Image image) => setImage(ImageInfo(image: image.clone()));

  void fail(Object error) => reportError(
    context: ErrorDescription('controlled image decode'),
    exception: error,
    stack: StackTrace.current,
    silent: true,
  );
}
