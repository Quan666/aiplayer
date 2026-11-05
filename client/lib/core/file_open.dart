import 'dart:io';

import 'package:flutter/services.dart';

import 'network.dart';

typedef ExternalFileProcess = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// Hands a local file to the system. Success means the handoff was accepted;
/// another application may still be reading the file after this Future ends.
Future<void> openExternalFile(String localPath) =>
    const ExternalFileOpener().open(localPath);

/// Revokes native work which has not launched yet. A completed handoff and its
/// read permission remain valid, including a system Open In menu already shown.
Future<void> cancelPendingExternalFileOpen() =>
    const ExternalFileOpener().cancelPending();

class ExternalFileOpener {
  static const channel = MethodChannel('app.aiplayer/file_open');
  final String? operatingSystem;
  final ExternalFileProcess? process;

  const ExternalFileOpener({this.operatingSystem, this.process});

  Future<void> cancelPending() async {
    final platform = operatingSystem ?? Platform.operatingSystem;
    if (platform != 'android' && platform != 'ios' && platform != 'macos') {
      return;
    }
    try {
      await channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Older platform runners have no delayed native preparation to revoke.
    } on PlatformException {
      // Cancellation is best effort and must never undo an accepted handoff.
    }
  }

  Future<void> open(String localPath) async {
    if (localPath.isEmpty || localPath.contains('\u0000')) {
      throw const AppFailure('文件位置无效。');
    }
    final path = File(localPath).absolute.path;
    final platform = operatingSystem ?? Platform.operatingSystem;
    try {
      if (platform == 'android' || platform == 'ios' || platform == 'macos') {
        await channel.invokeMethod<void>('open', path);
        return;
      }
      final run = process ?? _run;
      final ProcessResult result;
      if (platform == 'linux') {
        result = await run('xdg-open', [Uri.file(path).toString()]);
      } else if (platform == 'windows') {
        // The path is data in the child environment, never PowerShell source.
        result = await run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'try { Start-Process -FilePath $env:AIPLAYER_EXTERNAL_FILE -ErrorAction Stop; exit 0 } catch { exit 1 }',
          ],
          environment: {'AIPLAYER_EXTERNAL_FILE': path},
        );
      } else {
        throw const AppFailure('当前系统暂不支持使用其他应用打开。');
      }
      if (result.exitCode != 0) {
        throw const AppFailure('无法打开文件，请确认已安装支持此文件类型的应用。');
      }
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法使用其他应用打开此文件。');
    } on MissingPluginException {
      throw const AppFailure('当前系统暂不支持使用其他应用打开。');
    } on ProcessException {
      throw const AppFailure('无法启动系统文件打开器。');
    }
  }

  static Future<ProcessResult> _run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) => Process.run(executable, arguments, environment: environment);
}
