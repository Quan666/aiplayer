import 'dart:async';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/playback/music_controller.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/music_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const entries = [SourceEntry(name: 'Song.flac', path: 'Song.flac')];
  for (final (mobile, pause, autoplay) in [
    (true, true, false),
    (true, false, true),
    (false, true, true),
  ]) {
    testWidgets(
      'replacement waiting for decoder cleanup retains lifecycle intent mobile=$mobile pause=$pause',
      (tester) async {
        final firstModel = _Model(pause), nextModel = _Model(pause);
        final controllers = <_Controller>[];
        Widget page(AppModel model) => MaterialApp(
          home: MusicPage(
            key: const ValueKey('music'),
            model: model,
            sourceId: 'nas',
            entries: entries,
            mobileLifecycle: mobile,
            createController:
                ({
                  required model,
                  required sourceId,
                  required entries,
                  required initialIndex,
                  required backgrounded,
                  required mobileLifecycle,
                }) {
                  final value = _Controller(entries, backgrounded);
                  controllers.add(value);
                  return value;
                },
          ),
        );
        final closing = Completer<void>();
        try {
          await tester.pumpWidget(page(firstModel));
          await tester.pump();
          expect(controllers.single.starts, [true]);
          controllers.single.closeGate = closing;
          await tester.pumpWidget(page(nextModel));
          expect(controllers, hasLength(1));
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.idle();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.idle();
          closing.complete();
          await tester.idle();
          expect(controllers, hasLength(2));
          expect(controllers.last.starts, [autoplay]);
        } finally {
          if (!closing.isCompleted) closing.complete();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(const SizedBox());
          await MusicPage.waitForDisposals();
          firstModel.dispose();
          nextModel.dispose();
        }
      },
    );
  }

  testWidgets(
    'enabling pause policy while replacement waits in background revokes its old play intent',
    (tester) async {
      final model = _Model(false);
      final controllers = <_Controller>[];
      Widget page(String source) => MaterialApp(
        home: MusicPage(
          key: const ValueKey('music'),
          model: model,
          sourceId: source,
          entries: entries,
          mobileLifecycle: true,
          createController:
              ({
                required model,
                required sourceId,
                required entries,
                required initialIndex,
                required backgrounded,
                required mobileLifecycle,
              }) {
                final value = _Controller(entries, backgrounded);
                controllers.add(value);
                return value;
              },
        ),
      );
      final closing = Completer<void>();
      try {
        await tester.pumpWidget(page('a'));
        await tester.pump();
        controllers.single.closeGate = closing;
        await tester.pumpWidget(page('b'));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        model.setPause(true);
        model.setPause(false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        closing.complete();
        await tester.idle();
        expect(controllers.last.starts, [false]);
      } finally {
        if (!closing.isCompleted) closing.complete();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await MusicPage.waitForDisposals();
        model.dispose();
      }
    },
  );

  testWidgets(
    'initially paused music page opens stopped and stays stopped on resume',
    (tester) async {
      final model = _Model(true);
      late _Controller controller;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: MusicPage(
              model: model,
              sourceId: 'nas',
              entries: entries,
              mobileLifecycle: true,
              createController: ({
                required model,
                required sourceId,
                required entries,
                required initialIndex,
                required backgrounded,
                required mobileLifecycle,
              }) => controller = _Controller(entries, backgrounded),
            ),
          ),
        );
        tester.binding.scheduleForcedFrame();
        await tester.pump();
        await tester.idle();
        expect(controller.starts, [false]);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.idle();
        expect(controller.starts, [false]);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await MusicPage.waitForDisposals();
        model.dispose();
      }
    },
  );
}

class _Model extends ChangeNotifier implements AppModel {
  bool pause;
  _Model(this.pause);
  @override
  AppPreferences get preferences =>
      AppPreferences({'pauseOnBackground': pause});
  void setPause(bool value) {
    pause = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends ChangeNotifier implements MusicPlaybackController {
  @override
  final List<SourceEntry> entries;
  @override
  bool backgrounded;
  @override
  late final queue = MusicQueue(entries.length);
  @override
  PlaybackSession? get session => null;
  @override
  String get title => entries[queue.index].name;
  @override
  String get error => '';
  @override
  bool get loading => false;
  final starts = <bool>[];
  Completer<void>? closeGate;
  Future<void>? _closing;
  _Controller(this.entries, this.backgrounded);
  @override
  Future<void> start({bool play = true}) async => starts.add(play);
  @override
  Future<void> close() => _closing ??= closeGate?.future ?? Future.value();
  @override
  void setBackgrounded(bool value) => backgrounded = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
