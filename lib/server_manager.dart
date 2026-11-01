import 'dart:convert';

import 'package:flutter/services.dart';

import 'api.dart';
import 'native.dart';

enum ConnectStatus { ok, noTermux, noPermission, noResponse }

/// Installs (from app assets) and starts the server inside Termux.
class ServerManager {
  final Api api;
  ServerManager(this.api);

  static const termuxHome = '/data/data/com.termux/files/home';
  static const installUrl = 'https://raw.githubusercontent.com/GRUMM7506/termux-ide/main/termux/install.sh';

  /// The command the user pastes into Termux once.
  static const setupCommand = 'curl -fsSL $installUrl | bash';

  String? _server;
  String? _start;
  String? _install;

  Future<void> _loadAssets() async {
    _server ??= await rootBundle.loadString('assets/termux/server.py');
    _start ??= await rootBundle.loadString('assets/termux/start.sh');
    _install ??= await rootBundle.loadString('assets/termux/install.sh');
  }

  Future<String> bundledVersion() async {
    await _loadAssets();
    return RegExp(r'VERSION = "([^"]+)"').firstMatch(_server!)?.group(1) ?? '0';
  }

  /// Same as [setupCommand] but without internet access to GitHub.
  Future<String> offlineSetupCommand() async {
    await _loadAssets();
    return 'echo ${base64.encode(utf8.encode(_install!))} | base64 -d | bash';
  }

  String _b64(String s) => base64.encode(utf8.encode(s));

  /// Writes server.py + start.sh into ~/.termux-ide and starts the server.
  Future<String> _installAndStartCommand() async {
    await _loadAssets();
    return 'D="\$HOME/.termux-ide"; mkdir -p "\$D" && '
        'echo ${_b64(_server!)} | base64 -d > "\$D/server.py" && '
        'echo ${_b64(_start!)} | base64 -d > "\$D/start.sh" && '
        'chmod 700 "\$D/start.sh" && exec bash "\$D/start.sh" ${api.token}';
  }

  Future<ServerInfo?> ping() async {
    try {
      return await api.info();
    } catch (_) {
      return null;
    }
  }

  /// Makes sure an up-to-date server is running. Safe to call repeatedly.
  Future<ConnectStatus> connect({void Function(String)? onStep}) async {
    final want = await bundledVersion();
    final cur = await ping();
    if (cur != null && cur.version == want) return ConnectStatus.ok;

    if (!await Native.isTermuxInstalled()) return ConnectStatus.noTermux;
    onStep?.call('Запрашиваю разрешение…');
    if (!await Native.ensureRunCommandPermission()) return ConnectStatus.noPermission;

    onStep?.call(cur == null ? 'Запускаю сервер в Termux…' : 'Обновляю сервер в Termux…');
    await Native.runInTermux(await _installAndStartCommand(), background: true);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final info = await ping();
      if (info != null && info.version == want) return ConnectStatus.ok;
    }
    return ConnectStatus.noResponse;
  }

  /// Opens a visible Termux session with the server log (for troubleshooting).
  static Future<void> showLog() => Native.runInTermux(
      'echo "--- ~/.termux-ide/server.log ---"; tail -n 40 ~/.termux-ide/server.log 2>/dev/null || echo "лога нет"; '
      'echo; grep -s allow-external-apps ~/.termux/termux.properties || echo "allow-external-apps НЕ включён"; '
      'command -v python >/dev/null && python --version || echo "python НЕ установлен"');
}
