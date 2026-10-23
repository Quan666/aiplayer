import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Shares one idle delay across artwork and data refreshes in a scroll region.
class ArtworkScrollScope extends StatefulWidget {
  final Widget child;
  final ValueChanged<bool>? onActivityChanged;

  const ArtworkScrollScope({
    super.key,
    required this.child,
    this.onActivityChanged,
  });

  /// The carrier only changes when the scope changes, not on scroll events.
  static ValueListenable<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ArtworkScrollActivity>()
      ?.activity;

  @override
  State<ArtworkScrollScope> createState() => _ArtworkScrollScopeState();
}

class _ArtworkScrollScopeState extends State<ArtworkScrollScope> {
  final _activity = ValueNotifier(false);
  final _scrollables = <ScrollableState>{};
  ValueListenable<bool>? _parentActivity;
  bool _locallyActive = false, _reportedActivity = false;
  bool _callbackScheduled = false;
  Timer? _idle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ArtworkScrollScope.maybeOf(context);
    if (_parentActivity == parent) return;
    _parentActivity?.removeListener(_updateActivity);
    _parentActivity = parent;
    _parentActivity?.addListener(_updateActivity);
    _updateActivity();
  }

  void _setActive(bool active) {
    _locallyActive = active;
    _updateActivity();
  }

  void _updateActivity() {
    final active = _locallyActive || _parentActivity?.value == true;
    if (_activity.value == active) return;
    _activity.value = active;
    if (_callbackScheduled) return;
    // A newly mounted inner scope can inherit an already busy parent during
    // build. Its callback may refresh an ancestor, so report after that frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _callbackScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _callbackScheduled = false;
        if (mounted) _reportActivity();
      });
    } else {
      _reportActivity();
    }
  }

  void _reportActivity() {
    if (_reportedActivity == _activity.value) return;
    _reportedActivity = _activity.value;
    widget.onActivityChanged?.call(_reportedActivity);
  }

  void _waitForIdle() {
    _idle?.cancel();
    _idle = Timer(const Duration(milliseconds: 120), () {
      _idle = null;
      _scrollables.removeWhere(
        (scrollable) =>
            !scrollable.mounted ||
            !scrollable.position.isScrollingNotifier.value,
      );
      if (_scrollables.isNotEmpty) {
        _waitForIdle();
      } else {
        _setActive(false);
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is! ScrollStartNotification &&
        notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final origin = notification.context;
    if (origin == null) return false;
    final scrollable = origin.findAncestorStateOfType<ScrollableState>();
    if (scrollable == null) return false;
    if (notification is ScrollEndNotification) {
      _scrollables.remove(scrollable);
    } else {
      _scrollables.add(scrollable);
    }
    // A mouse-wheel event starts and ends scrolling in the same call. Keep
    // successive events in one busy period instead of decoding between them.
    _setActive(true);
    _waitForIdle();
    return false;
  }

  @override
  void dispose() {
    _idle?.cancel();
    _parentActivity?.removeListener(_updateActivity);
    _activity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ArtworkScrollActivity(
    activity: _activity,
    child: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.child,
    ),
  );
}

class _ArtworkScrollActivity extends InheritedWidget {
  final ValueListenable<bool> activity;

  const _ArtworkScrollActivity({required this.activity, required super.child});

  @override
  bool updateShouldNotify(_ArtworkScrollActivity oldWidget) =>
      activity != oldWidget.activity;
}
