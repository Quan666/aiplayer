import 'dart:async';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer/subtitles/settings.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _ModelTransport implements SubtitleAiTransport {
  final Future<List<String>> Function(SubtitleAiConfig, CancelToken) list;
  int calls = 0;
  _ModelTransport(this.list);
  @override
  Future<List<String>> models(SubtitleAiConfig config, CancelToken cancel) {
    calls++;
    return list(config, cancel);
  }

  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) => throw UnimplementedError();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  late Directory root;
  late AppStore store;
  late AppModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'aiSubtitleToken': 'private-key',
    });
    root = Directory.systemTemp.createTempSync('aiplayer-ai-settings-');
    store = AppStore(':memory:');
    model = AppModel(store, root);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, SubtitleAiTransport transport) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AiSubtitleSettings(model: model, transport: transport),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'expanded translation prompt stays bounded and saves at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final transport = _ModelTransport((_, _) async => []);
        await mount(tester, transport);
        await tester.ensureVisible(find.text('字幕翻译要求'));
        await tester.tap(find.text('字幕翻译要求'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final field = find.byWidgetPredicate(
          (widget) => widget is TextField && widget.maxLength == 10000,
        );
        await tester.ensureVisible(field);
        final fieldSize = tester.getSize(field);
        expect(fieldSize.width, greaterThan(200));
        expect(fieldSize.width, lessThan(size.width));
        expect(fieldSize.height, lessThan(300));
        final draft = List.filled(30, '保留角色称呼，翻译自然简洁。').join('\n');
        await tester.enterText(field, draft);
        await tester.pumpAndSettle();
        expect(tester.getSize(field).height, lessThan(300));
        // Closing and reopening must keep the draft without a runaway layout.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.ensureVisible(find.text('字幕翻译要求'));
        await tester.tap(find.text('字幕翻译要求'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('字幕翻译要求'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, draft);
        await tester.ensureVisible(find.text('保存'));
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(model.settings['aiSubtitlePrompt'], draft);
        expect(find.widgetWithText(SnackBar, '翻译设置已保存'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AiSubtitleSettings),
            matching: find.text('翻译设置已保存'),
          ),
          findsNothing,
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('翻译设置已保存'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('model loading, search and selection work at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      final transport = _ModelTransport((config, _) async {
        expect(config.token, 'private-key');
        return ['zeta', 'beta-translator', 'alpha', 'beta-translator'];
      });
      try {
        await mount(tester, transport);
        expect(transport.calls, 0);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '选择模型'),
              )
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(find.text('加载模型'));
        await tester.tap(find.text('加载模型'));
        await tester.pumpAndSettle();
        expect(transport.calls, 1);
        expect(find.text('已加载 3 个模型，点击“选择模型”后保存'), findsOneWidget);
        await tester.ensureVisible(find.text('选择模型'));
        await tester.tap(find.text('选择模型'));
        await tester.pumpAndSettle();
        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '搜索模型',
        );
        await tester.enterText(search, 'BETA');
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'alpha'), findsNothing);
        await tester.tap(find.widgetWithText(ListTile, 'beta-translator'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(_field('模型名称')).controller!.text,
          'beta-translator',
        );
        await tester.ensureVisible(find.text('保存'));
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(model.settings['aiSubtitleModel'], 'beta-translator');
        expect(model.settings.toString(), isNot(contains('private-key')));
        expect(await model.secrets.read(key: 'aiSubtitleToken'), 'private-key');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      }
    });
  }

  testWidgets('changing provider cancels pending model results', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    CancelToken? request;
    final transport = _ModelTransport((_, cancel) {
      request = cancel;
      return pending.future;
    });
    await mount(tester, transport);
    await tester.tap(find.text('加载模型'));
    await tester.pump();
    await tester.enterText(_field('API 地址'), 'https://another.example/v1');
    await tester.pump();
    expect(request!.cancelled, true);
    pending.complete(['stale-model']);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '选择模型'))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('已加载'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
