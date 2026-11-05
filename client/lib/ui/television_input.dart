import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'remote_control.dart';
import 'theme/app_theme.dart';

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

/// Owns TV key sequences, focus traversal and layered Back handling while
/// retaining non-TV input behavior. Detection runs once, with no polling.
class TelevisionInputScope extends StatefulWidget {
  static const menuDoublePressInterval = Duration(milliseconds: 650);
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

class _TelevisionInputScopeState extends State<TelevisionInputScope>
    with WidgetsBindingObserver {
  bool _television = false;
  late final _shortcuts = _RemoteShortcutManager();
  int _generation = 0, _focusVisibilityRevision = 0;
  Timer? _holdTimer, _menuTimer, _menuHoldTimer;
  LogicalKeyboardKey? _heldKey;
  FocusNode? _heldFocus;
  _TelevisionMenuPress? _menuPress;
  bool _menuDown = false, _menuDouble = false, _menuLongPressed = false;
  final _navigationHosts = <_TelevisionNavigationHostState>{};
  _TelevisionActionTarget? _heldTarget;
  bool _longPressed = false;
  bool _foreground = true;
  FocusHighlightStrategy? _previousHighlight;
  late final _traversal = _TelevisionTraversalPolicy(
    requestFocusCallback: _requestFocus,
    onDownEdge: _enterNavigationAtEdge,
  );

  void _requestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    final targetContext = node.context;
    if (_television && targetContext != null) {
      RemoteControlScope.maybeOf(targetContext)
          ?.prepareTelevisionTraversal(node);
    }
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
      node,
      alignmentPolicy: alignmentPolicy,
      alignment: alignment,
      duration: duration,
      curve: curve,
    );
    if (_television) {
      final revision = ++_focusVisibilityRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (revision != _focusVisibilityRevision ||
            !_current(node) ||
            !node.hasPrimaryFocus) {
          return;
        }
        final bounds = _activeNavigationHost?.widget.navigationBounds?.call();
        if (bounds == null || !node.rect.overlaps(bounds)) return;
        final delta = node.rect.bottom - bounds.top + 8;
        node.context?.visitAncestorElements((element) {
          if (element is! StatefulElement ||
              element.state is! ScrollableState) {
            return true;
          }
          final position = (element.state as ScrollableState).position;
          if (axisDirectionToAxis(position.axisDirection) != Axis.vertical) {
            return true;
          }
          position.jumpTo(
            (position.pixels + delta).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
          return false;
        });
      });
    }
    // Traversal selects a field; OK opens its keyboard. Consume synchronously
    // before EditableText receives the focus notification and opens the IME.
    if (_television &&
        node.context?.findAncestorStateOfType<EditableTextState>() != null) {
      node.consumeKeyboardToken();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    FocusManager.instance.addEarlyKeyEventHandler(_key);
    FocusManager.instance.addLateKeyEventHandler(_backKey);
    HardwareKeyboard.instance.addHandler(_hardwareMenu);
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
    if (widget.overrideTelevision == null &&
        defaultTargetPlatform == TargetPlatform.android) {
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
    if (value && _previousHighlight == null) {
      _previousHighlight = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
    } else if (!value) {
      _restoreHighlight();
      _cancelKeys();
    }
    if (_television != value) setState(() => _television = value);
  }

  void _restoreHighlight() {
    final previous = _previousHighlight;
    if (previous == null) return;
    _previousHighlight = null;
    FocusManager.instance.highlightStrategy = previous;
  }

  static bool _confirm(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  bool _current(FocusNode? node) {
    final context = node?.context;
    return mounted &&
        _foreground &&
        context != null &&
        context.mounted &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  void _cancelKeys() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _cancelMenu();
    _heldKey = null;
    _heldFocus = null;
    _heldTarget = null;
    _longPressed = false;
  }

  void _cancelMenu() {
    _menuTimer?.cancel();
    _menuHoldTimer?.cancel();
    _menuTimer = _menuHoldTimer = null;
    _menuPress = null;
    _menuDown = _menuDouble = _menuLongPressed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _cancelKeys();
  }

  KeyEventResult _key(KeyEvent event) {
    if (!_television) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (!_foreground) {
      return _confirm(key) ||
              key == LogicalKeyboardKey.contextMenu ||
              key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.browserBack ||
              key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if ((key == LogicalKeyboardKey.goBack ||
            key == LogicalKeyboardKey.browserBack ||
            key == LogicalKeyboardKey.escape) &&
        event is! KeyDownEvent) {
      // TV Back is owned for the entire physical press. A layer may change
      // focus on key-down; allowing key-up to reach Android then pops twice.
      return KeyEventResult.handled;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final target = context
        ?.getInheritedWidgetOfExactType<_TelevisionActionTarget>();

    // Keep ownership through release, even after the hold opens a new route.
    // Otherwise the release/repeat can activate the first item in that menu.
    if (key == _heldKey) {
      if (event is KeyUpEvent) {
        final activate =
            !_longPressed && focus == _heldFocus && _current(_heldFocus);
        final heldTarget = _heldTarget;
        _holdTimer?.cancel();
        _heldKey = null;
        _heldTarget = null;
        _heldFocus = null;
        if (activate) heldTarget?.onActivate();
      }
      return KeyEventResult.handled;
    }
    if (_confirm(key) && target != null && target.focusNode == focus) {
      if (event is KeyDownEvent) {
        _heldKey = key;
        _heldFocus = focus;
        _heldTarget = target;
        _longPressed = false;
        _holdTimer?.cancel();
        if (target.onMenu != null) {
          _holdTimer = Timer(const Duration(milliseconds: 550), () {
            if (_current(_heldFocus) &&
                FocusManager.instance.primaryFocus == _heldFocus) {
              _longPressed = true;
              target.onMenu?.call();
            }
          });
        }
      }
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.contextMenu) return KeyEventResult.ignored;
    // Physical repeats never count as a double click. Only two distinct presses
    // may enter navigation; a single press belongs to the focused item/page.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    // HardwareKeyboard owns menu recognition even when Flutter has no primary
    // focus. Keep the later focus-tree dispatch from acting on it a second time.
    return KeyEventResult.handled;
  }

  _TelevisionNavigationHostState? get _activeNavigationHost =>
      _navigationHosts.where((host) => host.available).lastOrNull;

  _TelevisionMenuPress? _captureMenu() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final host = _activeNavigationHost;
    if (context == null || !(ModalRoute.isCurrentOf(context) ?? true)) {
      return host?.menuPress;
    }
    final region = context
        .getInheritedWidgetOfExactType<TelevisionMenuRegion>();
    final target = context
        .getInheritedWidgetOfExactType<_TelevisionActionTarget>();
    final longPress = target?.focusNode == focus && target?.onMenu != null
        ? target!.onMenu
        : region?.onLongMenu;
    final route = ModalRoute.of(context);
    // A route-scoped host survives focus loss and replacement of a list row.
    // An open popup makes the shell host unavailable and cannot leak into it.
    return _TelevisionMenuPress(
      owner: host ?? route ?? region ?? focus!,
      isCurrent: host == null
          ? () => context.mounted && (route?.isCurrent ?? true)
          : () => host.available,
      onNavigation: region?.onNavigation ?? host?.widget.onNavigation,
      onMenu: region?.onMenu,
      onLongMenu: longPress == null
          ? null
          : () {
              if (_current(focus) &&
                  FocusManager.instance.primaryFocus == focus) {
                longPress();
              }
            },
    );
  }

  bool _hardwareMenu(KeyEvent event) {
    if (!_television || event.logicalKey != LogicalKeyboardKey.contextMenu) {
      return false;
    }
    if (!_foreground) return true;
    if (event.synthesized) {
      // Reconciliation is not another user press. A synthesized release must
      // still clear ownership or the next real menu press would be swallowed.
      if (event is KeyUpEvent) _cancelMenu();
      return true;
    }
    if (event is KeyRepeatEvent) return true;
    if (event is KeyDownEvent) {
      if (_menuDown) return true;
      _menuDown = true;
      _menuLongPressed = false;
      final current = _captureMenu();
      final previous = _menuPress;
      _menuDouble =
          _menuTimer?.isActive == true &&
          current != null &&
          previous != null &&
          identical(current.owner, previous.owner) &&
          previous.isCurrent();
      _menuTimer?.cancel();
      _menuTimer = null;
      if (_menuDouble) {
        _menuPress = null;
        (current!.onNavigation ?? previous!.onMenu)?.call();
      } else {
        _menuPress = current;
        _menuHoldTimer = Timer(const Duration(milliseconds: 550), () {
          _menuHoldTimer = null;
          _menuLongPressed = true;
          if (mounted && _foreground && current?.isCurrent() == true) {
            current?.onLongMenu?.call();
          }
        });
      }
    } else if (event is KeyUpEvent && _menuDown) {
      _menuDown = false;
      _menuHoldTimer?.cancel();
      _menuHoldTimer = null;
      if (_menuLongPressed) {
        _menuLongPressed = false;
        _menuPress = null;
        return true;
      }
      if (_menuDouble) {
        _menuDouble = false;
        return true;
      }
      final press = _menuPress;
      if (press == null) return true;
      // Measure between release and the next press. Real remotes have longer
      // press durations than synthetic key tests; never count hold repeats.
      _menuTimer = Timer(TelevisionInputScope.menuDoublePressInterval, () {
        _menuTimer = null;
        _menuPress = null;
        if (mounted && _foreground && press.isCurrent()) press.onMenu?.call();
      });
    }
    return true;
  }

  bool _enterNavigationAtEdge(FocusNode node) {
    if (!_television || !_foreground) return false;
    final host = _activeNavigationHost;
    if (host == null || host.widget.navigationActive) return false;
    // A nested modal has its own route and must retain all directional input.
    final context = node.context;
    final route = context == null ? null : ModalRoute.of(context);
    if (route != null && route != host.route) return false;
    host.widget.onNavigation();
    return true;
  }

  KeyEventResult _backKey(KeyEvent event) {
    if (!_television || !_foreground) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.goBack &&
        key != LogicalKeyboardKey.browserBack &&
        key != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyEventResult.ignored;
    final route = ModalRoute.of(context);
    if (route == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      unawaited(_popRoute(context));
    }
    return KeyEventResult.handled;
  }

  Future<void> _popRoute(BuildContext context) async {
    if (await Navigator.of(context).maybePop()) return;
    if (mounted && _foreground && context.mounted) {
      await SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    FocusManager.instance.removeLateKeyEventHandler(_backKey);
    HardwareKeyboard.instance.removeHandler(_hardwareMenu);
    _cancelKeys();
    _restoreHighlight();
    _shortcuts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TelevisionMode(
    enabled: _television,
    child: RemoteControlScope(
      television: _television,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          navigationMode: _television
              ? NavigationMode.directional
              : MediaQuery.of(context).navigationMode,
        ),
        child: Actions(
          actions: {
            if (_television)
              DirectionalFocusIntent: _TelevisionDirectionalFocusAction(),
          },
          child: FocusTraversalGroup(
            policy: _traversal,
            child: Shortcuts.manager(manager: _shortcuts, child: widget.child),
          ),
        ),
      ),
    ),
  );
}

class _TelevisionMenuPress {
  final Object owner;
  final bool Function() isCurrent;
  final VoidCallback? onMenu, onLongMenu, onNavigation;
  const _TelevisionMenuPress({
    required this.owner,
    required this.isCurrent,
    this.onMenu,
    this.onLongMenu,
    this.onNavigation,
  });
}

class _TelevisionTraversalPolicy extends ReadingOrderTraversalPolicy {
  final bool Function(FocusNode) onDownEdge;
  _TelevisionTraversalPolicy({
    required super.requestFocusCallback,
    required this.onDownEdge,
  });

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (super.inDirection(currentNode, direction)) return true;
    return direction == TraversalDirection.down && onDownEdge(currentNode);
  }
}

/// Registers only the currently visible shell route as a navigation fallback.
/// Menu access must survive a lost/replaced focus node without crossing modals.
class TelevisionNavigationHost extends StatefulWidget {
  final VoidCallback onNavigation;
  final bool navigationActive;
  final Rect? Function()? navigationBounds;
  final Widget child;
  const TelevisionNavigationHost({
    super.key,
    required this.onNavigation,
    required this.navigationActive,
    this.navigationBounds,
    required this.child,
  });

  @override
  State<TelevisionNavigationHost> createState() =>
      _TelevisionNavigationHostState();
}

class _TelevisionNavigationHostState extends State<TelevisionNavigationHost> {
  _TelevisionInputScopeState? _owner;
  ModalRoute<dynamic>? route;
  bool _current = false;
  bool get available => mounted && (route?.isCurrent ?? _current);
  _TelevisionMenuPress get menuPress => _TelevisionMenuPress(
    owner: this,
    isCurrent: () => available,
    onNavigation: widget.onNavigation,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route = ModalRoute.of(context);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_current && !current && _owner?._menuPress?.owner == this) {
      _owner?._cancelMenu();
    }
    _current = current;
    final owner = context.findAncestorStateOfType<_TelevisionInputScopeState>();
    if (_owner != owner) {
      _owner?._navigationHosts.remove(this);
      _owner = owner;
      owner?._navigationHosts.add(this);
    }
  }

  @override
  void dispose() {
    _owner?._navigationHosts.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TelevisionMenuRegion(
    onNavigation: widget.onNavigation,
    navigationActive: widget.navigationActive,
    child: widget.child,
  );
}

/// A page owns its single-menu action. Shell navigation is entered explicitly
/// with two menu presses or at the lower directional edge of shell content.
class TelevisionMenuRegion extends InheritedWidget {
  final VoidCallback? onMenu, onLongMenu, onNavigation;
  final bool navigationActive;
  const TelevisionMenuRegion({
    super.key,
    this.onMenu,
    this.onLongMenu,
    this.onNavigation,
    this.navigationActive = false,
    required super.child,
  });

  static bool navigationOwnsBack(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<TelevisionMenuRegion>()
          ?.navigationActive ??
      false;

  @override
  bool updateShouldNotify(TelevisionMenuRegion oldWidget) =>
      onMenu != oldWidget.onMenu ||
      onLongMenu != oldWidget.onLongMenu ||
      onNavigation != oldWidget.onNavigation ||
      navigationActive != oldWidget.navigationActive;
}

/// Keeps a small toolbar mounted when its parent scroll view is lazy.
class TelevisionHeader extends StatefulWidget {
  final FocusNode focusNode;
  final Widget child;
  const TelevisionHeader({
    super.key,
    required this.focusNode,
    required this.child,
  });

  @override
  State<TelevisionHeader> createState() => _TelevisionHeaderState();
}

class _TelevisionHeaderState extends State<TelevisionHeader>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => TelevisionMode.read(context);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Focus(
      focusNode: widget.focusNode,
      canRequestFocus: false,
      skipTraversal: true,
      child: widget.child,
    );
  }
}

/// A page-level shortcut to its toolbar, with an exact return to the list.
/// The header may be fixed, overlaid, or part of a lazy scroll view.
class TelevisionHeaderNavigation extends StatefulWidget {
  final FocusNode headerFocusNode;
  final VoidCallback? onHeaderRequested;
  final Widget child;
  const TelevisionHeaderNavigation({
    super.key,
    required this.headerFocusNode,
    this.onHeaderRequested,
    required this.child,
  });

  static void focusHeader(BuildContext context) => context
      .findAncestorStateOfType<_TelevisionHeaderNavigationState>()
      ?._focusHeader();

  @override
  State<TelevisionHeaderNavigation> createState() =>
      _TelevisionHeaderNavigationState();
}

class _TelevisionHeaderNavigationState extends State<TelevisionHeaderNavigation>
    with WidgetsBindingObserver {
  FocusNode? _previousFocus;
  _TelevisionActionState? _retainedAction;
  final _positions = <ScrollPosition, double>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _available {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.detached &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  void _focusHeader() {
    if (!_available) return;
    if (!widget.headerFocusNode.hasFocus) {
      _retainedAction?.retainForHeader(false);
      _previousFocus = FocusManager.instance.primaryFocus;
      _retainedAction = _previousFocus?.context
          ?.findAncestorStateOfType<_TelevisionActionState>();
      // Retain only the return row: scrolling the toolbar into view must not
      // dispose its lazy-list focus node before Down can return to it.
      _retainedAction?.retainForHeader(true);
      _positions.clear();
      _previousFocus?.context?.visitAncestorElements((element) {
        if (element is StatefulElement && element.state is ScrollableState) {
          final position = (element.state as ScrollableState).position;
          _positions[position] = position.pixels;
        }
        return true;
      });
    }
    widget.onHeaderRequested?.call();
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_available || generation != _generation) return;
      final target = widget.headerFocusNode.traversalDescendants
          .where((node) => node.context != null && node is! FocusScopeNode)
          .firstOrNull;
      if (target != null) {
        FocusTraversalGroup.of(target.context!).requestFocusCallback(target);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!TelevisionMode.read(context) ||
        !widget.headerFocusNode.hasFocus ||
        event.logicalKey != LogicalKeyboardKey.arrowDown ||
        _previousFocus?.context == null ||
        !_previousFocus!.canRequestFocus) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && _available) {
      ++_generation;
      for (final entry in _positions.entries) {
        if (entry.key.hasPixels && entry.key.hasContentDimensions) {
          entry.key.jumpTo(
            entry.value.clamp(
              entry.key.minScrollExtent,
              entry.key.maxScrollExtent,
            ),
          );
        }
      }
      final target = _previousFocus!;
      // The original viewport was restored above. Another ensureVisible would
      // use pre-layout geometry and incorrectly shift it a second time.
      target.requestFocus();
      _retainedAction?.retainForHeader(false);
      _retainedAction = null;
      _positions.clear();
    }
    return KeyEventResult.handled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) ++_generation;
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    // Descendants are already being unmounted; no keep-alive notification is
    // needed while the whole page leaves the tree.
    _positions.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parent = context
        .dependOnInheritedWidgetOfExactType<TelevisionMenuRegion>();
    return TelevisionMenuRegion(
      onMenu: _focusHeader,
      onLongMenu: parent?.onLongMenu,
      onNavigation: parent?.onNavigation,
      navigationActive: parent?.navigationActive ?? false,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        child: widget.child,
      ),
    );
  }
}

class _TelevisionDirectionalFocusAction extends DirectionalFocusAction {
  @override
  void invoke(DirectionalFocusIntent intent) {
    final scope = FocusManager.instance.primaryFocus?.nearestScope;
    super.invoke(intent);
    final target = scope?.focusedChild;
    if (target?.context != null) {
      RemoteControlScope.maybeOf(target!.context!)
          ?.prepareTelevisionTraversal(target);
    }
    if (target?.context?.findAncestorStateOfType<EditableTextState>() != null) {
      target!.consumeKeyboardToken();
    }
  }
}

/// Supplies an exact activation target: nested trailing buttons keep their own
/// actions. Pointer interaction continues to use the original widget callbacks.
class TelevisionAction extends StatefulWidget {
  final VoidCallback onActivate;
  final VoidCallback? onMenu;
  final FocusNode? focusNode;
  final BorderRadius? borderRadius;
  final Widget Function(BuildContext context, FocusNode focusNode) builder;
  const TelevisionAction({
    super.key,
    required this.onActivate,
    this.onMenu,
    this.focusNode,
    this.borderRadius,
    required this.builder,
  });

  @override
  State<TelevisionAction> createState() => _TelevisionActionState();
}

class _TelevisionActionState extends State<TelevisionAction>
    with AutomaticKeepAliveClientMixin {
  FocusNode? _ownedFocus;
  bool _headerReturnTarget = false;

  @override
  bool get wantKeepAlive => _headerReturnTarget;

  void retainForHeader(bool retain) {
    if (!mounted || retain == _headerReturnTarget) return;
    _headerReturnTarget = retain;
    updateKeepAlive();
  }

  @override
  void dispose() {
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final focus =
        widget.focusNode ??
        (_ownedFocus ??= FocusNode(debugLabel: 'television-action'));
    return _TelevisionActionTarget(
      focusNode: focus,
      onActivate: widget.onActivate,
      onMenu: widget.onMenu,
      child: widget.borderRadius == null
          ? widget.builder(context, focus)
          : TelevisionFocusIndicator(
              focusNode: focus,
              borderRadius: widget.borderRadius!,
              child: widget.builder(context, focus),
            ),
    );
  }
}

/// Paints inside the existing bounds, without changing layout or animating
/// every card. Only the control whose focus changes rebuilds its decoration.
class TelevisionFocusIndicator extends StatelessWidget {
  final FocusNode focusNode;
  final BorderRadius borderRadius;
  final Widget child;
  const TelevisionFocusIndicator({
    super.key,
    required this.focusNode,
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!TelevisionMode.of(context)) return child;
    final accent = GlassPalette.of(context).accent;
    return ListenableBuilder(
      listenable: focusNode,
      child: child,
      builder: (context, child) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: focusNode.hasPrimaryFocus
              ? Border.all(color: accent, width: 2)
              : null,
        ),
        child: child,
      ),
    );
  }
}

class _TelevisionActionTarget extends InheritedWidget {
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback? onMenu;
  const _TelevisionActionTarget({
    required this.focusNode,
    required this.onActivate,
    required this.onMenu,
    required super.child,
  });

  @override
  bool updateShouldNotify(_TelevisionActionTarget oldWidget) => false;
}

/// Contains directional traversal and gives TV dialogs/sheets a real initial
/// control. No polling, extra layout, or rebuilding of individual menu rows.
class TelevisionFocusScope extends StatefulWidget {
  final Widget child;
  final bool autofocus;
  final FocusScopeNode? node;
  const TelevisionFocusScope({
    super.key,
    required this.child,
    this.autofocus = true,
    this.node,
  });

  @override
  State<TelevisionFocusScope> createState() => _TelevisionFocusScopeState();
}

class _TelevisionFocusScopeState extends State<TelevisionFocusScope> {
  final _ownedScope = FocusScopeNode(debugLabel: 'television-region');
  FocusScopeNode get _scope => widget.node ?? _ownedScope;

  void _initialFocus() {
    if (!widget.autofocus || !TelevisionMode.read(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Child autofocus requests are queued until the focus manager flushes.
      // Respect an explicit selected option before choosing a default control.
      FocusManager.instance.applyFocusChangesIfNeeded();
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          !widget.autofocus ||
          lifecycle == AppLifecycleState.hidden ||
          lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.detached ||
          !(ModalRoute.isCurrentOf(context) ?? true) ||
          _scope.focusedChild != null ||
          !_scope.canRequestFocus) {
        return;
      }
      _scope.nextFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initialFocus();
  }

  @override
  void didUpdateWidget(TelevisionFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.autofocus && widget.autofocus) _initialFocus();
  }

  @override
  void dispose() {
    _ownedScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TelevisionMode.of(context)
      ? FocusScope(
          node: _scope,
          autofocus: widget.autofocus,
          child: widget.child,
        )
      : widget.child;
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
