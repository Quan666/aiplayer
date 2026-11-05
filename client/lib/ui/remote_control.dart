import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../playback/media_controls.dart';
import '../remote/remote_control_service.dart';

export '../remote/remote_control_service.dart'
    show RemoteCommand, RemoteCommandResult;

/// A photo viewer or other page may handle app-specific previous/next/zoom
/// commands using its own session. Null means fall through to normal controls.
class RemoteControlTarget extends InheritedWidget {
  final FutureOr<RemoteCommandResult?> Function(RemoteCommand) onCommand;
  const RemoteControlTarget({
    super.key,
    required this.onCommand,
    required super.child,
  });
  @override
  bool updateShouldNotify(RemoteControlTarget oldWidget) =>
      onCommand != oldWidget.onCommand;
}

class RemoteControlScope extends StatefulWidget {
  final Widget child;
  final bool television;
  const RemoteControlScope({
    super.key,
    required this.child,
    this.television = false,
  });
  static RemoteControlScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<RemoteControlScopeState>();
  @override
  State<RemoteControlScope> createState() => RemoteControlScopeState();
}

class RemoteControlScopeState extends State<RemoteControlScope>
    with WidgetsBindingObserver {
  late final service = RemoteControlService(onCommand: _command);
  TextEditingController? _editing;
  EditableTextState? _editor;
  int _editSession = 0;
  bool _dialogOpen = false;
  EditableTextState? _televisionEditor, _navigationOrigin;
  bool _hideNextKeyboard = false;

  /// Traversal selects an input without entering editing. The selection must
  /// be valid before focus: EditableText otherwise fixes it and opens the IME
  /// even after its keyboard token was consumed.
  void prepareTelevisionTraversal(FocusNode node) {
    if (!widget.television || node.hasFocus) return;
    final editor = node.context?.findAncestorStateOfType<EditableTextState>();
    if (editor == null) return;
    final controller = editor.widget.controller;
    if (!controller.selection.isValid) {
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    }
    _hideNextKeyboard = true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_focusChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_televisionKey);
    PlayerMediaControls.remoteStatus.addListener(_publish);
    service.addListener(_focusChanged);
  }

  bool get _backgrounded => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => true,
    _ => false,
  };

  bool _permittedEditor(EditableTextState editor) {
    final field = editor.widget;
    if (field.readOnly) return false;
    return !(field.autofillHints?.any(
          (hint) => const {
            AutofillHints.creditCardNumber,
            AutofillHints.creditCardSecurityCode,
            AutofillHints.oneTimeCode,
          }.contains(hint),
        ) ??
        false);
  }

  bool _obscuredEditor(EditableTextState editor) =>
      editor.widget.obscureText ||
      editor.widget.keyboardType == TextInputType.visiblePassword ||
      (editor.widget.autofillHints?.any(
            (hint) =>
                hint == AutofillHints.password ||
                hint == AutofillHints.newPassword,
          ) ??
          false);

  EditableTextState? get _focusedEditor => FocusManager
      .instance
      .primaryFocus
      ?.context
      ?.findAncestorStateOfType<EditableTextState>();

  EditableTextState? get _televisionNavigationEditor {
    final current = _focusedEditor;
    if (current != null) return current;
    final previous = _navigationOrigin;
    // Android can close the text connection and unfocus EditableText when its
    // IME is dismissed. Preserve only a navigation origin, never reopen it.
    if (previous == null ||
        !previous.mounted ||
        ModalRoute.isCurrentOf(previous.context) == false ||
        !identical(
          FocusManager.instance.primaryFocus,
          previous.widget.focusNode.enclosingScope,
        )) {
      return null;
    }
    return previous;
  }

  void _hideKeyboard() {
    _televisionEditor = null;
    _focusedEditor?.hideToolbar();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  bool _closeTelevisionEditor() {
    if (!widget.television || _televisionEditor == null) return false;
    _hideKeyboard();
    return true;
  }

  bool _moveFromEditor(EditableTextState editor, TraversalDirection direction) {
    _navigationOrigin = editor;
    _hideKeyboard();
    _hideNextKeyboard = true;
    final node = editor.widget.focusNode;
    final restoring = !node.hasFocus;
    // The policy reads its scope's focused child. Both requests are synchronous
    // and coalesce before focus notifications, so the old editor never opens.
    if (restoring) node.requestFocus();
    final moved = node.focusInDirection(direction);
    node.nearestScope?.focusedChild?.consumeKeyboardToken();
    if (!moved && !restoring) _hideNextKeyboard = false;
    return moved;
  }

  KeyEventResult _televisionKey(KeyEvent event) {
    if (!widget.television || _backgrounded) return KeyEventResult.ignored;
    final editor = _televisionNavigationEditor;
    if (editor == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    final select =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    final back =
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack;
    if (direction != null) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _moveFromEditor(editor, direction);
      }
      // EditableText's default arrows edit the caret and trap a TV remote.
      // The platform IME owns editing keys while it is visible; keys reaching
      // Flutter belong to form traversal, including at a form's edge.
      return KeyEventResult.handled;
    }
    if (select && !editor.widget.readOnly) {
      if (event is KeyDownEvent) {
        _televisionEditor = editor;
        editor.requestKeyboard();
      }
      return KeyEventResult.handled;
    }
    if (back && event is KeyDownEvent && _closeTelevisionEditor()) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Future<bool> didPopRoute() async => _closeTelevisionEditor();

  @override
  void didChangeMetrics() {
    final editor = _televisionEditor;
    if (editor != null &&
        editor.mounted &&
        View.of(editor.context).viewInsets.bottom == 0) {
      _televisionEditor = null;
    }
  }

  void _focusChanged() {
    if (widget.television) {
      final current = _focusedEditor;
      if (current != null) {
        _navigationOrigin = current;
      } else if (FocusManager.instance.primaryFocus is! FocusScopeNode) {
        _navigationOrigin = null;
      }
      if (!identical(current, _televisionEditor)) _televisionEditor = null;
      if (_hideNextKeyboard) {
        _hideNextKeyboard = false;
        _hideKeyboard();
      }
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    final editor = service.value.running && !_backgrounded
        ? focus?.findAncestorStateOfType<EditableTextState>()
        : null;
    final allowed = editor != null && _permittedEditor(editor) ? editor : null;
    final controller = allowed?.widget.controller;
    if (!identical(_editor, allowed) || !identical(_editing, controller)) {
      _editing?.removeListener(_textChanged);
      _editor = allowed;
      _editing = controller;
      _editSession++;
      _editing?.addListener(_textChanged);
    }
    _publish();
  }

  void _textChanged() {
    // A local edit invalidates a phone's previously observed editing session.
    _editSession++;
    _publish();
  }

  void _publish() {
    if (!mounted || !service.value.running) return;
    final media = PlayerMediaControls.remoteStatus.value;
    service.publish(
      RemoteControlStatus(
        active: media.active,
        playing: media.playing,
        positionMs: media.positionMs,
        durationMs: media.durationMs,
        editing: _editing != null,
        obscured: _editor != null && _obscuredEditor(_editor!),
        editSession: _editSession,
      ),
    );
  }

  Future<RemoteCommandResult> _command(RemoteCommand command) async {
    if (!mounted || _backgrounded || !command.isCurrent) {
      return RemoteCommandResult.unavailable;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (command.action == 'text' || command.action == 'submit') {
      _focusChanged();
      final editor = _editor, controller = _editing;
      if (editor == null ||
          !editor.mounted ||
          controller == null ||
          command.editSession != _editSession ||
          !_permittedEditor(editor) ||
          !controller.value.composing.isCollapsed) {
        return const RemoteCommandResult(false, '输入框已改变，请重新选择后发送');
      }
      if (command.action == 'text') {
        final text = command.text!;
        editor.userUpdateTextEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
          SelectionChangedCause.keyboard,
        );
      } else {
        editor.performAction(
          editor.widget.textInputAction ?? TextInputAction.done,
        );
      }
      return const RemoteCommandResult(true);
    }
    final target = context
        ?.getInheritedWidgetOfExactType<RemoteControlTarget>();
    if (target != null) {
      final result = await target.onCommand(command);
      if (!command.isCurrent || !mounted || _backgrounded) {
        return RemoteCommandResult.unavailable;
      }
      if (result != null) return result;
    }
    if (context != null && !context.mounted ||
        !identical(FocusManager.instance.primaryFocus, focus)) {
      return RemoteCommandResult.unavailable;
    }
    final direction = switch (command.action) {
      'up' => TraversalDirection.up,
      'down' => TraversalDirection.down,
      'left' => TraversalDirection.left,
      'right' => TraversalDirection.right,
      _ => null,
    };
    if (direction != null) {
      final editor = widget.television ? _televisionNavigationEditor : null;
      final moved = editor != null
          ? _moveFromEditor(editor, direction)
          : focus?.focusInDirection(direction) ?? false;
      return RemoteCommandResult(moved, moved ? '' : '已到边缘');
    }
    if (command.action == 'select') {
      final editor = widget.television ? _televisionNavigationEditor : null;
      if (editor != null && !editor.widget.readOnly) {
        _televisionEditor = editor;
        editor.requestKeyboard();
        return const RemoteCommandResult(true);
      }
      if (context == null) return RemoteCommandResult.unavailable;
      final intent = const ActivateIntent();
      final action = Actions.maybeFind<ActivateIntent>(context);
      if (action == null || !action.isEnabled(intent)) {
        final editor = context.findAncestorStateOfType<EditableTextState>();
        if (editor != null && _permittedEditor(editor)) {
          editor.requestKeyboard();
          return const RemoteCommandResult(true);
        }
        return RemoteCommandResult.unavailable;
      }
      Actions.invoke(context, intent);
      return const RemoteCommandResult(true);
    }
    if (command.action == 'back') {
      if (_closeTelevisionEditor()) return const RemoteCommandResult(true);
      final navigator = context == null ? null : Navigator.maybeOf(context);
      final popped = await navigator?.maybePop() ?? false;
      return RemoteCommandResult(popped, popped ? '' : '已在首页');
    }
    final applied = await PlayerMediaControls.dispatchRemote(
      command.action,
      positionMs: command.positionMs,
      isCurrent: () => command.isCurrent,
    );
    return applied
        ? const RemoteCommandResult(true)
        : RemoteCommandResult.unavailable;
  }

  Future<void> show(BuildContext context) async {
    if (_dialogOpen || _backgrounded) return;
    _dialogOpen = true;
    try {
      if (!service.value.running) await service.start();
      if (!mounted || !context.mounted || _backgrounded) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _RemoteControlDialog(service: service),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _televisionEditor = null;
      _hideNextKeyboard = false;
      unawaited(service.stop());
      _focusChanged();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_focusChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_televisionKey);
    PlayerMediaControls.remoteStatus.removeListener(_publish);
    _editing?.removeListener(_textChanged);
    service.removeListener(_focusChanged);
    service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> showRemoteControlDialog(BuildContext context) async {
  final scope = RemoteControlScope.maybeOf(context);
  if (scope != null) await scope.show(context);
}

class _RemoteControlDialog extends StatefulWidget {
  final RemoteControlService service;
  const _RemoteControlDialog({required this.service});
  @override
  State<_RemoteControlDialog> createState() => _RemoteControlDialogState();
}

class _RemoteControlDialogState extends State<_RemoteControlDialog> {
  late final _awaitPair = !widget.service.value.connected;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_connection);
  }

  void _connection() {
    if (mounted &&
        _awaitPair &&
        widget.service.value.connected &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_connection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<RemoteControlState>(
        valueListenable: widget.service,
        builder: (context, state, _) => AlertDialog(
          title: const Text('手机控制'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.qr != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Semantics(
                          label: '手机控制配对二维码',
                          image: true,
                          child: CustomPaint(painter: _QrPainter(state)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('手机连接同一局域网，扫码打开控制页'),
                    const SizedBox(height: 6),
                    const Text('二维码 2 分钟内有效'),
                  ] else if (state.phase == 'starting')
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    )
                  else
                    Text(
                      state.connected
                          ? '手机已连接'
                          : state.phase == 'reconnecting'
                          ? '等待手机重新连接'
                          : state.message.isEmpty
                          ? '手机控制已关闭'
                          : state.message,
                    ),
                  if (state.pairingUrl != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.pairingUrl!.origin,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (state.addresses.length > 1)
                    DropdownButton<String>(
                      isExpanded: true,
                      value: state.pairingUrl?.host,
                      items: [
                        for (final address in state.addresses)
                          DropdownMenuItem(
                            value: address,
                            child: Text(address),
                          ),
                      ],
                      onChanged: (address) {
                        if (address != null) {
                          unawaited(widget.service.start(address: address));
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (state.running)
              TextButton(
                onPressed: () async {
                  await widget.service.stop();
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('关闭控制'),
              ),
            if (!state.running)
              TextButton(
                onPressed: () => widget.service.start(),
                child: const Text('重新配对'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
}

class _QrPainter extends CustomPainter {
  final RemoteControlState state;
  const _QrPainter(this.state);
  @override
  void paint(Canvas canvas, Size size) {
    final count = state.qrSize, bits = state.qr;
    if (bits == null || count <= 0) return;
    final module = (math.min(size.width, size.height) / (count + 8))
        .floorToDouble();
    final width = module * (count + 8);
    final x = (size.width - width) / 2, y = (size.height - width) / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (bits[row * count + column] == 0) continue;
        final start = column;
        while (column + 1 < count && bits[row * count + column + 1] == 1) {
          column++;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            x + (start + 4) * module,
            y + (row + 4) * module,
            (column - start + 1) * module,
            module,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      !identical(state.qr, oldDelegate.state.qr);
}
