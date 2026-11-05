import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

bool focusedWithin(Finder finder) {
  final elements = finder.evaluate().toSet();
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus is! Element) return false;
  var found = elements.contains(focus);
  focus.visitAncestorElements((element) {
    found |= elements.contains(element);
    return !found;
  });
  return found;
}

void main() {
  late Directory directory;
  late AppStore store;
  late AppModel model;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('television-settings-');
    store = AppStore(':memory:')..setLocal('settings', {'autoDiscover': false});
    model = AppModel(store, directory, backgroundWork: false);
  });

  tearDown(() async {
    model.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('TV source options reorder without dragging and retain focus', (
    tester,
  ) async {
    store.setLocal('sources', [
      for (final id in ['one', 'two', 'three'])
        {'id': id, 'kind': 'smb', 'label': 'NAS $id', 'host': '$id.local'},
    ]);
    await mount(
      tester,
      SourcesPage(model: model, onImport: () async {}, onPlay: (_) async {}),
    );
    Finder row(String id) => find.byWidgetPredicate(
      (widget) =>
          widget is ReorderableDelayedDragStartListener &&
          widget.key is ValueKey &&
          (widget.key! as ValueKey).value == id,
    );
    Future<void> openMenu(String id, {bool hold = false}) async {
      tester
          .widget<ListTile>(
            find.descendant(of: row(id), matching: find.byType(ListTile)),
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      if (hold) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 650));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      } else {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
      }
      await tester.pumpAndSettle();
    }

    Finder option(String value) => find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == value,
    );
    Future<void> choose(String value) async {
      for (var i = 0; i < 8 && !focusedWithin(option(value)); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        for (final item in tester.widgetList<PopupMenuItem<String>>(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem<String>),
        )) {
          if (!item.enabled) {
            expect(focusedWithin(option(item.value!)), isFalse);
          }
        }
      }
      expect(focusedWithin(option(value)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
    }

    final sourceFocus = tester
        .widget<ListTile>(
          find.descendant(of: row('two'), matching: find.byType(ListTile)),
        )
        .focusNode!;
    sourceFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    await tester.pumpAndSettle();
    expect(focusedWithin(find.byTooltip('手机控制')), isTrue);
    expect(find.text('上移'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(sourceFocus.hasFocus, isTrue);

    await openMenu('one', hold: true);
    expect(
      tester.widget<PopupMenuItem<String>>(option('move-up')).enabled,
      isFalse,
    );
    await choose('move-down');
    expect(model.sources.map((source) => source['id']), [
      'two',
      'one',
      'three',
    ]);
    expect(focusedWithin(row('one')), isTrue);
    expect(
      tester.getTopLeft(find.text('NAS two')).dy,
      lessThan(tester.getTopLeft(find.text('NAS one')).dy),
    );

    await openMenu('three');
    expect(
      tester.widget<PopupMenuItem<String>>(option('move-down')).enabled,
      isFalse,
    );
    await choose('move-up');
    expect(model.sources.map((source) => source['id']), [
      'two',
      'three',
      'one',
    ]);
    expect(focusedWithin(row('three')), isTrue);
    expect(
      tester.getTopLeft(find.text('NAS three')).dy,
      lessThan(tester.getTopLeft(find.text('NAS one')).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'TV source editor starts focused and changes protocol with remote',
    (tester) async {
      await mount(tester, const SourceEditorPage());
      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
      expect(focusedWithin(find.byType(SourceEditorPage)), isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      final selector = find.byWidgetPredicate(
        (widget) => widget is GlassSelect<String> && widget.label == '来源类型',
      );
      final text = find.descendant(
        of: selector,
        matching: find.text('SMB / Samba'),
      );
      Focus.of(tester.element(text)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      final option = find.widgetWithText(ListTile, 'WebDAV');
      for (var i = 0; i < 5 && !focusedWithin(option); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(focusedWithin(option), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(tester.widget<GlassSelect<String>>(selector).value, 'webdav');
      expect(find.text('WebDAV 目录'), findsOneWidget);
      expect(find.text('HTTPS 加密'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV settings switches, selectors and sliders use only remote keys',
    (tester) async {
      await mount(tester, SettingsPage(model: model));
      final chip = find.widgetWithText(ChoiceChip, '字幕');
      final chipIcon = find.descendant(of: chip, matching: find.byType(Icon));
      Focus.of(tester.element(chipIcon)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);

      final toggle = find.widgetWithText(SwitchListTile, '默认显示字幕');
      final toggleTitle = find.descendant(
        of: toggle,
        matching: find.text('默认显示字幕'),
      );
      Focus.of(tester.element(toggleTitle)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(model.preferences.subtitlesEnabled, isFalse);

      final language = find.byWidgetPredicate(
        (widget) => widget is GlassSelect<String> && widget.label == '优先语言',
      );
      final languageText = find.descendant(
        of: language,
        matching: find.text('简体中文（默认）'),
      );
      Focus.of(tester.element(languageText)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      final japanese = find.widgetWithText(ListTile, '日语');
      for (var i = 0; i < 8 && !focusedWithin(japanese); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(focusedWithin(japanese), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(model.preferences.subtitleLanguage, 'ja');

      final slider = find.byType(Slider).first;
      final detector = tester.widget<FocusableActionDetector>(
        find.descendant(
          of: slider,
          matching: find.byType(FocusableActionDetector),
        ),
      );
      detector.focusNode!.requestFocus();
      await tester.pump();
      final before = model.preferences.subtitleScale;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(model.preferences.subtitleScale, greaterThan(before));
      final adjusted = model.preferences.subtitleScale;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(detector.focusNode!.hasPrimaryFocus, isFalse);
      expect(model.preferences.subtitleScale, adjusted);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
