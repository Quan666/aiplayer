import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Read {
  final CancelToken? cancel;
  final gate = Completer<void>();
  _Read(this.cancel);
}

class _Model extends AppModel {
  _Model(AppStore store)
    : super(store, Directory.systemTemp, backgroundWork: false);
  final reads = <_Read>[];
  bool hold = false;

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    final request = _Read(cancel);
    reads.add(request);
    final wait = hold;
    final snapshot = await super.loadLibrarySnapshot(
      query: query,
      cancel: cancel,
    );
    if (wait) await request.gate.future;
    // Deliberately return a late result to verify the widget owns cancellation.
    return snapshot;
  }

  @override
  Future<void> ensureMediaPreview(String id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late _Model model;

  void populate(AppStore target, {String prefix = 'video'}) {
    for (var i = 0; i < 32; i++) {
      final id = '$prefix-$i';
      target.save('media', id, {'title': id, 'series': id, 'size': 100});
      target.save('progress', '$id:100', {
        'position': 10,
        'duration': 100,
        'updatedAt': DateTime.utc(2026, 10, 23, 0, i).toIso8601String(),
      });
    }
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = AppStore(':memory:');
    populate(store);
    model = _Model(store);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
  });

  final grid = find.byKey(const PageStorageKey('library-history-grid'));
  ScrollPosition scrollPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)).first,
      )
      .position;

  Future<void> openHistory(WidgetTester tester) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    expect(grid, findsOneWidget);
  }

  void progress(int value) {
    store.save('progress', 'video-31:100', {
      'position': value,
      'duration': 100,
      'updatedAt': '2026-10-23T00:31:00Z',
    });
    model.changed();
  }

  testWidgets('history ignores presentation-only notifications', (
    tester,
  ) async {
    await openHistory(tester);
    final reads = model.reads.length;
    for (var i = 0; i < 20; i++) {
      model.status = '$i';
      store.setLocal('episodeTitle:video-31', 'Episode $i');
      model.changed();
    }
    await tester.pumpAndSettle();
    expect(model.reads, hasLength(reads));
    progress(50);
    await tester.pumpAndSettle();
    expect(model.reads, hasLength(reads + 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'covered history cancels reads and resumes once at the same offset',
    (tester) async {
      await openHistory(tester);
      final position = scrollPosition(tester);
      position.jumpTo(500);
      await tester.pumpAndSettle();
      model.hold = true;
      progress(20);
      await tester.pump();
      final pending = model.reads.last;
      final reads = model.reads.length;
      final navigator = Navigator.of(tester.element(grid));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(pending.cancel!.cancelled, true);
      for (var i = 21; i < 40; i++) {
        progress(i);
      }
      await tester.pump();
      expect(model.reads, hasLength(reads));
      pending.gate.complete();
      model.hold = false;
      await tester.pump();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(model.reads, hasLength(reads + 1));
      expect(scrollPosition(tester).pixels, 500);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background history coalesces updates and refreshes after resume',
    (tester) async {
      await openHistory(tester);
      final reads = model.reads.length;
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      for (var i = 20; i < 40; i++) {
        progress(i);
      }
      await tester.pump();
      expect(model.reads, hasLength(reads));
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      expect(model.reads, hasLength(reads + 1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scrolling history merges updates until idle without resetting offset',
    (tester) async {
      await openHistory(tester);
      final reads = model.reads.length;
      final gesture = await tester.startGesture(tester.getCenter(grid));
      await gesture.moveBy(const Offset(0, -180));
      await tester.pump(const Duration(milliseconds: 30));
      for (var i = 20; i < 40; i++) {
        progress(i);
      }
      await tester.pump();
      expect(model.reads, hasLength(reads));
      final offset = scrollPosition(tester).pixels;
      expect(offset, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(model.reads, hasLength(reads + 1));
      expect(scrollPosition(tester).pixels, greaterThanOrEqualTo(offset));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'replacing the model cancels old history and ignores its late result',
    (tester) async {
      await openHistory(tester);
      model.hold = true;
      progress(20);
      await tester.pump();
      final pending = model.reads.last;
      final replacementStore = AppStore(':memory:');
      populate(replacementStore, prefix: 'replacement');
      final replacement = _Model(replacementStore);
      try {
        await tester.pumpWidget(AIPlayerApp(model: replacement));
        await tester.pumpAndSettle();
        expect(pending.cancel!.cancelled, true);
        expect(replacement.reads, hasLength(1));
        expect(
          find.byKey(const ValueKey('history:replacement-31')),
          findsOneWidget,
        );
        pending.gate.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('history:video-31')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        replacement.dispose();
        replacementStore.dispose();
      }
    },
  );

  testWidgets('disposing history cancels its pending read', (tester) async {
    await openHistory(tester);
    model.hold = true;
    progress(30);
    await tester.pump();
    final pending = model.reads.last;
    await tester.pumpWidget(const SizedBox());
    expect(pending.cancel!.cancelled, true);
    pending.gate.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
