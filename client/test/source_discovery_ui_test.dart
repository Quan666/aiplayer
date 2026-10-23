import 'dart:async';
import 'dart:io';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/discovery.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'LAN scanning happens only after the add-page action and closes with picker',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-explicit-discovery-',
      );
      final store = AppStore(':memory:');
      final model = AppModel(store, directory);
      var scans = 0, cancelled = false;
      final discovery = LanDiscovery(
        interfaces: () async => [const LocalNetwork('192.168.1.1', 30)],
        probe: (_, _, _) async => false,
        browse: (cancel, duration, found) async {
          scans++;
          found(
            const DiscoveredSource(
              kind: 'smb',
              name: '客厅 NAS',
              host: '192.168.1.50',
              port: 1445,
            ),
          );
          await cancel.whenCancelled;
          cancelled = true;
        },
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                discovery: discovery,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(scans, 0);
        expect(find.text('局域网发现'), findsNothing);
        await tester.tap(find.byTooltip('添加来源'));
        await tester.pumpAndSettle();
        expect(find.byType(SourceEditorPage), findsOneWidget);
        expect(scans, 0);
        await tester.tap(find.text('扫描局域网'));
        await tester.pumpAndSettle();
        expect(scans, 1);
        expect(find.text('客厅 NAS'), findsOneWidget);
        await tester.tap(find.text('客厅 NAS'));
        await tester.pumpAndSettle();
        expect(cancelled, true);
        expect(_controller(tester, '服务器地址').text, '192.168.1.50');
        expect(_controller(tester, '端口').text, '1445');
        expect(find.text('所有共享'), findsOneWidget);
        expect(model.sources, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'closing discovery cancels a pending interface lookup and ignores late broadcasts',
    (tester) async {
      final lookup = Completer<List<LocalNetwork>>();
      var cancelled = false, probes = 0;
      late void Function(DiscoveredSource) lateFound;
      final discovery = LanDiscovery(
        interfaces: () => lookup.future,
        probe: (_, _, _) async {
          probes++;
          return false;
        },
        browse: (cancel, duration, found) async {
          lateFound = found;
          await cancel.whenCancelled;
          cancelled = true;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: SourceEditorPage(discovery: discovery),
        ),
      );
      await tester.tap(find.text('扫描局域网'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      expect(cancelled, true);
      lateFound(
        const DiscoveredSource(
          kind: 'smb',
          name: '迟到结果',
          host: '192.168.1.5',
          port: 445,
        ),
      );
      await tester.pumpAndSettle();
      expect(probes, 0);
      expect(find.text('迟到结果'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final custom in ['', '我的影片']) {
    testWidgets('HTTP optional name is preserved "$custom"', (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await Navigator.push<Map<String, dynamic>>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SourceEditorPage(
                        initial: {
                          'kind': 'http',
                          'label': custom,
                          'url':
                              'https://cdn.example/private-path/第01集.mkv?token=private',
                        },
                      ),
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved?['label'], custom.isEmpty ? '第01集.mkv' : custom);
      expect('${saved?['label']}', isNot(contains('private')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

TextEditingController _controller(WidgetTester tester, String label) => tester
    .widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    )
    .controller!;
