import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../playback/desktop_window.dart';
import 'glass.dart';

/// Window chrome shares the page's background. Only interactive content is
/// inset; artwork and video can continue underneath the transparent drag area.
class DesktopWindowFrame extends StatelessWidget {
  static const titlebarHeight = 36.0;
  final Widget child;

  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    if (kIsWeb ||
        (platform != TargetPlatform.macOS &&
            platform != TargetPlatform.windows &&
            platform != TargetPlatform.linux)) {
      return child;
    }
    final macOS = platform == TargetPlatform.macOS;
    // The frame sits outside the Navigator; provide an overlay for its window
    // button tooltips without adding a route or replacing the page's Navigator.
    return Overlay.wrap(
      child: ValueListenableBuilder<DesktopWindowState>(
        valueListenable: DesktopWindow.state,
        child: child,
        builder: (context, state, child) {
          final media = MediaQuery.of(context);
          final inset = state.fullscreen ? 0.0 : titlebarHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              MediaQuery(
                data: media.copyWith(
                  padding: media.padding.copyWith(
                    top: math.max(media.padding.top, inset),
                  ),
                  viewPadding: media.viewPadding.copyWith(
                    top: math.max(media.viewPadding.top, inset),
                  ),
                ),
                child: child!,
              ),
              if (!state.fullscreen)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: titlebarHeight,
                  child: Row(
                    // Window controls stay on the platform's physical side,
                    // independently of the application's text direction.
                    textDirection: TextDirection.ltr,
                    children: [
                      if (macOS) const SizedBox(width: 80),
                      Expanded(
                        child: GestureDetector(
                          key: const ValueKey('desktop-window-drag'),
                          behavior: HitTestBehavior.opaque,
                          excludeFromSemantics: true,
                          onPanStart: (_) =>
                              unawaited(DesktopWindow.startDrag()),
                          onDoubleTap: () =>
                              unawaited(DesktopWindow.toggleMaximize()),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      if (!macOS) ...[
                        _WindowButton(
                          label: '最小化',
                          icon: Icons.remove,
                          onPressed: DesktopWindow.minimize,
                        ),
                        _WindowButton(
                          label: state.maximized ? '还原窗口' : '最大化',
                          icon: state.maximized
                              ? Icons.filter_none_outlined
                              : Icons.crop_square,
                          onPressed: DesktopWindow.toggleMaximize,
                        ),
                        _WindowButton(
                          label: '关闭窗口',
                          icon: Icons.close,
                          onPressed: DesktopWindow.requestClose,
                          close: true,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool close;

  const _WindowButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.close = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = GlassPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        width: 46,
        height: DesktopWindowFrame.titlebarHeight,
        child: Tooltip(
          message: label,
          child: TextButton(
            onPressed: () => unawaited(onPressed()),
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              minimumSize: const WidgetStatePropertyAll(Size.zero),
              shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              animationDuration: Duration.zero,
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (close &&
                    (states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused) ||
                        states.contains(WidgetState.pressed))) {
                  return Colors.white;
                }
                return colors.text;
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)) {
                  return close ? colors.danger : colors.selected;
                }
                return Colors.transparent;
              }),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              backgroundBuilder: (context, states, child) =>
                  child ?? const SizedBox.shrink(),
            ),
            child: Icon(
              icon,
              size: 16,
              semanticLabel: label,
              // Keep the small glyph readable over a playing video as well as
              // the library canvas, without painting a separate titlebar band.
              shadows: [Shadow(color: colors.canvas, blurRadius: 3)],
            ),
          ),
        ),
      ),
    );
  }
}
