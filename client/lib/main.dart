import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data/app_model.dart';
import 'data/store.dart';
import 'ui/library_page.dart';
import 'ui/glass.dart';
import 'sources/apple_access.dart';
import 'core/logger.dart';
import 'playback/display.dart';
import 'playback/fullscreen_transition.dart';
import 'core/external_open.dart';
import 'ui/player_page.dart';
import 'playback/desktop_window.dart';
import 'playback/subtitle_fonts.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans SC',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'OpenCC',
    ], await rootBundle.loadString('assets/opencc/LICENSE'));
  });
  try {
    MediaKit.ensureInitialized();
    await AppleFileAccess.restore();
    final documents = await getApplicationSupportDirectory();
    await documents.create(recursive: true);
    await AppLog.instance.initialize(documents);
    AppLog.instance.info('应用', '映库 0.5.18 启动');
    final model = AppModel(
      await AppStore.open(p.join(documents.path, 'library.db')),
      documents,
      enableThumbnails: true,
      deferBackgroundWork: true,
    );
    runApp(AIPlayerApp(model: model, arguments: arguments));
    unawaited(
      preparePlaybackFonts(documents).catchError((Object error) {
        AppLog.instance.warning('字幕字体', safeFailure(error).message);
        return Directory(p.join(documents.path, 'subtitle-fonts'));
      }),
    );
  } catch (error) {
    AppLog.instance.error('启动', safeFailure(error).message);
    runApp(
      MaterialApp(
        theme: AppTheme.theme(),
        darkTheme: AppTheme.theme(brightness: Brightness.dark),
        home: const Scaffold(
          body: Center(child: Text('启动失败：请检查播放器原生库和应用数据目录权限。')),
        ),
      ),
    );
  }
}

class AIPlayerApp extends StatefulWidget {
  final AppModel model;
  final List<String> arguments;
  const AIPlayerApp({
    super.key,
    required this.model,
    this.arguments = const [],
  });
  @override
  State<AIPlayerApp> createState() => _AIPlayerAppState();
}

class _AIPlayerAppState extends State<AIPlayerApp> with WidgetsBindingObserver {
  AppModel get model => widget.model;
  bool? _highRefresh;
  final _appearance = ValueNotifier<({ThemeMode themeMode, bool animations})>((
    themeMode: ThemeMode.light,
    animations: true,
  ));
  late final _lightTheme = AppTheme.theme();
  late final _darkTheme = AppTheme.theme(brightness: Brightness.dark);
  late final _highContrastTheme = AppTheme.theme(highContrast: true);
  late final _highContrastDarkTheme = AppTheme.theme(
    brightness: Brightness.dark,
    highContrast: true,
  );
  bool _backgrounded = false;
  final _presentationVisible = ValueNotifier(true);
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _routeObserver = _OpenRouteObserver();
  ExternalVideoRequest? _pendingExternal;
  int _externalGeneration = 0;
  late final ExternalVideoInbox _inbox;
  bool _openingExternal = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _backgrounded = state != null && state != AppLifecycleState.resumed;
    _presentationVisible.value = !playbackIsBackgrounded(state);
    model.setForeground(!_backgrounded);
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_displayPreferences);
    _displayPreferences();
    _inbox = ExternalVideoInbox(_receiveExternal);
    DesktopWindow.watchClose(_closeApplication);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      unawaited(DesktopWindow.ready());
      unawaited(model.startBackgroundWork());
      unawaited(_inbox.start(widget.arguments));
    });
  }

  void _receiveExternal(Map<dynamic, dynamic> value) {
    if (!mounted || _closing) return;
    try {
      final request = ExternalVideoRequest.parse(value);
      final superseded = _pendingExternal;
      _pendingExternal = request;
      _externalGeneration++;
      if (superseded?.temporary ?? false) {
        unawaited(_inbox.release(superseded!.location));
      }
      _dismissExternalRoutes();
      unawaited(_drainExternal());
    } catch (error) {
      _showExternalError(error);
    }
  }

  Future<void> _closeApplication() async {
    if (_closing) return;
    setState(() => _closing = true);
    model.setForeground(false);
    _externalGeneration++;
    final pending = _pendingExternal;
    _pendingExternal = null;
    _inbox.dispose();
    if (pending?.temporary ?? false) {
      await _inbox.release(pending!.location);
    }
    _dismissExternalRoutes();
    // A minimized desktop window may have no vsync. Unmount playback before
    // acknowledging native close so progress and decoder cleanup can finish.
    WidgetsBinding.instance.scheduleWarmUpFrame();
    await WidgetsBinding.instance.endOfFrame;
    await PlayerPage.waitForDisposals();
    try {
      await model.flushPlaybackPreviews();
      await AppLog.instance.flush();
    } finally {
      await DesktopWindow.close();
    }
  }

  void _dismissExternalRoutes() {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    // Remove fullscreen and modal routes as well as the player. PopScope may
    // intentionally reject pop, so popUntil is not suitable for replacement.
    for (final route in _routeObserver.routes.reversed.toList()) {
      if (!route.isFirst && route.isActive) navigator.removeRoute(route);
    }
  }

  void _showExternalError(Object error) {
    final message = safeFailure(error).message;
    AppLog.instance.error('外部打开', message);
    _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _drainExternal() async {
    if (_openingExternal) return;
    _openingExternal = true;
    try {
      while (mounted && !_closing && _pendingExternal != null) {
        final request = _pendingExternal!;
        final generation = _externalGeneration;
        _pendingExternal = null;
        String? importedId;
        var playing = false;
        try {
          model.status = '正在打开外部视频…';
          model.changed();
          late final String id;
          try {
            id = request.remote
                ? await model.importExternalLink(request.location, request.name)
                : await model.importExternalFile(
                    request.location,
                    request.name,
                    temporary: request.temporary,
                  );
            importedId = id;
          } finally {
            if (request.temporary) await _inbox.release(request.location);
          }
          if (!mounted || _closing || generation != _externalGeneration) {
            continue;
          }
          final media = model.store.get('media', id);
          if (media == null) continue;
          _dismissExternalRoutes();
          // Allow the previous player and decoder to dispose before
          // mounting the replacement; never show a stale import result.
          await WidgetsBinding.instance.endOfFrame;
          await PlayerPage.waitForDisposals();
          if (!mounted || _closing || generation != _externalGeneration) {
            continue;
          }
          final navigator = _navigator.currentState;
          if (navigator == null) continue;
          unawaited(
            navigator.push<void>(
              PageRouteBuilder<void>(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, animation, secondaryAnimation) =>
                    PlayerPage(model: model, media: media),
              ),
            ),
          );
          playing = true;
        } catch (error) {
          if (mounted && generation == _externalGeneration) {
            _showExternalError(error);
          }
        } finally {
          if (!playing && importedId != null) {
            await model.disposeExternalMedia(importedId);
          }
          if (mounted && generation == _externalGeneration) {
            model.status = '';
            model.changed();
          }
        }
      }
    } finally {
      _openingExternal = false;
    }
  }

  @override
  void didUpdateWidget(AIPlayerApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_displayPreferences);
      oldWidget.model.setForeground(false);
      model.setForeground(!_backgrounded && !_closing);
      model.addListener(_displayPreferences);
      _displayPreferences();
    }
  }

  void _displayPreferences() {
    final preferences = model.preferences;
    // Cover and metadata updates must not recreate MaterialApp and its themes.
    _appearance.value = (
      themeMode: model.themeMode,
      animations: preferences.animations,
    );
    final enabled = preferences.highRefreshRate && !_backgrounded && !_closing;
    if (_highRefresh == enabled) return;
    _highRefresh = enabled;
    PlayerDisplay.setHighRefreshRate(enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    // An unfocused window and the mobile notification shade can leave video
    // visible and playing. Keep its animation clock running even while
    // maintenance work waits for focus to return.
    _presentationVisible.value = !playbackIsBackgrounded(state);
    final backgrounded = state != AppLifecycleState.resumed;
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    model.setForeground(!backgrounded);
    _displayPreferences();
    if (backgrounded) {
      unawaited(AppLog.instance.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DesktopWindow.watchClose(null);
    _externalGeneration++;
    final pending = _pendingExternal;
    _pendingExternal = null;
    if (pending?.temporary ?? false) {
      unawaited(_inbox.release(pending!.location));
    }
    _inbox.dispose();
    model.setForeground(false);
    unawaited(PlayerDisplay.setHighRefreshRate(false));
    model.removeListener(_displayPreferences);
    _appearance.dispose();
    _presentationVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<({ThemeMode themeMode, bool animations})>(
        valueListenable: _appearance,
        child: LibraryPage(model: model),
        builder: (context, appearance, child) => MaterialApp(
          title: '映库 · AIPlayer',
          navigatorKey: _navigator,
          navigatorObservers: [_routeObserver],
          scaffoldMessengerKey: _messenger,
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          highContrastTheme: _highContrastTheme,
          highContrastDarkTheme: _highContrastDarkTheme,
          themeMode: appearance.themeMode,
          themeAnimationDuration: appearance.animations
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: _presentationVisible,
            child: child,
            builder: (context, visible, child) => TickerMode(
              enabled: visible && !_closing,
              child: MotionScope(
                enabled: appearance.animations,
                child: AbsorbPointer(
                  absorbing: _closing,
                  child: child ?? const SizedBox(),
                ),
              ),
            ),
          ),
          home: child,
        ),
      );
}

class _OpenRouteObserver extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute != null) {
        routes[index] = newRoute;
      } else {
        routes.removeAt(index);
      }
    } else if (newRoute != null) {
      routes.add(newRoute);
    }
  }
}
