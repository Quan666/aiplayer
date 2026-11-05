import 'dart:async';

import 'package:aiplayer/remote/remote_control_service.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:aiplayer/ui/secret_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a page handler cannot activate stale focus after an await', (
    tester,
  ) async {
    final release = Completer<RemoteCommandResult?>();
    final first = FocusNode(), second = FocusNode();
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => RemoteControlScope(child: child!),
        home: Scaffold(
          body: RemoteControlTarget(
            onCommand: (_) => release.future,
            child: Row(
              children: [
                ElevatedButton(
                  focusNode: first,
                  autofocus: true,
                  onPressed: () => activations++,
                  child: const Text('一'),
                ),
                ElevatedButton(
                  focusNode: second,
                  onPressed: () => activations++,
                  child: const Text('二'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final scope = tester.state<RemoteControlScopeState>(
      find.byType(RemoteControlScope),
    );
    scope.service.value = const RemoteControlState(phase: 'connected');
    final pending = scope.service.onCommand(
      RemoteCommand(1, 'select', null, null, null, () => true),
    );
    second.requestFocus();
    await tester.pump();
    release.complete(null);
    expect((await pending).ok, isFalse);
    expect(activations, 0);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });
  testWidgets(
    'text targets are versioned and secret fields cannot be remotely edited',
    (tester) async {
      final plain = TextEditingController(), secret = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => RemoteControlScope(child: child!),
          home: Scaffold(
            body: Column(
              children: [
                TextField(key: const ValueKey('plain'), controller: plain),
                SecretTextField(
                  key: const ValueKey('secret'),
                  controller: secret,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
              ],
            ),
          ),
        ),
      );
      final scope = tester.state<RemoteControlScopeState>(
        find.byType(RemoteControlScope),
      );
      // Transport parsing/authentication has dedicated real-socket tests. Here
      // drive the UI dispatcher with its active, already paired session.
      scope.service.value = const RemoteControlState(phase: 'connected');
      await tester.tap(find.byKey(const ValueKey('plain')));
      await tester.pump();
      final editSession = scope.service.status.editSession;
      expect(scope.service.status.editing, isTrue);
      final result = await scope.service.onCommand(
        RemoteCommand(1, 'text', '海边照片', editSession, null, () => true),
      );
      expect(result.ok, isTrue);
      expect(plain.text, '海边照片');
      final stale = await scope.service.onCommand(
        RemoteCommand(2, 'text', '旧请求', editSession, null, () => true),
      );
      expect(stale.ok, isFalse);
      expect(plain.text, '海边照片');
      await tester.tap(find.byKey(const ValueKey('secret')));
      await tester.pump();
      expect(scope.service.status.editing, isFalse);
      final blocked = await scope.service.onCommand(
        RemoteCommand(
          3,
          'text',
          '不能写入',
          scope.service.status.editSession,
          null,
          () => true,
        ),
      );
      expect(blocked.ok, isFalse);
      expect(secret.text, isEmpty);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('secret')),
          matching: find.byType(TextField),
        ),
        'local-secret',
      );
      secret.selection = const TextSelection.collapsed(offset: 5);
      await tester.tap(find.byTooltip('显示'));
      await tester.pump();
      final revealed = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('secret')),
          matching: find.byType(TextField),
        ),
      );
      expect(revealed.obscureText, isFalse);
      expect(secret.text, 'local-secret');
      expect(secret.selection, const TextSelection.collapsed(offset: 5));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('secret')),
          matching: find.byType(TextField),
        ),
      );
      await tester.pump();
      final revealedBlocked = await scope.service.onCommand(
        RemoteCommand(
          4,
          'text',
          'cannot replace a visible password',
          scope.service.status.editSession,
          null,
          () => true,
        ),
      );
      expect(revealedBlocked.ok, isFalse);
      expect(scope.service.status.editing, isFalse);
      expect(secret.text, 'local-secret');
      await tester.tap(find.byTooltip('隐藏'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('secret')),
                matching: find.byType(TextField),
              ),
            )
            .obscureText,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      plain.dispose();
      secret.dispose();
    },
  );

  testWidgets(
    'remote activation uses focused action and Back does not exit root',
    (tester) async {
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => RemoteControlScope(child: child!),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                autofocus: true,
                onPressed: () => activations++,
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final scope = tester.state<RemoteControlScopeState>(
        find.byType(RemoteControlScope),
      );
      scope.service.value = const RemoteControlState(phase: 'connected');
      final activated = await scope.service.onCommand(
        RemoteCommand(1, 'select', null, null, null, () => true),
      );
      expect(activated.ok, isTrue);
      expect(activations, 1);
      final back = await scope.service.onCommand(
        RemoteCommand(2, 'back', null, null, null, () => true),
      );
      expect(back.ok, isFalse);
      expect(find.text('打开'), findsOneWidget);
    },
  );

  testWidgets(
    'paused lifecycle disables service and queued UI actions without pump',
    (tester) async {
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => RemoteControlScope(child: child!),
          home: Scaffold(
            body: ElevatedButton(
              autofocus: true,
              onPressed: () => activations++,
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.pump();
      final scope = tester.state<RemoteControlScopeState>(
        find.byType(RemoteControlScope),
      );
      scope.service.value = const RemoteControlState(phase: 'connected');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Deliberately do not pump after pausing.
      expect(scope.service.value.running, isFalse);
      final result = await scope.service.onCommand(
        RemoteCommand(1, 'select', null, null, null, () => true),
      );
      expect(result.ok, isFalse);
      expect(activations, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(scope.service.value.running, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
