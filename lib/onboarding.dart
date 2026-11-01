import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'extensions.dart';
import 'native.dart';
import 'server_manager.dart';
import 'terminal_panel.dart';

/// First-run guide: Termux → one setup command → permission → connect → languages.
class OnboardingPage extends StatefulWidget {
  final Api api;
  final ServerManager server;

  /// Called when the user is done (connected or skipped).
  final void Function(List<String> tools) onDone;

  const OnboardingPage({super.key, required this.api, required this.server, required this.onDone});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> with WidgetsBindingObserver {
  int _page = 0;
  bool? _termux;
  bool _perm = false;
  bool _setupCopied = false;
  bool _connecting = false;
  String? _connectMsg;
  ConnectStatus? _status;
  List<String> _tools = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final t = await Native.isTermuxInstalled();
    final p = t && await Native.hasRunCommandPermission();
    if (!mounted) return;
    setState(() {
      _termux = t;
      _perm = p;
    });
  }

  Future<void> _copySetup({bool offline = false}) async {
    final cmd = offline ? await widget.server.offlineSetupCommand() : ServerManager.setupCommand;
    await Clipboard.setData(ClipboardData(text: cmd));
    setState(() => _setupCopied = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Команда скопирована. В Termux: долгое нажатие → «Вставить» → Enter'),
      duration: Duration(seconds: 5),
    ));
    await Native.openTermux();
  }

  Future<void> _grant() async {
    final ok = await Native.ensureRunCommandPermission();
    setState(() => _perm = ok);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Разрешение не выдано. Включи его в настройках приложения.'),
        action: SnackBarAction(label: 'Настройки', onPressed: Native.openAppSettings),
      ));
    }
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _connectMsg = null;
      _status = null;
    });
    final st = await widget.server.connect(onStep: (s) {
      if (mounted) setState(() => _connectMsg = s);
    });
    List<String> tools = [];
    if (st == ConnectStatus.ok) {
      try {
        tools = (await widget.api.info(refresh: true)).tools;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _status = st;
      _tools = tools;
      _perm = st != ConnectStatus.noPermission;
      if (st == ConnectStatus.ok) _page = 2;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: switch (_page) {
            0 => _welcome(),
            1 => _setup(),
            _ => _languages(),
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- page 0

  Widget _welcome() {
    Widget tip(IconData i, String title, String text) => ListTile(
          leading: Icon(i, color: const Color(0xFF3DDC97)),
          title: Text(title),
          subtitle: Text(text),
        );
    return ListView(key: const ValueKey(0), padding: const EdgeInsets.all(24), children: [
      const SizedBox(height: 12),
      Center(child: Image.asset('assets/branding/logo.png', width: 112, height: 112)),
      const SizedBox(height: 16),
      const Text('Termux IDE', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text('Пиши и запускай код прямо на телефоне', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 24),
      tip(Icons.folder_open, 'Проекты и файлы', 'Дерево файлов, вкладки, подсветка 15+ языков, автоотступы.'),
      tip(Icons.play_arrow, 'Запуск в одно касание', 'IDE сама понимает, как запускать: Flutter, Python, Kotlin, C++, Node…'),
      tip(Icons.terminal, 'Настоящий терминал', 'Интерактивная консоль Termux: ввод, цвета, hot reload.'),
      tip(Icons.extension, 'Языки одной кнопкой', 'Python, Node.js, Kotlin, Java, Go, Rust ставятся из приложения.'),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: () => setState(() => _page = 1),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Начать настройку (≈2 минуты)'),
      ),
    ]);
  }

  // ---------------------------------------------------------------- page 1

  Widget _step(int n, String title, bool done, Widget body, {bool enabled = true}) {
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: done ? const Color(0xFF3DDC97) : const Color(0xFF37373D),
                child: done
                    ? const Icon(Icons.check, size: 16, color: Colors.black)
                    : Text('$n', style: const TextStyle(fontSize: 13, color: Colors.white)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ]),
            if (enabled) ...[const SizedBox(height: 12), body],
          ]),
        ),
      ),
    );
  }

  Widget _setup() {
    final termux = _termux ?? false;
    final connected = _status == ConnectStatus.ok;
    return ListView(key: const ValueKey(1), padding: const EdgeInsets.all(16), children: [
      Row(children: [
        IconButton(onPressed: () => setState(() => _page = 0), icon: const Icon(Icons.arrow_back)),
        const Text('Настройка', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 8),
      _step(
        1,
        termux ? 'Termux установлен' : 'Установи Termux',
        termux,
        termux
            ? const Text('Отлично, идём дальше.', style: TextStyle(color: Colors.white60))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                    'Termux — это Linux-терминал, в котором IDE компилирует и запускает код. '
                    'Ставь версию с F-Droid или GitHub: из Google Play не подойдёт.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: () => Native.openUrl('https://f-droid.org/packages/com.termux/'),
                    icon: const Icon(Icons.download),
                    label: const Text('F-Droid'),
                  ),
                  OutlinedButton(
                    onPressed: () => Native.openUrl('https://github.com/termux/termux-app/releases/latest'),
                    child: const Text('GitHub'),
                  ),
                  TextButton(onPressed: _check, child: const Text('Проверить')),
                ]),
              ]),
      ),
      _step(
        2,
        'Подготовь Termux (один раз)',
        _setupCopied || connected,
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Команда разрешит IDE запускать команды и поставит Python, на котором работает сервер IDE.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)),
            child: const SelectableText(ServerManager.setupCommand, style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _copySetup,
            icon: const Icon(Icons.copy),
            label: const Text('Скопировать и открыть Termux'),
          ),
          TextButton(
            onPressed: () => _copySetup(offline: true),
            child: const Text('Нет доступа к GitHub? Скопировать полную команду'),
          ),
          const Text('Дождись надписи «✔ Готово» и возвращайся сюда.', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
        ]),
        enabled: termux,
      ),
      _step(
        3,
        'Разреши запуск команд',
        _perm,
        _perm
            ? const Text('Разрешение выдано.', style: TextStyle(color: Colors.white60))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Android спросит: «Разрешить Termux IDE выполнять команды в Termux?» — нажми «Разрешить».',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 10),
                FilledButton(onPressed: _grant, child: const Text('Разрешить')),
              ]),
        enabled: termux,
      ),
      _step(
        4,
        connected ? 'Подключено' : 'Подключи IDE к Termux',
        connected,
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_connecting)
            Row(children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text(_connectMsg ?? 'Подключаюсь…')),
            ])
          else ...[
            if (_status != null && !connected) _failure(_status!),
            FilledButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.link),
              label: Text(_status == null ? 'Подключить' : 'Попробовать ещё раз'),
            ),
          ],
        ]),
        enabled: termux,
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: () => widget.onDone(const []), child: const Text('Пропустить настройку')),
    ]);
  }

  Widget _failure(ConnectStatus s) {
    final text = switch (s) {
      ConnectStatus.noTermux => 'Termux не найден.',
      ConnectStatus.noPermission => 'Нет разрешения на запуск команд (шаг 3).',
      ConnectStatus.noResponse =>
        'Сервер не ответил. Чаще всего не выполнена команда из шага 2 '
            '(после неё Termux нужно перезапустить, если он был открыт), или не поставился Python.',
      ConnectStatus.ok => '',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: const TextStyle(color: Colors.orangeAccent)),
        if (s == ConnectStatus.noResponse)
          TextButton.icon(
            onPressed: ServerManager.showLog,
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: const Text('Показать диагностику в Termux'),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- page 2

  Widget _languages() {
    final popular = langPacks.where((p) => p.popular).toList();
    return ListView(key: const ValueKey(2), padding: const EdgeInsets.all(16), children: [
      const SizedBox(height: 8),
      const Icon(Icons.check_circle, size: 56, color: Color(0xFF3DDC97)),
      const SizedBox(height: 8),
      const Text('Termux подключён!', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text('Поставь языки, на которых будешь писать. Это можно сделать и позже: «Языки и расширения».',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 16),
      for (final p in popular)
        Card(
          child: ListTile(
            leading: Icon(p.icon, color: p.color),
            title: Text(p.title),
            subtitle: Text(p.description, style: const TextStyle(fontSize: 12.5)),
            trailing: _tools.contains(p.tool)
                ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                : FilledButton.tonal(
                    onPressed: () async {
                      await runInTerminalPage(context, widget.api,
                          cmd: p.install!, cwd: ServerManager.termuxHome, title: 'Установка: ${p.title}');
                      try {
                        final t = (await widget.api.info(refresh: true)).tools;
                        if (mounted) setState(() => _tools = t);
                      } catch (_) {}
                    },
                    child: const Text('Установить'),
                  ),
          ),
        ),
      TextButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExtensionsPage(api: widget.api)));
          try {
            final t = (await widget.api.info(refresh: true)).tools;
            if (mounted) setState(() => _tools = t);
          } catch (_) {}
        },
        child: const Text('Все языки и расширения'),
      ),
      const SizedBox(height: 16),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Как пользоваться', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('1. Создай проект или открой папку.\n'
                '2. Пиши код. Долгое нажатие в дереве — создать, переименовать, удалить.\n'
                '3. Нажми ▶ — IDE сама подберёт команду (строка под заголовком).\n'
                '4. Внизу — настоящий терминал: можно вводить данные в программу.\n'
                '5. Для Flutter: ⚡ — hot reload, ↻ — hot restart.'),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => widget.onDone(_tools),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Начать работу'),
      ),
    ]);
  }
}
