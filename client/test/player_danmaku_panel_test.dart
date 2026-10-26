import 'dart:collection';

import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_danmaku_panel.dart';
import 'package:aiplayer/ui/player_danmaku_list.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('danmaku sheet fits content and preserves edited search fields', (
    tester,
  ) async {
    _desktopSize(tester);
    final (session, danmaku) = _sessions();
    await _open(tester, session, danmaku);
    final panel = tester.getSize(find.byType(PlayerGlass));
    expect(panel.height, lessThan(800));
    expect(find.text('密度').hitTestable(), findsOneWidget);
    expect(_scroll(tester).maxScrollExtent, 0);
    final title = find.byType(TextField).first;
    expect(
      tester.widget<TextField>(title).controller!.text,
      '用【循环利息】强制收回借出的魔力',
    );
    await tester.enterText(title, '修改后的作品 [原名]');
    danmaku.setOffset(.5);
    await tester.pump();
    expect(tester.widget<TextField>(title).controller!.text, '修改后的作品 [原名]');
    expect(tester.getSize(find.byType(PlayerGlass)).height, panel.height);
    // The controllers remain valid throughout the modal exit animation.
    Navigator.of(tester.element(find.byType(PlayerDanmakuPanel))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('danmaku sheet scrolls in a short window with the keyboard', (
    tester,
  ) async {
    _desktopSize(tester);
    final (session, danmaku) = _sessions();
    await _open(tester, session, danmaku);
    tester.view.physicalSize = const Size(844, 600);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PlayerGlass)).height,
      lessThanOrEqualTo(340),
    );
    final scroll = _scroll(tester);
    expect(scroll.maxScrollExtent, greaterThan(0));
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('密度').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large danmaku candidate lists stay lazy and select the last match',
    (tester) async {
      _desktopSize(tester);
      final (session, danmaku) = _sessions();
      await _open(tester, session, danmaku);
      await tester.enterText(find.byType(TextField).first, '保留的搜索名称');
      FocusManager.instance.primaryFocus?.unfocus();
      danmaku.showCandidates([
        for (var i = 0; i < 1000; i++) EpisodeMatch('$i', '作品', '$i'),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      expect(find.byKey(const ValueKey('danmaku-candidate-999')), findsNothing);
      final scroll = _scroll(tester);
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = find.byKey(const ValueKey('danmaku-candidate-999'));
      expect(last.hitTestable(), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.tap(last);
      expect(danmaku.selected, '999');
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      _scroll(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '保留的搜索名称',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tabs retain drafts and display loaded and candidate counts', (
    tester,
  ) async {
    _desktopSize(tester);
    final (session, danmaku) = _sessions();
    danmaku.showComments(const [DanmakuComment(1, '已加载', 0xffffff, 0)]);
    danmaku.showCandidates(const [
      EpisodeMatch('2', '有数量', '1', 0, 123),
      EpisodeMatch('3', '无数量', '1'),
    ]);
    await _open(tester, session, danmaku);
    expect(find.text('弹幕 · 1 条'), findsOneWidget);
    expect(find.text('123 条'), findsOneWidget);
    expect(find.text('数量未知'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '保留搜索');
    expect(session.position.listened, isFalse);
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(find.text('已加载'), findsOneWidget);
    expect(session.position.listened, isTrue);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(session.position.listened, isFalse);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '保留搜索',
    );
  });

  testWidgets('time list stays compact and lazy while seeking and shifting', (
    tester,
  ) async {
    final position = _Position()..value = const Duration(seconds: 12000);
    final longText = List.filled(12, '这是一条需要自然换行并且完整展示的长弹幕。').join();
    final comments = _Comments([
      for (var i = 0; i < 10000; i++)
        DanmakuComment(i * 2, i == 6001 ? longText : '弹幕 $i', 0xffffff, 0),
    ]);
    addTearDown(position.dispose);
    Future<void> show(double shift) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 480,
            height: 240,
            child: PlayerDanmakuList(
              position: position,
              comments: comments,
              shift: shift,
            ),
          ),
        ),
      ),
    );
    await show(0);
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('danmaku-comment-6000'));
    expect(current.hitTestable(), findsOneWidget);
    expect(tester.getSize(current).height, 24);
    expect(tester.widget<Semantics>(current).properties.selected, isTrue);
    final longRow = find.byKey(const ValueKey('danmaku-comment-6001'));
    expect(tester.getSize(longRow).height, greaterThan(24));
    final longWidget = tester.widget<Text>(find.text(longText));
    expect(longWidget.maxLines, isNull);
    expect(longWidget.overflow, isNot(TextOverflow.ellipsis));
    expect(comments.reads, lessThan(100));
    expect(find.text('弹幕 0'), findsNothing);

    comments.reads = 0;
    position.value = const Duration(seconds: 12001);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(comments.reads, lessThan(35));

    position.value = const Duration(seconds: 20);
    comments.reads = 0;
    await tester.pumpAndSettle();
    expect(comments.reads, lessThan(100));
    expect(
      find.byKey(const ValueKey('danmaku-comment-10')).hitTestable(),
      findsOneWidget,
    );
    await show(10);
    await tester.pumpAndSettle();
    final shifted = find.byKey(const ValueKey('danmaku-comment-5'));
    expect(shifted.hitTestable(), findsOneWidget);
    expect(tester.widget<Semantics>(shifted).properties.selected, isTrue);
    expect(
      find.descendant(of: shifted, matching: find.text('00:20')),
      findsOneWidget,
    );
    position.value = const Duration(seconds: 12000);
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    scroll.jumpTo(60000);
    comments.reads = 0;
    await show(-7000);
    await tester.pumpAndSettle();
    expect(comments.reads, lessThan(150));
    expect(
      find.byKey(const ValueKey('danmaku-comment-9500')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual browsing survives playback and refresh until returning to current',
    (tester) async {
      final position = _Position()..value = const Duration(seconds: 500);
      final comments = [
        for (var i = 0; i < 1000; i++)
          DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
      ];
      addTearDown(position.dispose);
      await _showTimeList(tester, position, comments);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -144));
      await tester.pumpAndSettle();
      final scroll = _timeScroll(tester);
      final offset = scroll.pixels;
      expect(offset, greaterThan(100));
      expect(
        find.byKey(const ValueKey('danmaku-follow-current')),
        findsOneWidget,
      );

      for (final second in [501, 502, 508]) {
        position.value = Duration(seconds: second);
        await tester.pumpAndSettle();
        expect(scroll.pixels, offset);
      }
      final current = find.byKey(const ValueKey('danmaku-comment-508'));
      expect(current.hitTestable(), findsOneWidget);
      expect(tester.widget<Semantics>(current).properties.selected, isTrue);

      // The periodic refresh can replace the snapshot without taking control
      // of a list the user is reading.
      await _showTimeList(tester, position, [
        ...comments,
        const DanmakuComment(1001, '刷新增加的弹幕', 0xffffff, 0),
      ]);
      await tester.pumpAndSettle();
      expect(scroll.pixels, offset);
      expect(
        find.byKey(const ValueKey('danmaku-follow-current')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('danmaku-follow-current')));
      await tester.pumpAndSettle();
      expect(scroll.pixels, 0);
      expect(
        find.byKey(const ValueKey('danmaku-follow-current')),
        findsNothing,
      );
      expect(current.hitTestable(), findsOneWidget);
      position.value = const Duration(seconds: 510);
      await tester.pumpAndSettle();
      final next = find.byKey(const ValueKey('danmaku-comment-510'));
      expect(next.hitTestable(), findsOneWidget);
      expect(tester.widget<Semantics>(next).properties.selected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mouse wheel leaves the list in manual browsing mode', (
    tester,
  ) async {
    final position = _Position()..value = const Duration(seconds: 500);
    addTearDown(position.dispose);
    await _showTimeList(tester, position, [
      for (var i = 0; i < 1000; i++)
        DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
    ]);
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, 144),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = _timeScroll(tester);
    final offset = scroll.pixels;
    expect(offset, greaterThan(100));
    expect(
      find.byKey(const ValueKey('danmaku-follow-current')),
      findsOneWidget,
    );
    position.value = const Duration(seconds: 550);
    await tester.pumpAndSettle();
    expect(scroll.pixels, offset);
    expect(find.byKey(const ValueKey('danmaku-comment-550')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard scroll intents preserve manual browsing', (
    tester,
  ) async {
    final position = _Position()..value = const Duration(seconds: 500);
    addTearDown(position.dispose);
    await _showTimeList(tester, position, [
      for (var i = 0; i < 1000; i++)
        DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
    ]);
    await tester.pumpAndSettle();
    Actions.invoke(
      tester.element(find.byType(SliverList).last),
      const ScrollIntent(
        direction: AxisDirection.down,
        type: ScrollIncrementType.page,
      ),
    );
    await tester.pumpAndSettle();
    final scroll = _timeScroll(tester);
    final offset = scroll.pixels;
    expect(offset, greaterThan(100));
    expect(
      find.byKey(const ValueKey('danmaku-follow-current')),
      findsOneWidget,
    );
    position.value = const Duration(seconds: 550);
    await tester.pumpAndSettle();
    expect(scroll.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('truncated browsing snapshots do not measure a long prefix', (
    tester,
  ) async {
    final position = _Position()..value = const Duration(seconds: 100);
    final comments = [
      for (var i = 0; i < 10000; i++)
        DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
    ];
    addTearDown(position.dispose);
    await _showTimeList(tester, position, comments);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -144));
    await tester.pumpAndSettle();
    final scroll = _timeScroll(tester);
    scroll.jumpTo(60000);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('danmaku-follow-current')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('danmaku-comment-2600')).hitTestable(),
      findsOneWidget,
    );

    // The old anchor (100) still exists, but the entire visible window has
    // been removed. Retaining its large offset would measure ~1900 rows.
    final shortened = _Comments(comments.take(2000).toList());
    await _showTimeList(tester, position, shortened);
    await tester.pumpAndSettle();
    expect(shortened.reads, lessThan(150));
    expect(
      find.byKey(const ValueKey('danmaku-follow-current')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('danmaku-comment-1999')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('danmaku-comment-100')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit player seeks resume following including the same time',
    (tester) async {
      _desktopSize(tester);
      final (session, danmaku) = _sessions();
      session.position.value = const Duration(seconds: 500);
      danmaku.showComments([
        for (var i = 0; i < 1000; i++)
          DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
      ]);
      await _open(tester, session, danmaku);
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();

      for (final target in [500, 900]) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -144));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('danmaku-follow-current')),
          findsOneWidget,
        );
        session.seekTo(Duration(seconds: target));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('danmaku-follow-current')),
          findsNothing,
        );
        final current = find.byKey(ValueKey('danmaku-comment-$target'));
        expect(current.hitTestable(), findsOneWidget);
        expect(tester.widget<Semantics>(current).properties.selected, isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'equal-time comments highlight together and background stops now',
    (tester) async {
      final position = _Position()..value = const Duration(seconds: 500);
      final comments = _Comments([
        for (var i = 0; i < 10000; i++)
          DanmakuComment((i ~/ 3).toDouble(), '弹幕 $i', 0xffffff, 0),
      ]);
      addTearDown(position.dispose);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 480,
              height: 240,
              child: PlayerDanmakuList(
                position: position,
                comments: comments,
                shift: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final index in [1500, 1501, 1502]) {
        final row = find.byKey(ValueKey('danmaku-comment-$index'));
        expect(row.hitTestable(), findsOneWidget);
        expect(tester.widget<Semantics>(row).properties.selected, isTrue);
      }
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -100),
        1500,
      );
      expect(scroll.isScrollingNotifier.value, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Intentionally do not pump after paused: no next frame is required.
      expect(scroll.isScrollingNotifier.value, isFalse);
      expect(position.listened, isFalse);
      final offset = scroll.pixels;
      comments.reads = 0;
      position.value = const Duration(seconds: 2000);
      position.value = const Duration(seconds: 2500);
      expect(comments.reads, 0);
      expect(scroll.pixels, offset);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(position.listened, isTrue);
      await tester.pumpAndSettle();
      expect(scroll.pixels, offset);
      expect(
        find.byKey(const ValueKey('danmaku-follow-current')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('danmaku-comment-7500')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('danmaku-follow-current')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('danmaku-comment-7500')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'initial background and hidden replacement resume the latest source',
    (tester) async {
      final original = _Position()..value = const Duration(seconds: 9000);
      final replacement = _Position()..value = const Duration(seconds: 2);
      final large = _Comments([
        for (var i = 0; i < 10000; i++)
          DanmakuComment(i.toDouble(), '弹幕 $i', 0xffffff, 0),
      ]);
      const small = [
        DanmakuComment(1, '新第一条', 0xffffff, 0),
        DanmakuComment(2, '新第二条', 0xffffff, 0),
      ];
      addTearDown(original.dispose);
      addTearDown(replacement.dispose);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      Future<void> show(
        _Position position,
        List<DanmakuComment> comments, {
        bool visible = true,
      }) => tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: visible,
            child: SizedBox(
              height: 240,
              child: PlayerDanmakuList(
                position: position,
                comments: comments,
                shift: 0,
              ),
            ),
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await show(original, large);
      expect(original.listened, isFalse);
      large.reads = 0;
      original.value = const Duration(seconds: 9500);
      expect(large.reads, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(original.listened, isTrue);
      expect(
        find.byKey(const ValueKey('danmaku-comment-9500')).hitTestable(),
        findsOneWidget,
      );
      await show(original, large, visible: false);
      expect(original.listened, isFalse);
      await show(replacement, small, visible: false);
      expect(replacement.listened, isFalse);
      expect(tester.takeException(), isNull);
      await show(replacement, small);
      await tester.pumpAndSettle();
      expect(original.listened, isFalse);
      expect(replacement.listened, isTrue);
      expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('danmaku-comment-1')))
            .properties
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

void _desktopSize(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

(_Session, _Danmaku) _sessions() {
  final store = AppStore(':memory:');
  final session = _Session();
  final danmaku = _Danmaku(store);
  addTearDown(store.dispose);
  addTearDown(danmaku.dispose);
  addTearDown(session.dispose);
  addTearDown(session.position.dispose);
  return (session, danmaku);
}

Future<void> _open(
  WidgetTester tester,
  _Session session,
  _Danmaku danmaku,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => PlayerSheet(
                child: PlayerDanmakuPanel(session: session, danmaku: danmaku),
              ),
            ),
            child: const Text('打开弹幕'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开弹幕'));
  await tester.pumpAndSettle();
}

ScrollPosition _scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(PlayerMenuList),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

Future<void> _showTimeList(
  WidgetTester tester,
  _Position position,
  List<DanmakuComment> comments,
) => tester.pumpWidget(
  MaterialApp(
    home: Center(
      child: SizedBox(
        width: 480,
        height: 240,
        child: PlayerDanmakuList(
          position: position,
          comments: comments,
          shift: 0,
        ),
      ),
    ),
  ),
);

ScrollPosition _timeScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(PlayerDanmakuList),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

class _Session extends Fake with ChangeNotifier implements PlaybackSession {
  @override
  int timelineRevision = 0;
  @override
  final _Position position = _Position();
  @override
  final model = _Model();
  @override
  ReleaseName get danmakuIdentity =>
      const ReleaseName('用【循环利息】强制收回借出的魔力', '1', '3');
  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    model.settings.addAll(changes);
  }

  void seekTo(Duration value) {
    timelineRevision++;
    position.value = value;
    notifyListeners();
  }
}

class _Model extends Fake implements AppModel {
  @override
  final settings = <String, dynamic>{};
}

class _Danmaku extends DanmakuSession {
  String? selected;
  _Danmaku(AppStore store)
    : super(
        store,
        DanmuApiClient('https://offline.invalid', 'fixture'),
        'video',
      );

  void showCandidates(List<EpisodeMatch> matches) {
    candidates = matches;
    notifyListeners();
  }

  void showComments(List<DanmakuComment> values) {
    episodeId = '1';
    comments = values;
    notifyListeners();
  }

  @override
  Future<void> select(EpisodeMatch match, {String? savedLabel}) async {
    selected = match.episodeId;
  }
}

class _Position extends ValueNotifier<Duration> {
  _Position() : super(Duration.zero);
  bool get listened => hasListeners;
}

class _Comments extends ListBase<DanmakuComment> {
  final List<DanmakuComment> values;
  int reads = 0;
  _Comments(this.values);
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  DanmakuComment operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, DanmakuComment value) =>
      throw UnsupportedError('immutable');
}
