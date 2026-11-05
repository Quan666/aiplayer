import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'remote_control.dart';

/// Native device classification, independent of screen width: tablets and
/// desktop windows must not accidentally acquire television key semantics.
class TelevisionMode extends InheritedWidget {
  final bool enabled;
  const TelevisionMode({
    super.key,
    required this.enabled,
    required super.child,
  });

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TelevisionMode>()?.enabled ??
      false;

  static bool read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TelevisionMode>()?.enabled ?? false;

  @override
  bool updateShouldNotify(TelevisionMode oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Adds remote activation without replacing Flutter's directional traversal,
/// text editing or system Back handling. Detection runs once, with no polling.
class TelevisionInputScope extends StatefulWidget {
  final Widget child;
  final bool? overrideTelevision;
  const TelevisionInputScope({
    super.key,
    required this.child,
    this.overrideTelevision,
  });

  @override
  State<TelevisionInputScope> createState() => _TelevisionInputScopeState();
}

class _TelevisionInputScopeState extends State<TelevisionInputScope> {
  bool _television = false;
  late final _shortcuts = _RemoteShortcutManager();
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void didUpdateWidget(TelevisionInputScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.overrideTelevision != oldWidget.overrideTelevision) _detect();
  }

  Future<void> _detect() async {
    final generation = ++_generation;
    var value = widget.overrideTelevision ?? false;
    if (widget.overrideTelevision == null && Platform.isAndroid) {
      try {
        final info = await const MethodChannel('app.aiplayer/device_info')
            .invokeMapMethod<String, dynamic>('getDeviceInfo');
        value = info?['isTelevision'] == true;
      } on MissingPluginException {
        value = false;
      } on PlatformException {
        value = false;
      }
    }
    if (!mounted || generation != _generation) return;
    _shortcuts.television = value;
    if (_television != value) setState(() => _television = value);
  }

  @override
  void dispose() {
    _generation++;
    _shortcuts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TelevisionMode(
    enabled: _television,
    child: RemoteControlScope(
      child: Shortcuts.manager(manager: _shortcuts, child: widget.child),
    ),
  );
}

class _RemoteShortcutManager extends ShortcutManager {
  bool television = false;
  _RemoteShortcutManager()
    : super(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
      );

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    // A held remote OK must not open several routes. Keep arrow repeats for
    // traversal, and ordinary desktop text/Enter behavior unchanged.
    if (event is KeyRepeatEvent &&
        (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA ||
            television &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter))) {
      return KeyEventResult.handled;
    }
    return super.handleKeypress(context, event);
  }
}
