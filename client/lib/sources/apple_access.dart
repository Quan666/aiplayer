import 'dart:io';
import 'package:flutter/services.dart';

/// macOS retains user-selected access across launches using security bookmarks.
class AppleFileAccess {
  static const _channel = MethodChannel('app.aiplayer/files');
  // The personal-use macOS package is not sandboxed and needs no scoped grant.
  static const _adhoc = bool.fromEnvironment('AIPLAYER_MACOS_ADHOC');
  static Future<void> restore() async {
    if (Platform.isMacOS && !_adhoc) {
      await _channel.invokeMethod<void>('restore');
    }
  }

  static Future<void> remember(String path) async {
    if (Platform.isMacOS && !_adhoc) {
      await _channel.invokeMethod<void>('remember', path);
    }
  }
}
