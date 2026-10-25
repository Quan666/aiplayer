import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/danmaku/session.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_danmaku_panel.dart';
import 'package:aiplayer/ui/player_theme.dart';
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
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '保留的搜索名称',
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

class _Session extends Fake implements PlaybackSession {
  @override
  final model = _Model();
  @override
  ReleaseName get danmakuIdentity =>
      const ReleaseName('用【循环利息】强制收回借出的魔力', '1', '3');
  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    model.settings.addAll(changes);
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

  @override
  Future<void> select(EpisodeMatch match, {String? savedLabel}) async {
    selected = match.episodeId;
  }
}
