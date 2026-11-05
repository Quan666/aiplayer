import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'television_input.dart';

/// A remote can focus a reading viewport even when its rows contain no actions.
/// Controls inside it retain normal traversal; oversized focused rows scroll
/// before navigation advances past the unread part. No timers or animations are
/// needed: one key (including hardware repeats) performs one bounded movement.
class TelevisionScrollRegion extends StatefulWidget {
  final ScrollController? controller, horizontalController;
  final Widget Function(BuildContext, ScrollController) builder;
  final bool autofocus;
  final Color? focusColor;
  final BorderRadius borderRadius;

  const TelevisionScrollRegion({
    super.key,
    this.controller,
    this.horizontalController,
    required this.builder,
    this.autofocus = false,
    this.focusColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  State<TelevisionScrollRegion> createState() => _TelevisionScrollRegionState();
}

class _TelevisionScrollRegionState extends State<TelevisionScrollRegion>
    with WidgetsBindingObserver {
  final _ownedScroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'television-scroll-region');
  FocusNode? _departedControl;
  TraversalDirection? _departedDirection;
  bool _focused = false;

  ScrollController get _scroll => widget.controller ?? _ownedScroll;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _focusChanged() {
    final focused = _focus.hasPrimaryFocus;
    if (_focused != focused) setState(() => _focused = focused);
    if (!_focus.hasFocus) {
      _departedControl = null;
      _departedDirection = null;
    }
  }

  bool get _backgrounded => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => true,
    _ => false,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_backgrounded) return;
    for (final controller in [_scroll, widget.horizontalController]) {
      if (controller == null || !controller.hasClients) continue;
      for (final position in controller.positions) {
        if (position is ScrollPositionWithSingleContext) position.goIdle();
      }
    }
  }

  FocusNode? _visibleControl(TraversalDirection direction, FocusNode? from) {
    final bounds = _focus.rect;
    final descending = direction == TraversalDirection.down;
    final origin = from?.context == null ? null : from!.rect.center.dy;
    FocusNode? next;
    var distance = double.infinity;
    // Only mounted viewport/cache children have focus nodes. Never enumerate
    // the document, media parameters, or the backing log collection here.
    for (final node in _focus.descendants) {
      if (node == from ||
          node is FocusScopeNode ||
          !node.canRequestFocus ||
          node.skipTraversal ||
          node.context == null) {
        continue;
      }
      final rect = node.rect;
      if (!rect.overlaps(bounds) || rect.isEmpty) continue;
      final delta = origin == null
          ? descending
                ? rect.center.dy - bounds.top
                : bounds.bottom - rect.center.dy
          : (rect.center.dy - origin) * (descending ? 1 : -1);
      if (delta > 0 && delta < distance) {
        next = node;
        distance = delta;
      }
    }
    return next;
  }

  bool _move(ScrollController controller, bool forward) {
    if (!controller.hasClients || controller.positions.length != 1) {
      return false;
    }
    final position = controller.position;
    final step = math.min(96.0, position.viewportDimension * .25);
    final next = (position.pixels + (forward ? step : -step)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((next - position.pixels).abs() < .5) return false;
    controller.jumpTo(next);
    return true;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    if (_backgrounded || !(ModalRoute.isCurrentOf(context) ?? true)) {
      return KeyEventResult.handled;
    }
    final vertical =
        direction == TraversalDirection.up ||
        direction == TraversalDirection.down;
    final controller = vertical ? _scroll : widget.horizontalController;
    if (controller == null) return KeyEventResult.ignored;
    final forward =
        direction == TraversalDirection.down ||
        direction == TraversalDirection.right;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return KeyEventResult.ignored;
    if (!primary.hasPrimaryFocus || !_focus.hasFocus) {
      return KeyEventResult.ignored;
    }
    if (primary != _focus) {
      final field = primary.context
          ?.findAncestorWidgetOfExactType<EditableText>();
      if (field != null) return KeyEventResult.ignored;
      final clipped =
          vertical &&
          (forward
              ? primary.rect.bottom > _focus.rect.bottom + 1
              : primary.rect.top < _focus.rect.top - 1);
      if (clipped && _move(controller, forward)) return KeyEventResult.handled;
      if (!vertical || _visibleControl(direction, primary) != null) {
        return KeyEventResult.ignored;
      }
      if (!_move(controller, forward)) return KeyEventResult.ignored;
      _departedControl = primary;
      _departedDirection = direction;
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (vertical) {
      final next = _visibleControl(
        direction,
        _departedDirection == direction ? _departedControl : null,
      );
      if (next != null) {
        final oversized = next.rect.height > _focus.rect.height;
        FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
          next,
          // Enter a tall log at its leading edge; revealing its far edge would
          // skip precisely the text this reading region makes reachable.
          alignmentPolicy: forward != oversized
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return KeyEventResult.handled;
      }
    }
    return _move(controller, forward)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    _ownedScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _scroll);
    if (!TelevisionMode.of(context)) return child;
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _key,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          border: _focused
              ? Border.all(
                  color:
                      widget.focusColor ??
                      Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : null,
        ),
        child: child,
      ),
    );
  }
}
