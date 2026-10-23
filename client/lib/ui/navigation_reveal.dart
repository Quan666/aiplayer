import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Embedded pages use this when changing directory or settings section. Their
/// navigation does not push a Navigator route, but should still restore the bar.
class NavigationRevealNotification extends Notification {
  const NavigationRevealNotification();

  static void reveal(BuildContext context) {
    const NavigationRevealNotification().dispatch(context);
  }
}

/// Observes a downward pull without competing with scrolling, taps, or sliders.
/// Raw pointer movement is deliberate: an empty/clamped list does not emit a
/// ScrollUpdateNotification, so relying on scroll notifications can trap the
/// navigation offscreen.
class NavigationRevealRegion extends StatefulWidget {
  final VoidCallback onReveal;
  final Widget child;

  const NavigationRevealRegion({
    super.key,
    required this.onReveal,
    required this.child,
  });

  @override
  State<NavigationRevealRegion> createState() => _NavigationRevealRegionState();
}

class _NavigationRevealRegionState extends State<NavigationRevealRegion> {
  final _pointers = <int>{};
  int? _pointer;
  Offset _origin = Offset.zero;
  Axis? _axis;
  double _downwardTravel = 0;
  bool? _wasCurrent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent == false && current) {
      // Route dependencies change during build. Reveal on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.isCurrentOf(context) ?? true)) {
          widget.onReveal();
        }
      });
    }
    _wasCurrent = current;
  }

  void _down(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 ||
        (event.kind != PointerDeviceKind.touch &&
            event.kind != PointerDeviceKind.stylus)) {
      _pointer = null;
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _axis = null;
    _downwardTravel = 0;
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    final travel = event.position - _origin;
    if (_axis == null && travel.distance >= 12) {
      if (travel.dx.abs() > travel.dy.abs() * 1.2) {
        _axis = Axis.horizontal;
      } else if (travel.dy.abs() > travel.dx.abs() * 1.2) {
        _axis = Axis.vertical;
      }
    }
    if (_axis == Axis.horizontal) return;
    _downwardTravel = math.max(0, _downwardTravel + event.delta.dy);
    if (_axis == Axis.vertical && _downwardTravel >= 18) {
      _downwardTravel = 0;
      widget.onReveal();
    }
  }

  void _end(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointer == event.pointer) _pointer = null;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<NavigationRevealNotification>(
        onNotification: (_) {
          widget.onReveal();
          return false;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _end,
          onPointerCancel: _end,
          child: widget.child,
        ),
      );
}
