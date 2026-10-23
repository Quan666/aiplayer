import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'artwork_lifecycle.dart';

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
  final _activity = _ArtworkActivity();
  final _scrollables = <ScrollableState, ScrollPosition>{};
  ValueListenable<bool>? _parentActivity;
  bool _locallyActive = false, _reportedActivity = false;
  bool _callbackScheduled = false;
  bool _enabled = true, _detachmentCheckScheduled = false;
  bool _tickerEnabled = true;
  Timer? _idle;
  Timer? _viewportUpdate;

  @override
  void initState() {
    super.initState();
    _enabled = ArtworkLifecycle.instance.value;
    ArtworkLifecycle.instance.addListener(_updateEnabled);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _updateEnabled();
    final parent = ArtworkScrollScope.maybeOf(context);
    if (_parentActivity == parent) return;
    _parentActivity?.removeListener(_updateActivity);
    _parentActivity = parent;
    _parentActivity?.addListener(_updateActivity);
    _updateActivity();
  }

  void _updateEnabled() {
    final enabled = _tickerEnabled && ArtworkLifecycle.instance.value;
    if (_enabled != enabled) {
      _enabled = enabled;
      if (!enabled) {
        _idle?.cancel();
        _idle = null;
        _viewportUpdate?.cancel();
        _viewportUpdate = null;
        // A muted ballistic activity cannot finish itself. End it before
        // releasing our listeners so returning to the page starts idle.
        for (final position in _scrollables.values.toList(growable: false)) {
          if (position is ScrollPositionWithSingleContext) position.goIdle();
        }
        _clearScrollables();
        _locallyActive = false;
      }
      _updateActivity();
    }
  }

  void _setActive(bool active) {
    _locallyActive = active;
    _updateActivity();
  }

  void _updateActivity() {
    final active =
        _enabled && (_locallyActive || _parentActivity?.value == true);
    if (_activity.value == active) {
      if (active) _activity.viewportChanged();
      return;
    }
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
    if (!_enabled) return;
    _idle = Timer(const Duration(milliseconds: 120), () {
      _idle = null;
      _pruneScrollables();
      if (_scrollables.isEmpty) {
        _viewportUpdate?.cancel();
        _viewportUpdate = null;
        _setActive(false);
      }
    });
  }

  void _removeScrollable(ScrollableState scrollable) {
    _scrollables
        .remove(scrollable)
        ?.isScrollingNotifier
        .removeListener(_scrollingChanged);
  }

  void _clearScrollables() {
    for (final scrollable in _scrollables.keys.toList(growable: false)) {
      _removeScrollable(scrollable);
    }
  }

  void _pruneScrollables() {
    for (final entry in _scrollables.entries.toList(growable: false)) {
      if (!entry.key.mounted || !entry.value.isScrollingNotifier.value) {
        _removeScrollable(entry.key);
      }
    }
  }

  void _scrollingChanged() {
    _pruneScrollables();
    if (_scrollables.isEmpty) _waitForIdle();
  }

  void _watchForDetachment() {
    if (_detachmentCheckScheduled || !_enabled || _scrollables.isEmpty) return;
    _detachmentCheckScheduled = true;
    // ScrollPosition.dispose does not notify listeners. Check for removed
    // scrollables only on frames the app already needs; never request a frame
    // or keep waking a timer while a finger is held still.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detachmentCheckScheduled = false;
      if (!mounted || !_enabled || _scrollables.isEmpty) return;
      _pruneScrollables();
      if (_scrollables.isEmpty) {
        _waitForIdle();
      } else {
        _watchForDetachment();
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (!_enabled) return false;
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
      _removeScrollable(scrollable);
    } else {
      if (!_scrollables.containsKey(scrollable)) {
        final position = scrollable.position;
        _scrollables[scrollable] = position;
        position.isScrollingNotifier.addListener(_scrollingChanged);
      }
      _watchForDetachment();
    }
    // A mouse-wheel event starts and ends scrolling in the same call. Keep
    // successive events in one busy period instead of decoding between them.
    if (!_locallyActive) _setActive(true);
    // One bounded viewport wake-up for the whole region, including children
    // already laid out in the sliver cache. Never poll each card on every tick.
    _viewportUpdate ??= Timer(const Duration(milliseconds: 64), () {
      _viewportUpdate = null;
      if (mounted && _activity.value) _activity.viewportChanged();
    });
    _waitForIdle();
    return false;
  }

  @override
  void dispose() {
    ArtworkLifecycle.instance.removeListener(_updateEnabled);
    _idle?.cancel();
    _viewportUpdate?.cancel();
    _clearScrollables();
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

class _ArtworkActivity extends ValueNotifier<bool> {
  _ArtworkActivity() : super(false);

  void viewportChanged() => notifyListeners();
}

class _ArtworkScrollActivity extends InheritedWidget {
  final ValueListenable<bool> activity;

  const _ArtworkScrollActivity({required this.activity, required super.child});

  @override
  bool updateShouldNotify(_ArtworkScrollActivity oldWidget) =>
      activity != oldWidget.activity;
}
