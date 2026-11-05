import 'package:aiplayer/ui/album_viewer_route.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('photo navigation uses a lateral slide with live pixels', (
    tester,
  ) async {
    final route = AlbumViewerRoute<void>(builder: (_) => const SizedBox());
    final progress = ValueNotifier<double>(0.25);
    const page = SizedBox(key: ValueKey('photo-page'));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, _) => ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => route.transitionsBuilder(
            context,
            AlwaysStoppedAnimation(value),
            const AlwaysStoppedAnimation(0),
            page,
          ),
        ),
      ),
    );
    expect(route.allowSnapshotting, isFalse);
    final pixels = tester.element(find.byKey(page.key!));
    final first = tester
        .widget<SlideTransition>(
          find.ancestor(
            of: find.byKey(page.key!),
            matching: find.byType(SlideTransition),
          ),
        )
        .position
        .value;
    expect(first.dx, greaterThan(0));
    expect(first.dy, 0);
    expect(
      find.ancestor(
        of: find.byKey(page.key!),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    progress.value = 0.75;
    await tester.pump();
    final second = tester
        .widget<SlideTransition>(
          find.ancestor(
            of: find.byKey(page.key!),
            matching: find.byType(SlideTransition),
          ),
        )
        .position
        .value;
    expect(second.dx, lessThan(first.dx));
    expect(tester.element(find.byKey(page.key!)), same(pixels));
    // Reversing the route pulls the same live page out to the right.
    progress.value = 0.25;
    await tester.pump();
    expect(
      tester
          .widget<SlideTransition>(
            find.ancestor(
              of: find.byKey(page.key!),
              matching: find.byType(SlideTransition),
            ),
          )
          .position
          .value,
      first,
    );
    await tester.pumpWidget(const SizedBox());
    progress.dispose();
  });

  testWidgets('photo navigation respects disabled decorative motion', (
    tester,
  ) async {
    final route = AlbumViewerRoute<void>(builder: (_) => const SizedBox());
    const page = SizedBox(key: ValueKey('photo-page'));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, _) => MotionScope(
          enabled: false,
          child: Builder(
            builder: (context) => route.transitionsBuilder(
              context,
              const AlwaysStoppedAnimation(0.25),
              const AlwaysStoppedAnimation(0),
              page,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(page.key!), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(page.key!),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
  });
}
