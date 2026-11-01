import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'dialogs.dart';
import 'editor.dart';
import 'extensions.dart';
import 'file_tree.dart';
import 'git.dart';
import 'git_panel.dart';
import 'native.dart';
import 'runner.dart';
import 'settings.dart';
import 'terminal_panel.dart';

class OpenFile {
  String path;
  final CodeController ctrl;
  final UndoHistoryController undo = UndoHistoryController();
  final FocusNode focus = FocusNode();
  String saved;

  OpenFile(this.path, String content)
      : saved = content,
        ctrl = CodeController(text: content, language: languageForPath(path));

  bool get dirty => ctrl.text != saved;
  String get name => path.split('/').last;

  /// Disposed after the current frame, when the editor widget using it is gone.
  void disposeLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctrl.dispose();
      undo.dispose();
      focus.dispose();
    });
  }
}

class IdePage extends StatefulWidget {
  final Api api;
  final Settings settings;
  final String root;
  final List<String> tools;
  final VoidCallback onClose;

  const IdePage({
    super.key,
    required this.api,
    required this.settings,
    required this.root,
    required this.tools,
    required this.onClose,
  });

  @override
  State<IdePage> createState() => _IdePageState();
}

class _IdePageState extends State<IdePage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _tree = GlobalKey<FileTreeState>();
  final List<OpenFile> _files = [];
  int _active = -1;

  final _hub = TermHub();
  bool _panelOpen = false;
  bool _panelMax = false;
  double _panelH = 260;
  bool _termFocused = false;
  bool _editorFocused = false;
  bool _closing = false;

  ProjectInfo? _project;
  late List<String> _tools = widget.tools;
  late final GitController _git = GitController(widget.api, widget.root);
  int _side = 0; // 0 = files, 1 = git
  String _home = '/data/data/com.termux/files/home';

  Api get api => widget.api;
  Settings get st => widget.settings;
  OpenFile? get _cur => _active >= 0 && _active < _files.length ? _files[_active] : null;
  String get _targetId => st.targetByProject[widget.root] ?? 'auto';
  TermTab? get _runTab => _hub.runTab;
  bool get _running => _runTab?.running ?? false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
    _hub.addListener(_onHub);
    Future.microtask(_detect);
    Future.microtask(_git.refresh);
    api.info().then((i) {
      _home = i.home;
    }).catchError((_) {});
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _hub.removeListener(_onHub);
    _hub.closeAll();
    _hub.dispose();
    _git.dispose();
    for (final f in _files) {
      f.disposeLater();
    }
    super.dispose();
  }

  void _onHub() {
    if (mounted) setState(() {});
  }

  void _onFocus() {
    final pf = FocusManager.instance.primaryFocus;
    bool inside(FocusNode n) => pf != null && (pf == n || pf.ancestors.contains(n));
    final term = _hub.tabs.any((t) => inside(t.focus));
    final ed = _cur != null && inside(_cur!.focus);
    if (term != _termFocused || ed != _editorFocused) {
      setState(() {
        _termFocused = term;
        _editorFocused = ed;
      });
    }
  }

  Future<void> _detect() async {
    try {
      final p = await detectProject(api, widget.root);
      if (!mounted) return;
      setState(() => _project = p);
      if (_files.isEmpty) {
        // Well-known entry points first, then any runnable file in the project root.
        final runnable = p.rootNames.where((n) => fileTarget(n) != null).toList()..sort();
        final candidates = [
          'lib/main.dart', 'main.py', 'Main.kt', 'Main.java', 'main.c', 'main.cpp', 'main.js',
          'main.go', 'src/main.rs', 'index.js',
          ...runnable,
          'README.md',
        ];
        for (final f in candidates) {
          if (!p.rootNames.contains(f.split('/').first)) continue;
          try {
            await _open('${widget.root}/$f');
            if (_files.isNotEmpty) break;
          } catch (_) {}
        }
      }
    } catch (e) {
      _snack('Не удалось прочитать проект: $e');
    }
  }

  Future<void> _refreshTools() async {
    try {
      final info = await api.info(refresh: true);
      if (mounted) setState(() => _tools = info.tools);
    } catch (_) {}
  }

  void _snack(String msg, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), action: action, duration: const Duration(seconds: 4)));
  }

  // ------------------------------------------------------------------ files

  Future<void> _open(String path) async {
    final i = _files.indexWhere((f) => f.path == path);
    if (i >= 0) {
      setState(() => _active = i);
      return;
    }
    final r = await api.readFile(path);
    if (r.binary) {
      _snack('Это бинарный файл, открыть нельзя');
      return;
    }
    setState(() {
      _files.add(OpenFile(path, r.content));
      _active = _files.length - 1;
    });
  }

  Future<void> _openFromTree(String path) async {
    try {
      await _open(path);
      if (_scaffold.currentState?.isDrawerOpen ?? false) _scaffold.currentState!.closeDrawer();
    } catch (e) {
      _snack('Ошибка открытия: $e');
    }
  }

  Future<bool> _save(OpenFile f) async {
    try {
      final text = f.ctrl.text;
      await api.write(f.path, text);
      f.saved = text;
      if (mounted) setState(() {});
      unawaited(_git.refresh());
      return true;
    } catch (e) {
      _snack('Не сохранилось: $e');
      return false;
    }
  }

  Future<void> _saveCurrent() async {
    final f = _cur;
    if (f != null && await _save(f)) _snack('Сохранено: ${f.name}');
  }

  Future<void> _saveAll() async {
    for (final f in _files.where((f) => f.dirty).toList()) {
      await _save(f);
    }
  }

  Future<void> _closeTab(int i) async {
    final f = _files[i];
    if (f.dirty) {
      final r = await askChoice(context, 'Сохранить ${f.name}?', ['Сохранить', 'Не сохранять', 'Отмена']);
      if (r == null || r == 2) return;
      if (r == 0 && !await _save(f)) return;
    }
    setState(() {
      _files.remove(f);
      if (_active >= _files.length) _active = _files.length - 1;
    });
    f.disposeLater();
  }

  void _forget(bool Function(OpenFile f) test) {
    final gone = _files.where(test).toList();
    if (gone.isEmpty) return;
    setState(() {
      _files.removeWhere(test);
      if (_active >= _files.length) _active = _files.length - 1;
    });
    for (final f in gone) {
      f.disposeLater();
    }
  }

  Future<void> _newFile(String dir) async {
    final name = await prompt(context, 'Новый файл', hint: 'например lib/screens/home.dart');
    if (name == null || name.trim().isEmpty) return;
    final path = '$dir/${name.trim()}';
    try {
      await api.write(path, '');
      await _tree.currentState?.refresh();
      unawaited(_git.refresh());
      await _open(path);
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<void> _newFolder(String dir) async {
    final name = await prompt(context, 'Новая папка');
    if (name == null || name.trim().isEmpty) return;
    try {
      await api.mkdir('$dir/${name.trim()}');
      await _tree.currentState?.refresh();
      unawaited(_git.refresh());
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<void> _entryMenu(FsEntry e) async {
    final dir = e.dir ? e.path : e.path.substring(0, e.path.lastIndexOf('/'));
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold))),
          ListTile(leading: const Icon(Icons.note_add_outlined), title: const Text('Новый файл здесь'), onTap: () => Navigator.pop(ctx, 'file')),
          ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: const Text('Новая папка здесь'), onTap: () => Navigator.pop(ctx, 'folder')),
          ListTile(leading: const Icon(Icons.drive_file_rename_outline), title: const Text('Переименовать'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.terminal), title: const Text('Терминал в этой папке'), onTap: () => Navigator.pop(ctx, 'shell')),
          ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    try {
      switch (choice) {
        case 'file':
          await _newFile(dir);
        case 'folder':
          await _newFolder(dir);
        case 'shell':
          await _newShell(dir);
        case 'rename':
          final n = await prompt(context, 'Переименовать', initial: e.name);
          if (n == null || n.trim().isEmpty || n == e.name) return;
          final to = '${e.path.substring(0, e.path.lastIndexOf('/'))}/${n.trim()}';
          await api.rename(e.path, to);
          setState(() {
            for (final f in _files) {
              if (f.path == e.path || f.path.startsWith('${e.path}/')) {
                f.path = to + f.path.substring(e.path.length);
                f.ctrl.setLanguage(languageForPath(f.path));
              }
            }
          });
          await _tree.currentState?.refresh();
      unawaited(_git.refresh());
        case 'delete':
          final ok = await askChoice(context, 'Удалить ${e.name}${e.dir ? ' со всем содержимым' : ''}?', ['Удалить', 'Отмена']);
          if (ok != 0) return;
          await api.delete(e.path);
          _forget((f) => f.path == e.path || f.path.startsWith('${e.path}/'));
          await _tree.currentState?.refresh();
      unawaited(_git.refresh());
      }
    } catch (err) {
      _snack('Ошибка: $err');
    }
  }

  // ------------------------------------------------------------------ run

  RunTarget? get _resolved {
    final p = _project;
    if (_targetId == 'auto') return p == null ? null : autoTarget(p, _cur?.path);
    return targetById(_targetId);
  }

  String _commandFor(RunTarget t) {
    final raw = t.id == 'custom' ? (st.customCmdByProject[widget.root] ?? '') : t.cmd;
    return expandCmd(raw, root: widget.root, file: _cur?.path, nodeMain: _project?.nodeMain);
  }

  Future<void> _run([RunTarget? override]) async {
    var t = override ?? _resolved;
    if (t == null) {
      await _pickTarget();
      t = _resolved;
      if (t == null) return;
    }
    if (t.id == 'custom' && (st.customCmdByProject[widget.root] ?? '').trim().isEmpty) {
      if (!await _editCustom()) return;
    }
    final missing = missingTools(t, _tools);
    if (missing.isNotEmpty) {
      await _offerInstall(missing.first, t.title);
      return;
    }
    if (t.exts.isNotEmpty && _cur == null) {
      _snack('Открой файл, который нужно запустить');
      return;
    }
    final cmd = _commandFor(t);
    final prev = _runTab;
    if (prev != null && prev.running) {
      final r = await askChoice(context, '«${prev.title}» ещё работает. Остановить и запустить заново?', ['Да', 'Отмена']);
      if (r != 0) return;
    }
    if (prev != null) _hub.close(prev);
    await _saveAll();
    try {
      final tab = await TermTab.start(api, cwd: widget.root, cmd: cmd, title: t.title, isRun: true, hotReload: t.hotReload);
      if (!mounted) {
        tab.dispose();
        return;
      }
      _hub.add(tab);
      setState(() => _panelOpen = true);
      final target = t;
      unawaited(tab.exitCode.addListenerOnce(() {
        if (!mounted) return;
        _tree.currentState?.refresh();
        _git.refresh();
        if (tab.exitCode.value == 0 && (target.id.contains('apk') || target.id == 'gradle_debug')) {
          _snack('APK собран', action: SnackBarAction(label: 'Установить', onPressed: _installApk));
        }
      }));
    } catch (e) {
      _snack('Не удалось запустить: $e');
    }
  }

  Future<void> _offerInstall(String tool, String what) async {
    LangPack? pack;
    for (final p in langPacks) {
      if (p.tool == tool || (tool == 'npm' && p.tool == 'node') || (tool == 'clang++' && p.tool == 'clang') ||
          (tool == 'pip' && p.tool == 'python') || (tool == 'rustc' && p.tool == 'cargo')) {
        pack = p;
        break;
      }
    }
    final r = await askChoice(
      context,
      'Для «$what» нужен $tool, а его нет в Termux.${pack == null ? '' : '\n\nУстановить «${pack.title}»?'}',
      pack == null ? ['OK'] : [pack.install == null ? 'Инструкция' : 'Установить', 'Отмена'],
    );
    if (r != 0 || pack == null || !mounted) return;
    if (pack.install == null) {
      await Native.openUrl(pack.guideUrl!);
      return;
    }
    await runInTerminalPage(context, api, cmd: pack.install!, cwd: widget.root, title: 'Установка: ${pack.title}');
    await _refreshTools();
  }

  Future<bool> _editCustom() async {
    final c = await prompt(
      context,
      'Своя команда',
      initial: st.customCmdByProject[widget.root] ?? (_resolved?.cmd ?? ''),
      hint: 'выполняется в папке проекта; {file} — текущий файл',
      multiline: true,
    );
    if (c == null || c.trim().isEmpty) return false;
    st.customCmdByProject[widget.root] = c;
    st.targetByProject[widget.root] = 'custom';
    await st.save();
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _pickTarget() async {
    final p = _project;
    if (p == null) return;
    var showAll = false;
    final auto = autoTarget(p, _cur?.path);
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final list = showAll ? targets : relevantTargets(p, _cur?.path);
        Widget tile(RunTarget t) {
          final miss = missingTools(t, _tools);
          return ListTile(
            dense: true,
            selected: _targetId == t.id,
            title: Text(t.title),
            subtitle: Text(
              miss.isEmpty ? t.cmd : 'нужно установить: ${miss.join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: miss.isEmpty ? null : Colors.orangeAccent),
            ),
            onTap: () => Navigator.pop(ctx, t.id),
          );
        }

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: .65,
          builder: (_, sc) => ListView(controller: sc, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Проект: ${p.kind.title}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            ListTile(
              selected: _targetId == 'auto',
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Авто (рекомендуется)'),
              subtitle: Text(auto == null ? 'открой файл — подберу по его типу' : auto.title),
              onTap: () => Navigator.pop(ctx, 'auto'),
            ),
            const Divider(height: 1),
            for (final t in list) tile(t),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Своя команда…'),
              subtitle: Text(st.customCmdByProject[widget.root] ?? 'не задана',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
            if (!showAll)
              TextButton(onPressed: () => setSheet(() => showAll = true), child: const Text('Показать все варианты')),
          ]),
        );
      }),
    );
    if (id == null) return;
    if (id == 'custom') {
      await _editCustom();
      return;
    }
    st.targetByProject[widget.root] = id;
    await st.save();
    if (mounted) setState(() {});
  }

  Future<void> _newShell([String? dir]) async {
    try {
      final tab = await TermTab.start(api, cwd: dir ?? widget.root, title: 'bash');
      if (!mounted) {
        tab.dispose();
        return;
      }
      _hub.add(tab);
      setState(() => _panelOpen = true);
      tab.focus.requestFocus();
    } catch (e) {
      _snack('Не удалось открыть терминал: $e');
    }
  }

  /// Runs a command in a new terminal tab (used by Git: push/pull…). Returns the exit code.
  Future<int> _runInPanel(String cmd, String title) async {
    try {
      final tab = await TermTab.start(api, cwd: _git.repoRoot ?? widget.root, cmd: cmd, title: title);
      if (!mounted) {
        tab.dispose();
        return -1;
      }
      _hub.add(tab);
      setState(() => _panelOpen = true);
      if (_scaffold.currentState?.isDrawerOpen ?? false) _scaffold.currentState!.closeDrawer();
      return await tab.session.exitCode;
    } catch (e) {
      _snack('Не удалось запустить: $e');
      return -1;
    }
  }

  Future<void> _installGit() async {
    final pack = langPacks.firstWhere((p) => p.id == 'git');
    await runInTerminalPage(context, api, cmd: pack.install!, cwd: widget.root, title: 'Установка: Git');
    await _refreshTools();
    await _git.refresh();
  }

  Future<void> _openAbs(String path) async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) _scaffold.currentState!.closeDrawer();
    try {
      await _open(path);
    } catch (e) {
      _snack('Ошибка открытия: $e');
    }
  }

  Future<void> _installApk() async {
    const candidates = [
      'build/app/outputs/flutter-apk/app-release.apk',
      'build/app/outputs/flutter-apk/app-debug.apk',
      'app/build/outputs/apk/debug/app-debug.apk',
      'app/build/outputs/apk/release/app-release.apk',
    ];
    try {
      final r = await api.exec('ls -t ${candidates.join(' ')} 2>/dev/null | head -n 1', cwd: widget.root);
      final apk = r.stdout.trim();
      if (apk.isEmpty) {
        _snack('APK не найден — сначала собери проект');
        return;
      }
      if (!await Native.ensureRunCommandPermission()) {
        _snack('Нет разрешения на запуск команд в Termux');
        return;
      }
      await Native.runInTermux('termux-open "$apk"', workdir: widget.root);
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'apk_debug':
        await _run(targetById(_project?.kind == ProjectKind.androidGradle ? 'gradle_debug' : 'flutter_apk_debug'));
      case 'apk_release':
        await _run(targetById('flutter_apk'));
      case 'install':
        await _installApk();
      case 'run_file':
        await _run(fileTarget(_cur?.path));
      case 'shell':
        await _newShell();
      case 'termux':
        if (await Native.ensureRunCommandPermission()) {
          await Native.runInTermux('cd "${widget.root}"', workdir: widget.root);
        }
      case 'ext':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExtensionsPage(api: api)));
        await _refreshTools();
      case 'font+':
        st.fontSize = (st.fontSize + 1).clamp(9.0, 28.0);
        await st.save();
        setState(() {});
      case 'font-':
        st.fontSize = (st.fontSize - 1).clamp(9.0, 28.0);
        await st.save();
        setState(() {});
      case 'close':
        await _tryClose();
    }
  }

  List<PopupMenuEntry<String>> _menuItems() {
    final kind = _project?.kind;
    final ft = fileTarget(_cur?.path);
    final res = _resolved;
    return [
      if (kind == ProjectKind.flutter && _tools.contains('flutter')) ...const <PopupMenuEntry<String>>[
        PopupMenuItem(value: 'apk_debug', child: Text('Собрать APK (debug)')),
        PopupMenuItem(value: 'apk_release', child: Text('Собрать APK (release)')),
      ],
      if (kind == ProjectKind.androidGradle) const PopupMenuItem(value: 'apk_debug', child: Text('Собрать APK (Gradle)')),
      if (kind != null && kind.buildsApk) const PopupMenuItem(value: 'install', child: Text('Установить собранный APK')),
      if (ft != null && ft.id != res?.id) PopupMenuItem(value: 'run_file', child: Text('Запустить ${_cur!.name}')),
      const PopupMenuItem(value: 'shell', child: Text('Новый терминал')),
      const PopupMenuItem(value: 'termux', child: Text('Открыть папку в Termux')),
      const PopupMenuItem(value: 'ext', child: Text('Языки и расширения')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'font+', child: Text('Шрифт крупнее')),
      const PopupMenuItem(value: 'font-', child: Text('Шрифт мельче')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'close', child: Text('Закрыть проект')),
    ];
  }

  Future<void> _tryClose() async {
    if (_closing) return;
    final dirty = _files.where((f) => f.dirty).toList();
    if (dirty.isNotEmpty) {
      final r = await askChoice(context, 'Есть несохранённые файлы (${dirty.length}). Сохранить?',
          ['Сохранить всё', 'Не сохранять', 'Отмена']);
      if (r == null || r == 2) return;
      if (r == 0) await _saveAll();
    }
    if (_hub.tabs.any((t) => t.running)) {
      final r = await askChoice(context, 'Запущенные программы будут остановлены.', ['Закрыть проект', 'Отмена']);
      if (r != 0) return;
    }
    _closing = true;
    try {
      _hub.closeAll();
    } catch (_) {}
    widget.onClose();
  }

  // ------------------------------------------------------------------ UI

  Widget _sidePanel(Widget tree) {
    Widget tab(int i, IconData icon, String label, {int badge = 0}) {
      final on = _side == i;
      return Expanded(
        child: InkWell(
          onTap: () {
            setState(() => _side = i);
            if (i == 1) _git.refresh();
          },
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: on ? Colors.lightBlueAccent : Colors.transparent, width: 2)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 17, color: on ? Colors.white : Colors.white54),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13, color: on ? Colors.white : Colors.white60)),
              if (badge > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFF0E639C), borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ],
            ]),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF1B1B1C),
      child: Column(children: [
        ListenableBuilder(
          listenable: _git,
          builder: (_, __) => Container(
            color: const Color(0xFF202021),
            child: Row(children: [
              tab(0, Icons.folder_copy_outlined, 'Файлы'),
              tab(1, Icons.account_tree_outlined, 'Git', badge: _git.count),
            ]),
          ),
        ),
        Expanded(
          child: IndexedStack(index: _side, children: [
            tree,
            GitPanel(
              git: _git,
              home: _home,
              onOpenFile: _openAbs,
              onRunInTerminal: _runInPanel,
              onInstallGit: _installGit,
            ),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Tablet / big window: file tree on the left. Phone (also in landscape): drawer.
    final wide = size.width >= 840 && size.height >= 500;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compactBar = keyboard && size.height < 500;
    final res = _resolved;
    final runTab = _runTab;
    final termFull = _panelOpen && (_panelMax || (keyboard && _termFocused && !wide));

    final tree = FileTree(
      key: _tree,
      api: api,
      root: widget.root,
      activePath: _cur?.path,
      onOpen: _openFromTree,
      onMenu: _entryMenu,
      onNewFile: _newFile,
      onNewFolder: _newFolder,
      colorFor: _git.colorFor,
      decorations: _git,
    );

    final panel = TerminalPanel(
      hub: _hub,
      fontSize: st.fontSize,
      maximized: _panelMax,
      onNewShell: () => _newShell(),
      onHide: () => setState(() {
        _panelOpen = false;
        _panelMax = false;
      }),
      onToggleMax: () => setState(() => _panelMax = !_panelMax),
    );

    final editorArea = Column(children: [
      if (_files.isNotEmpty) _tabs(),
      Expanded(
        child: _cur == null
            ? _empty(wide)
            : CodeEditor(
                key: ValueKey(_cur!.path),
                controller: _cur!.ctrl,
                undo: _cur!.undo,
                focusNode: _cur!.focus,
                fontSize: st.fontSize,
                onSave: _saveCurrent,
              ),
      ),
      if (_cur != null && _editorFocused && (keyboard || !wide))
        ExtraKeysBar(controller: _cur!.ctrl, undo: _cur!.undo, onSave: _saveCurrent),
    ]);

    // The widget tree here never changes shape when the keyboard opens/closes (only sizes do).
    // Re-creating the terminal would drop its keyboard connection, and the keyboard would close.
    final main = LayoutBuilder(builder: (context, box) {
      final maxH = box.maxHeight;
      final handleH = _panelOpen && !termFull ? 12.0 : 0.0;
      final double panelH = !_panelOpen
          ? 0.0
          : termFull
              ? maxH
              : _panelH.clamp(math.min(120.0, maxH), math.max(120.0, maxH - handleH - 90)).toDouble();
      return Column(children: [
        Expanded(child: Offstage(offstage: termFull, child: editorArea)),
        SizedBox(
          height: handleH,
          child: handleH == 0
              ? null
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) =>
                      setState(() => _panelH = (_panelH - d.delta.dy).clamp(120.0, math.max(120.0, maxH - 90)).toDouble()),
                  child: Container(
                    color: const Color(0xFF2D2D2D),
                    alignment: Alignment.center,
                    child: Container(width: 44, height: 3, color: Colors.white24),
                  ),
                ),
        ),
        SizedBox(height: panelH, child: _panelOpen ? panel : null),
      ]);
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_scaffold.currentState?.isDrawerOpen ?? false) {
          _scaffold.currentState!.closeDrawer();
          return;
        }
        if (_panelMax) {
          setState(() => _panelMax = false);
          return;
        }
        _tryClose();
      },
      child: Scaffold(
        key: _scaffold,
        backgroundColor: CodeTheme.bg,
        drawer: wide
            ? null
            : Drawer(
                width: math.min(340.0, size.width * .85),
                child: SafeArea(
                  child: Column(children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_back),
                      title: const Text('К проектам'),
                      onTap: () {
                        _scaffold.currentState?.closeDrawer();
                        _tryClose();
                      },
                    ),
                    Expanded(child: _sidePanel(tree)),
                  ]),
                ),
              ),
        appBar: AppBar(
          toolbarHeight: compactBar ? 44 : 48,
          backgroundColor: const Color(0xFF2D2D2D),
          titleSpacing: 0,
          leading: wide ? IconButton(tooltip: 'К проектам', onPressed: _tryClose, icon: const Icon(Icons.arrow_back)) : null,
          title: Text(widget.root.split('/').last, style: const TextStyle(fontSize: 16)),
          actions: [
            if (_running && runTab!.hotReload) ...[
              IconButton(tooltip: 'Hot reload (r)', onPressed: () => runTab.type('r'), icon: const Icon(Icons.bolt, color: Colors.amber)),
              IconButton(tooltip: 'Hot restart (R)', onPressed: () => runTab.type('R'), icon: const Icon(Icons.restart_alt)),
            ],
            if (_running)
              IconButton(tooltip: 'Стоп', onPressed: runTab!.stop, icon: const Icon(Icons.stop, color: Colors.redAccent))
            else
              IconButton(tooltip: 'Запуск', onPressed: _run, icon: const Icon(Icons.play_arrow, color: Colors.greenAccent)),
            IconButton(
              tooltip: 'Терминал',
              onPressed: () {
                if (_hub.tabs.isEmpty) {
                  _newShell();
                } else {
                  setState(() => _panelOpen = !_panelOpen);
                }
              },
              icon: Icon(Icons.terminal, color: _panelOpen ? Colors.lightBlueAccent : null),
            ),
            PopupMenuButton<String>(onSelected: _menu, itemBuilder: (_) => _menuItems()),
          ],
          bottom: compactBar ? null : PreferredSize(
            preferredSize: const Size.fromHeight(34),
            child: InkWell(
              onTap: _pickTarget,
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                color: const Color(0xFF252526),
                child: Row(children: [
                  Icon(_targetId == 'auto' ? Icons.auto_awesome : Icons.tune, size: 15, color: Colors.white54),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      res == null
                          ? (_project == null ? 'Определяю проект…' : 'Выбери, как запускать')
                          : '${_targetId == 'auto' ? 'Авто · ' : ''}${res.title}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (res != null)
                    Expanded(
                      child: Text(
                        missingTools(res, _tools).isEmpty ? _commandFor(res) : 'нет: ${missingTools(res, _tools).join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: missingTools(res, _tools).isEmpty ? Colors.white38 : Colors.orangeAccent,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  ListenableBuilder(
                    listenable: _git,
                    builder: (_, __) => _git.isRepo
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.call_split, size: 14, color: Colors.white54),
                              Text(' ${_git.status.branch}${_git.count > 0 ? '*' : ''}',
                                  style: const TextStyle(fontSize: 12, color: Colors.white60)),
                            ]),
                          )
                        : const SizedBox(),
                  ),
                  const Icon(Icons.arrow_drop_down, color: Colors.white54),
                ]),
              ),
            ),
          ),
        ),
        // Keep content above the system navigation bar and away from cutouts (edge-to-edge).
        body: SafeArea(
          top: false,
          child: wide
              ? Row(children: [
                  SizedBox(width: 290, child: _sidePanel(tree)),
                  const VerticalDivider(width: 1, color: Color(0xFF333333)),
                  Expanded(child: main),
                ])
              : main,
        ),
      ),
    );
  }

  Widget _tabs() {
    return Container(
      height: 38,
      color: const Color(0xFF252526),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _files.length,
        itemBuilder: (_, i) {
          final f = _files[i];
          final active = i == _active;
          return ListenableBuilder(
            listenable: f.ctrl,
            builder: (_, __) => InkWell(
              onTap: () => setState(() => _active = i),
              child: Container(
                padding: const EdgeInsets.only(left: 12, right: 4),
                decoration: BoxDecoration(
                  color: active ? CodeTheme.bg : Colors.transparent,
                  border: Border(top: BorderSide(color: active ? Colors.lightBlueAccent : Colors.transparent, width: 2)),
                ),
                child: Row(children: [
                  Text(f.name, style: TextStyle(fontSize: 13, color: active ? Colors.white : Colors.white60)),
                  if (f.dirty) const Text(' ●', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    onPressed: () => _closeTab(i),
                    icon: const Icon(Icons.close),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(bool wide) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.code, size: 56, color: Colors.white24),
        const SizedBox(height: 12),
        const Text('Открой файл из дерева проекта', style: TextStyle(color: Colors.white54)),
        if (!wide) ...[
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => _scaffold.currentState?.openDrawer(),
            icon: const Icon(Icons.folder_open),
            label: const Text('Файлы'),
          ),
        ],
      ]),
    );
  }
}

extension _Once on ValueNotifier<int?> {
  /// Completes when the value becomes non-null, running [f] once.
  Future<void> addListenerOnce(VoidCallback f) {
    final c = Completer<void>();
    void l() {
      if (value != null) {
        removeListener(l);
        f();
        if (!c.isCompleted) c.complete();
      }
    }

    addListener(l);
    return c.future;
  }
}
