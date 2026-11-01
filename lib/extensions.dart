import 'package:flutter/material.dart';

import 'api.dart';
import 'native.dart';
import 'terminal_panel.dart';

/// A language / toolchain that can be installed into Termux with one button.
class LangPack {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Color color;

  /// Tool whose presence means "installed".
  final String tool;

  /// Shell command run in a terminal. null = manual install ([guideUrl]).
  final String? install;
  final String? uninstall;
  final String? guideUrl;
  final bool popular;

  const LangPack({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.tool,
    this.install,
    this.uninstall,
    this.guideUrl,
    this.popular = false,
  });
}

/// Termux does not support partial upgrades, so always upgrade before installing.
String pkgInstall(String pkgs) =>
    'export DEBIAN_FRONTEND=noninteractive; pkg update -y && '
    'pkg upgrade -y -o Dpkg::Options::=--force-confold && pkg install -y $pkgs';

const _aapt2Fix = 'mkdir -p ~/.gradle && (grep -qs aapt2FromMavenOverride ~/.gradle/gradle.properties || '
    'echo "android.aapt2FromMavenOverride=\$PREFIX/bin/aapt2" >> ~/.gradle/gradle.properties)';

/// Claude Code has no Android build (since 2.1.113): the community installer runs the
/// official linux-arm64 binary through glibc-runner and keeps it updated.
const claudeInstallCmd = r'command -v curl >/dev/null || pkg install -y curl; '
    r'F="${TMPDIR:-$PREFIX/tmp}/claude-code-android-install.sh"; '
    r'curl -fsSL https://raw.githubusercontent.com/ferrumclaudepilgrim/claude-code-android/main/install.sh -o "$F" '
    r'&& bash "$F"';

/// Codex is in the official Termux repository.
final codexInstallCmd = pkgInstall('codex ripgrep');

final langPacks = <LangPack>[
  LangPack(
    id: 'python', title: 'Python', tool: 'python', popular: true,
    description: 'Python 3 и pip. Скрипты, боты, анализ данных.',
    icon: Icons.code, color: const Color(0xFF3776AB),
    install: pkgInstall('python'), uninstall: 'pkg uninstall -y python',
  ),
  LangPack(
    id: 'node', title: 'Node.js', tool: 'node', popular: true,
    description: 'JavaScript / TypeScript, npm.',
    icon: Icons.javascript, color: const Color(0xFF5FA04E),
    install: pkgInstall('nodejs-lts'), uninstall: 'pkg uninstall -y nodejs-lts',
  ),
  LangPack(
    id: 'clang', title: 'C / C++', tool: 'clang', popular: true,
    description: 'Компилятор clang, make и cmake.',
    icon: Icons.memory, color: const Color(0xFF00599C),
    install: pkgInstall('clang make cmake'), uninstall: 'pkg uninstall -y clang cmake',
  ),
  LangPack(
    id: 'java', title: 'Java (OpenJDK 21)', tool: 'java',
    description: 'JDK для Java, Kotlin и Gradle.',
    icon: Icons.coffee, color: const Color(0xFFE76F00),
    install: pkgInstall('openjdk-21'), uninstall: 'pkg uninstall -y openjdk-21',
  ),
  LangPack(
    id: 'kotlin', title: 'Kotlin', tool: 'kotlinc', popular: true,
    description: 'Компилятор kotlinc (ставит и Java).',
    icon: Icons.change_history, color: const Color(0xFF7F52FF),
    install: pkgInstall('openjdk-21 kotlin'), uninstall: 'pkg uninstall -y kotlin',
  ),
  LangPack(
    id: 'gradle', title: 'Gradle', tool: 'gradle',
    description: 'Сборка Kotlin/Java-проектов.',
    icon: Icons.build, color: const Color(0xFF209BC4),
    install: pkgInstall('openjdk-21 gradle'), uninstall: 'pkg uninstall -y gradle',
  ),
  LangPack(
    id: 'android', title: 'Сборка APK в Termux', tool: 'aapt2',
    description: 'aapt2 для ARM — без него Gradle не соберёт APK на телефоне.',
    icon: Icons.android, color: const Color(0xFF3DDC84),
    install: '${pkgInstall('aapt2 openjdk-21')} && $_aapt2Fix',
  ),
  LangPack(
    id: 'flutter', title: 'Flutter', tool: 'flutter',
    description: 'Ставится отдельно (сборка flutter для Termux). Нажми «Инструкция».',
    icon: Icons.flutter_dash, color: const Color(0xFF02569B),
    guideUrl: 'https://github.com/mumumusuc/termux-flutter',
  ),
  LangPack(
    id: 'dart', title: 'Dart', tool: 'dart',
    description: 'Dart SDK без Flutter: консольные программы.',
    icon: Icons.adjust, color: const Color(0xFF0175C2),
    install: pkgInstall('dart'), uninstall: 'pkg uninstall -y dart',
  ),
  LangPack(
    id: 'go', title: 'Go', tool: 'go',
    description: 'Компилятор Go.',
    icon: Icons.speed, color: const Color(0xFF00ADD8),
    install: pkgInstall('golang'), uninstall: 'pkg uninstall -y golang',
  ),
  LangPack(
    id: 'rust', title: 'Rust', tool: 'cargo',
    description: 'rustc и cargo.',
    icon: Icons.settings, color: const Color(0xFFCE422B),
    install: pkgInstall('rust'), uninstall: 'pkg uninstall -y rust',
  ),
  LangPack(
    id: 'ruby', title: 'Ruby', tool: 'ruby',
    description: 'Интерпретатор Ruby и gem.',
    icon: Icons.diamond_outlined, color: const Color(0xFFCC342D),
    install: pkgInstall('ruby'), uninstall: 'pkg uninstall -y ruby',
  ),
  LangPack(
    id: 'php', title: 'PHP', tool: 'php',
    description: 'PHP CLI и встроенный веб-сервер.',
    icon: Icons.web, color: const Color(0xFF777BB4),
    install: pkgInstall('php'), uninstall: 'pkg uninstall -y php',
  ),
  LangPack(
    id: 'claude', title: 'Claude Code', tool: 'claude',
    description: 'ИИ-агент Anthropic. Вход по подписке Pro/Max. Панель «Агент» в проекте.',
    icon: Icons.smart_toy_outlined, color: const Color(0xFFD97757),
    install: claudeInstallCmd,
  ),
  LangPack(
    id: 'codex', title: 'Codex', tool: 'codex',
    description: 'ИИ-агент OpenAI. Вход через ChatGPT (Plus/Pro). Панель «Агент» в проекте.',
    icon: Icons.smart_toy, color: const Color(0xFF10A37F),
    install: codexInstallCmd, uninstall: 'pkg uninstall -y codex',
  ),
  LangPack(
    id: 'git', title: 'Git', tool: 'git', popular: true,
    description: 'Контроль версий, clone/push.',
    icon: Icons.merge_type, color: const Color(0xFFF05032),
    install: pkgInstall('git'), uninstall: 'pkg uninstall -y git',
  ),
];

/// Screen with all language packs and their status.
class ExtensionsPage extends StatefulWidget {
  final Api api;
  const ExtensionsPage({super.key, required this.api});

  @override
  State<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends State<ExtensionsPage> {
  List<String>? tools;
  String? error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await widget.api.info(refresh: true);
      if (mounted) setState(() => tools = info.tools);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _run(LangPack p, String cmd, String title) async {
    final home = (await widget.api.info()).home;
    if (!mounted) return;
    await runInTerminalPage(context, widget.api, cmd: cmd, cwd: home, title: title);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = tools;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Языки и расширения'),
        actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: t == null
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(12), children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Всё ставится в Termux одной кнопкой. Установка идёт в терминале, где видно ход и при необходимости можно ответить на вопросы.',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
              for (final p in langPacks) _card(p, t.contains(p.tool)),
            ])),
    );
  }

  Widget _card(LangPack p, bool installed) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: p.color.withValues(alpha: .18), child: Icon(p.icon, color: p.color)),
        title: Row(children: [
          Flexible(child: Text(p.title)),
          if (installed) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_circle, size: 16, color: Colors.greenAccent),
          ],
        ]),
        subtitle: Text(p.description, style: const TextStyle(fontSize: 12.5)),
        trailing: installed
            ? (p.uninstall == null
                ? null
                : PopupMenuButton<String>(
                    onSelected: (_) => _run(p, p.uninstall!, 'Удаление: ${p.title}'),
                    itemBuilder: (_) => const [PopupMenuItem(value: 'rm', child: Text('Удалить'))],
                  ))
            : p.install != null
                ? FilledButton.tonal(
                    onPressed: () => _run(p, p.install!, 'Установка: ${p.title}'),
                    child: const Text('Установить'),
                  )
                : OutlinedButton(
                    onPressed: () => Native.openUrl(p.guideUrl!),
                    child: const Text('Инструкция'),
                  ),
      ),
    );
  }
}
