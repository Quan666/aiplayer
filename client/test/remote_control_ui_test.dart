import 'dart:async';

import 'package:aiplayer/remote/remote_control_service.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:aiplayer/ui/secret_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  testWidgets('remote passwords are versioned, formatted and never published', (
    tester,
  ) async {
    final plain = TextEditingController(), secret = TextEditingController();
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => RemoteControlScope(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              TextField(
                key: const ValueKey('plain'),
                controller: plain,
                inputFormatters: [LengthLimitingTextInputFormatter(4)],
                onChanged: (_) => changes++,
              ),
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
    scope.service.value = const RemoteControlState(phase: 'connected');
    await tester.tap(find.byKey(const ValueKey('plain')));
    await tester.pump();
    final editSession = scope.service.status.editSession;
    expect(scope.service.status.editing, isTrue);
    expect(scope.service.status.obscured, isFalse);
    final result = await scope.service.onCommand(
      RemoteCommand(1, 'text', '海边照片更多', editSession, null, () => true),
    );
    expect(result.ok, isTrue);
    expect(plain.text, '海边照片');
    expect(changes, 1);
    final stale = await scope.service.onCommand(
      RemoteCommand(2, 'text', '旧请求', editSession, null, () => true),
    );
    expect(stale.ok, isFalse);
    expect(plain.text, '海边照片');
    await tester.tap(find.byKey(const ValueKey('secret')));
    await tester.pump();
    expect(scope.service.status.editing, isTrue);
    expect(scope.service.status.obscured, isTrue);
    final applied = await scope.service.onCommand(
      RemoteCommand(
        3,
        'text',
        'phone-password',
        scope.service.status.editSession,
        null,
        () => true,
      ),
    );
    expect(applied.ok, isTrue);
    expect(secret.text, 'phone-password');
    expect(
      scope.service.status.toMessage().toString(),
      isNot(contains('phone-password')),
    );
    expect(scope.service.status.toMessage().keys, isNot(contains('text')));
    secret.selection = const TextSelection.collapsed(offset: 5);
    await tester.tap(find.byTooltip('显示'));
    await tester.pump();
    expect(secret.selection, const TextSelection.collapsed(offset: 5));
    final secretField = find.descendant(
      of: find.byKey(const ValueKey('secret')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(secretField).obscureText, isFalse);
    await tester.tap(secretField);
    await tester.pump();
    expect(scope.service.status.obscured, isTrue);
    final visible = await scope.service.onCommand(
      RemoteCommand(
        4,
        'text',
        'replacement',
        scope.service.status.editSession,
        null,
        () => true,
      ),
    );
    expect(visible.ok, isTrue);
    expect(secret.text, 'replacement');
    await tester.pumpWidget(const SizedBox());
    plain.dispose();
    secret.dispose();
  });

  testWidgets('TV arrows leave text fields, including after IME disconnect', (
    tester,
  ) async {
    final first = FocusNode(), second = FocusNode(), done = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            RemoteControlScope(television: true, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: first),
              TextField(focusNode: second, obscureText: true),
              TextButton(
                focusNode: done,
                onPressed: () {},
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(second.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(second.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    tester.testTextInput.closeConnection();
    await tester.pump();
    expect(second.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(done.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
    done.dispose();
  });

  testWidgets(
    'TV remote phone directions navigate a form without changing text',
    (tester) async {
      final first = FocusNode(), second = FocusNode();
      final controller = TextEditingController(text: 'keep');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RemoteControlScope(television: true, child: child!),
          home: Scaffold(
            body: Column(
              children: [
                TextField(focusNode: first, controller: controller),
                TextField(focusNode: second, obscureText: true),
              ],
            ),
          ),
        ),
      );
      first.requestFocus();
      await tester.pump();
      final scope = tester.state<RemoteControlScopeState>(
        find.byType(RemoteControlScope),
      );
      scope.service.value = const RemoteControlState(phase: 'connected');
      final moved = await scope.service.onCommand(
        RemoteCommand(1, 'down', null, null, null, () => true),
      );
      await tester.pump();
      expect(moved.ok, isTrue);
      expect(second.hasFocus, isTrue);
      expect(controller.text, 'keep');
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
      controller.dispose();
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
