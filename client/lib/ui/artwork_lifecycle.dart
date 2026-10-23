import 'package:flutter/widgets.dart';

/// One synchronous lifecycle signal for artwork, including when Android stops
/// delivering frames before a TickerMode rebuild can reach retained widgets.
class ArtworkLifecycle extends ValueNotifier<bool> with WidgetsBindingObserver {
  ArtworkLifecycle._()
    : super(
        WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      ) {
    WidgetsBinding.instance.addObserver(this);
  }

  static final instance = ArtworkLifecycle._();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    value = state == AppLifecycleState.resumed;
  }
}
