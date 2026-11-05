import 'package:flutter/material.dart';

import 'glass.dart';

/// Direct lateral navigation: the image page slides in and pulls away on back.
/// Keep its live child instead of mixing route snapshots with decoded images.
class AlbumViewerRoute<T> extends PageRouteBuilder<T> {
  AlbumViewerRoute({required WidgetBuilder builder})
    : super(
        allowSnapshotting: false,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 230),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, _, child) {
          if (!MotionScope.enabledOf(context)) return child;
          return SlideTransition(
            position: animation.drive(
              Tween(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeInOutCubic)),
            ),
            child: child,
          );
        },
      );
}
