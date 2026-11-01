import 'package:flutter/services.dart';

/// Bridge to MainActivity.kt.
class Native {
  static const _ch = MethodChannel('termux_ide/native');

  static Future<String> filesDir() async => (await _ch.invokeMethod<String>('filesDir'))!;

  static Future<bool> isTermuxInstalled() async => (await _ch.invokeMethod<bool>('isTermuxInstalled')) ?? false;

  static Future<bool> hasRunCommandPermission() async =>
      (await _ch.invokeMethod<bool>('hasPermission')) ?? false;

  /// Asks for com.termux.permission.RUN_COMMAND if needed. Returns true if granted.
  static Future<bool> ensureRunCommandPermission() async =>
      (await _ch.invokeMethod<bool>('ensurePermission')) ?? false;

  /// Runs [command] through the Termux RUN_COMMAND intent.
  /// background=false opens a visible Termux session.
  static Future<void> runInTermux(String command, {String? workdir, bool background = false}) =>
      _ch.invokeMethod('runInTermux', {'command': command, 'workdir': workdir, 'background': background});

  static Future<void> openTermux() => _ch.invokeMethod('openTermux');

  static Future<void> openUrl(String url) => _ch.invokeMethod('openUrl', {'url': url});

  static Future<void> openAppSettings() => _ch.invokeMethod('openAppSettings');
}
