import 'dart:async';

import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(
    () => WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );

  testWidgets('paused without a frame ends scrolling immediately', (
    tester,
  ) async {
    final controller = ScrollController();
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          onActivityChanged: changes.add,
          child: ListView(
            controller: controller,
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    final scrolling = controller.animateTo(
      2000,
      duration: const Duration(seconds: 10),
      curve: Curves.linear,
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.position.isScrollingNotifier.value, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(controller.position.isScrollingNotifier.value, isFalse);
    expect(changes, [true, false]);
    await scrolling;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  Future<void> wheel(WidgetTester tester) => tester.sendEventToBinding(
    PointerScrollEvent(
      kind: PointerDeviceKind.mouse,
      position: tester.getCenter(find.byType(ListView)),
      scrollDelta: const Offset(0, 40),
    ),
  );

  testWidgets('paused without a frame cancels shared scroll wake-up timers', (
    tester,
  ) async {
    final timers = <Timer>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: ListView(children: const [SizedBox(height: 4000)]),
        ),
      ),
    );
    await runZoned(
      () async {
        await wheel(tester);
        expect(timers.any((timer) => timer.isActive), isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(timers.every((timer) => !timer.isActive), isTrue);
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == const Duration(milliseconds: 64) ||
              duration == const Duration(milliseconds: 120)) {
            timers.add(timer);
          }
          return timer;
        },
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wheel bursts share one idle transition without rebuilding', (
    tester,
  ) async {
    final changes = <bool>[];
    late ValueListenable<bool> activity;
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          onActivityChanged: changes.add,
          child: Builder(
            builder: (context) {
              builds++;
              activity = ArtworkScrollScope.maybeOf(context)!;
              return ListView(
                physics: const ClampingScrollPhysics(),
                children: const [SizedBox(height: 4000)],
              );
            },
          ),
        ),
      ),
    );
    expect(activity.value, isFalse);
    expect(changes, isEmpty);
    await wheel(tester);
    await tester.pump();
    expect(activity.value, isTrue);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .isScrollingNotifier
          .value,
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await wheel(tester);
    await tester.pump(const Duration(milliseconds: 119));
    expect(activity.value, isTrue);
    expect(changes, [true]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(activity.value, isFalse);
    expect(changes, [true, false]);
    expect(builds, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stationary trackpad gesture remains active until it ends', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          onActivityChanged: changes.add,
          child: ListView(
            physics: const ClampingScrollPhysics(),
            children: const [SizedBox(height: 4000)],
          ),
        ),
      ),
    );
    final location = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(
      location,
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomUpdate(location, pan: const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 300));
    expect(changes, [true]);
    await gesture.panZoomEnd();
    await tester.pump(const Duration(milliseconds: 120));
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stationary gestures do not repeatedly wake an idle timer', (
    tester,
  ) async {
    var idleTimers = 0;
    await runZoned(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: ArtworkScrollScope(
              child: ListView(children: const [SizedBox(height: 4000)]),
            ),
          ),
        );
        final location = tester.getCenter(find.byType(ListView));
        final gesture = await tester.startGesture(
          location,
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomUpdate(location, pan: const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 200));
        final afterStart = idleTimers;
        await tester.pump(const Duration(seconds: 3));
        expect(idleTimers, afterStart);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await gesture.panZoomEnd();
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pumpWidget(const SizedBox());
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(milliseconds: 120)) idleTimers++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
  });

  testWidgets('hidden regions end scrolling and resume idle', (tester) async {
    final controller = ScrollController();
    final changes = <bool>[];
    late StateSetter update;
    var enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: enabled,
              child: ArtworkScrollScope(
                onActivityChanged: changes.add,
                child: ListView(
                  controller: controller,
                  children: const [SizedBox(height: 4000)],
                ),
              ),
            );
          },
        ),
      ),
    );
    final scrolling = controller.animateTo(
      2000,
      duration: const Duration(seconds: 10),
      curve: Curves.linear,
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(changes, [true]);
    update(() => enabled = false);
    await tester.pump();
    await scrolling;
    expect(controller.position.isScrollingNotifier.value, isFalse);
    expect(changes, [true, false]);
    await tester.pump(const Duration(seconds: 2));
    expect(changes, [true, false]);
    update(() => enabled = true);
    await tester.pump();
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('removing a scrolling child releases its region', (tester) async {
    final changes = <bool>[];
    late StateSetter update;
    var showList = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          onActivityChanged: changes.add,
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return showList
                  ? ListView(children: const [SizedBox(height: 4000)])
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    final location = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(
      location,
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomUpdate(location, pan: const Offset(0, -60));
    await tester.pump();
    expect(changes, [true]);
    update(() => showList = false);
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pump(const Duration(milliseconds: 120));
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nested scopes keep outer refreshes deferred too', (
    tester,
  ) async {
    final outer = <bool>[], inner = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          onActivityChanged: outer.add,
          child: ArtworkScrollScope(
            onActivityChanged: inner.add,
            child: ListView(children: const [SizedBox(height: 4000)]),
          ),
        ),
      ),
    );
    await wheel(tester);
    await tester.pump();
    expect(outer, [true]);
    expect(inner, [true]);
    await tester.pump(const Duration(milliseconds: 120));
    expect(outer, [true, false]);
    expect(inner, [true, false]);
    await wheel(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 240));
    expect(outer, [true, false, true]);
    expect(inner, [true, false, true]);
  });

  testWidgets('inner scopes remain busy until their outer scroll ends', (
    tester,
  ) async {
    final outer = ScrollController(), inner = ScrollController();
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 200,
                child: ArtworkScrollScope(
                  onActivityChanged: changes.add,
                  child: ListView(
                    controller: inner,
                    scrollDirection: Axis.horizontal,
                    children: const [SizedBox(width: 4000)],
                  ),
                ),
              ),
              const SizedBox(height: 4000),
            ],
          ),
        ),
      ),
    );
    final drag = outer.position.drag(DragStartDetails(), () {});
    await tester.pump();
    // The inner scope has received no scroll notification of its own.
    expect(changes, [true]);
    inner.position.pointerScroll(40);
    await tester.pump(const Duration(milliseconds: 240));
    expect(changes, [true]);
    drag.end(DragEndDetails(primaryVelocity: 0));
    await tester.pump(const Duration(milliseconds: 120));
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox());
    outer.dispose();
    inner.dispose();
  });

  testWidgets('mounting under a busy parent reports after ancestor build', (
    tester,
  ) async {
    final controller = ScrollController();
    final changes = <bool>[];
    late StateSetter update;
    var showInner = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ArtworkScrollScope(
              child: ListView(
                controller: controller,
                children: [
                  if (showInner)
                    ArtworkScrollScope(
                      onActivityChanged: (active) {
                        update(() => changes.add(active));
                      },
                      child: const SizedBox(height: 200),
                    ),
                  const SizedBox(height: 4000),
                ],
              ),
            );
          },
        ),
      ),
    );
    final drag = controller.position.drag(DragStartDetails(), () {});
    update(() => showInner = true);
    await tester.pump();
    expect(changes, [true]);
    expect(tester.takeException(), isNull);
    drag.end(DragEndDetails(primaryVelocity: 0));
    await tester.pump(const Duration(milliseconds: 120));
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
