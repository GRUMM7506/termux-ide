import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'api.dart';

/// One terminal tab = one PTY session on the server + an xterm emulator.
class TermTab {
  final String title;
  final TermSession session;
  final Terminal terminal;
  final bool isRun;
  final bool hotReload;
  final ValueNotifier<int?> exitCode = ValueNotifier(null);
  final ValueNotifier<bool> ctrl = ValueNotifier(false);
  final FocusNode focus = FocusNode();
  StreamSubscription<String>? _sub;
  bool _disposed = false;

  TermTab._(this.title, this.session, this.terminal, this.isRun, this.hotReload);

  bool get running => exitCode.value == null;

  static Future<TermTab> start(
    Api api, {
    required String cwd,
    String cmd = '',
    required String title,
    bool isRun = false,
    bool hotReload = false,
  }) async {
    final terminal = Terminal(maxLines: 10000);
    final s = await api.openTerminal(cmd: cmd, cwd: cwd, title: title);
    final tab = TermTab._(title, s, terminal, isRun, hotReload);
    tab._sub = s.output.listen(terminal.write);
    terminal.onOutput = (d) => s.input(tab._applyCtrl(d));
    terminal.onResize = (w, h, pw, ph) => s.resize(w, h);
    unawaited(s.exitCode.then((c) {
      if (!tab._disposed) tab.exitCode.value = c;
    }));
    return tab;
  }

  /// Sticky Ctrl from the extra-keys bar: the next typed letter becomes Ctrl+letter.
  String _applyCtrl(String d) {
    // A real terminal sends CR for Enter; soft keyboards may deliver "\n" as text.
    if (d == '\n') d = '\r';
    if (!ctrl.value || d.length != 1) return d;
    ctrl.value = false;
    final c = d.toUpperCase().codeUnitAt(0);
    if (c >= 64 && c <= 95) return String.fromCharCode(c - 64);
    return d;
  }

  void key(TerminalKey k, {bool ctrlKey = false}) => terminal.keyInput(k, ctrl: ctrlKey);
  void type(String text) => session.input(text);

  /// Ctrl+C, then SIGTERM if the program ignores it.
  void stop() {
    session.signal('int');
    Timer(const Duration(seconds: 2), () {
      if (!_disposed && running) session.signal('term');
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    session.close();
    focus.dispose();
    exitCode.dispose();
    ctrl.dispose();
  }
}

/// All terminal tabs of an open project.
class TermHub extends ChangeNotifier {
  final List<TermTab> tabs = [];
  int active = -1;

  TermTab? get current => active >= 0 && active < tabs.length ? tabs[active] : null;

  TermTab? get runTab {
    for (final t in tabs.reversed) {
      if (t.isRun) return t;
    }
    return null;
  }

  void add(TermTab t) {
    tabs.add(t);
    active = tabs.length - 1;
    notifyListeners();
  }

  void select(int i) {
    active = i;
    notifyListeners();
  }

  void close(TermTab t) {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    tabs.removeAt(i);
    if (active >= tabs.length) active = tabs.length - 1;
    notifyListeners();
    // Dispose after the frame so TerminalView is gone first.
    WidgetsBinding.instance.addPostFrameCallback((_) => t.dispose());
  }

  void closeAll() {
    final all = List.of(tabs);
    tabs.clear();
    active = -1;
    for (final t in all) {
      t.dispose();
    }
  }
}

const _termTheme = TerminalTheme(
  cursor: Color(0xFFAEAFAD),
  selection: Color(0x80264F78),
  foreground: Color(0xFFCCCCCC),
  background: Color(0xFF181818),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF0DBC79),
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFF14C4C),
  brightGreen: Color(0xFF23D18B),
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

/// Terminal emulator view of one tab + extra keys.
class TermView extends StatelessWidget {
  final TermTab tab;
  final double fontSize;
  final bool showKeys;
  const TermView({super.key, required this.tab, required this.fontSize, this.showKeys = true});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: TerminalView(
          tab.terminal,
          key: ObjectKey(tab),
          focusNode: tab.focus,
          theme: _termTheme,
          textStyle: TerminalStyle(fontSize: fontSize, fontFamily: 'monospace'),
          padding: const EdgeInsets.all(6),
          autofocus: false,
        ),
      ),
      if (showKeys) TerminalKeysBar(tab: tab),
    ]);
  }
}

class TerminalKeysBar extends StatelessWidget {
  final TermTab tab;
  const TerminalKeysBar({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    Widget k(String label, VoidCallback onTap, {bool active = false}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 42),
            height: 38,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: active ? const Color(0xFF094771) : null,
            child: Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, color: Colors.white)),
          ),
        );
    return Material(
      color: const Color(0xFF252526),
      child: ValueListenableBuilder<bool>(
        valueListenable: tab.ctrl,
        builder: (_, ctrlOn, __) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            k('ESC', () => tab.key(TerminalKey.escape)),
            k('TAB', () => tab.key(TerminalKey.tab)),
            k('CTRL', () => tab.ctrl.value = !ctrlOn, active: ctrlOn),
            k('^C', () => tab.key(TerminalKey.keyC, ctrlKey: true)),
            k('^D', () => tab.key(TerminalKey.keyD, ctrlKey: true)),
            k('←', () => tab.key(TerminalKey.arrowLeft)),
            k('↓', () => tab.key(TerminalKey.arrowDown)),
            k('↑', () => tab.key(TerminalKey.arrowUp)),
            k('→', () => tab.key(TerminalKey.arrowRight)),
            k('HOME', () => tab.key(TerminalKey.home)),
            k('END', () => tab.key(TerminalKey.end)),
            for (final s in const ['|', '/', '-', '~', '_', '&', '>', '<', r'$', '*'])
              k(s, () => tab.type(s)),
          ]),
        ),
      ),
    );
  }
}

/// Panel at the bottom of the IDE: tabs + active terminal.
class TerminalPanel extends StatelessWidget {
  final TermHub hub;
  final double fontSize;
  final bool maximized;
  final VoidCallback onNewShell;
  final VoidCallback onHide;
  final VoidCallback onToggleMax;

  const TerminalPanel({
    super.key,
    required this.hub,
    required this.fontSize,
    required this.maximized,
    required this.onNewShell,
    required this.onHide,
    required this.onToggleMax,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final cur = hub.current;
        return Container(
          color: const Color(0xFF181818),
          child: Column(children: [
            Container(
              height: 36,
              color: const Color(0xFF252526),
              child: Row(children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: hub.tabs.length,
                    itemBuilder: (_, i) {
                      final t = hub.tabs[i];
                      final on = i == hub.active;
                      return InkWell(
                        onTap: () => hub.select(i),
                        child: Container(
                          padding: const EdgeInsets.only(left: 10),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: on ? Colors.lightBlueAccent : Colors.transparent, width: 2)),
                          ),
                          child: Row(children: [
                            ValueListenableBuilder<int?>(
                              valueListenable: t.exitCode,
                              builder: (_, code, __) => Icon(
                                t.isRun ? Icons.play_arrow : Icons.terminal,
                                size: 14,
                                color: code == null
                                    ? Colors.greenAccent
                                    : (code == 0 ? Colors.white38 : Colors.redAccent),
                              ),
                            ),
                            const SizedBox(width: 4),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: Text(t.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, color: on ? Colors.white : Colors.white60)),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              iconSize: 14,
                              tooltip: 'Закрыть',
                              onPressed: () => hub.close(t),
                              icon: const Icon(Icons.close),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                    tooltip: 'Новый терминал', iconSize: 18, visualDensity: VisualDensity.compact,
                    onPressed: onNewShell, icon: const Icon(Icons.add)),
                IconButton(
                    tooltip: maximized ? 'Свернуть' : 'Развернуть', iconSize: 18, visualDensity: VisualDensity.compact,
                    onPressed: onToggleMax, icon: Icon(maximized ? Icons.fullscreen_exit : Icons.fullscreen)),
                IconButton(
                    tooltip: 'Скрыть', iconSize: 18, visualDensity: VisualDensity.compact,
                    onPressed: onHide, icon: const Icon(Icons.keyboard_arrow_down)),
              ]),
            ),
            Expanded(
              child: cur == null
                  ? Center(
                      child: TextButton.icon(
                        onPressed: onNewShell,
                        icon: const Icon(Icons.terminal),
                        label: const Text('Открыть терминал'),
                      ),
                    )
                  : TermView(tab: cur, fontSize: fontSize - 1),
            ),
          ]),
        );
      },
    );
  }
}

/// Full-screen terminal for one command (install, create project…). Returns the exit code.
Future<int?> runInTerminalPage(BuildContext context, Api api,
    {required String cmd, required String cwd, required String title}) {
  return Navigator.of(context).push<int?>(MaterialPageRoute(
    builder: (_) => _TerminalPage(api: api, cmd: cmd, cwd: cwd, title: title),
  ));
}

class _TerminalPage extends StatefulWidget {
  final Api api;
  final String cmd;
  final String cwd;
  final String title;
  const _TerminalPage({required this.api, required this.cmd, required this.cwd, required this.title});

  @override
  State<_TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<_TerminalPage> {
  TermTab? tab;
  String? error;

  @override
  void initState() {
    super.initState();
    TermTab.start(widget.api, cwd: widget.cwd, cmd: widget.cmd, title: widget.title, isRun: true).then((t) {
      if (!mounted) {
        t.dispose();
        return;
      }
      setState(() => tab = t);
    }, onError: (Object e) {
      if (mounted) setState(() => error = '$e');
    });
  }

  @override
  void dispose() {
    tab?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (t != null)
            ValueListenableBuilder<int?>(
              valueListenable: t.exitCode,
              builder: (_, code, __) => code == null
                  ? TextButton.icon(
                      onPressed: t.stop,
                      icon: const Icon(Icons.stop, color: Colors.redAccent),
                      label: const Text('Стоп'),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, code),
                        child: Text(code == 0 ? 'Готово' : 'Закрыть (код $code)'),
                      ),
                    ),
            ),
        ],
      ),
      body: SafeArea(
        child: error != null
            ? Center(child: Text('Не удалось запустить: $error'))
            : t == null
                ? const Center(child: CircularProgressIndicator())
                : TermView(tab: t, fontSize: 13),
      ),
    );
  }
}
