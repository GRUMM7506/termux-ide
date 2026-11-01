import 'package:flutter/material.dart';

import 'api.dart';
import 'dialogs.dart';
import 'extensions.dart';
import 'native.dart';
import 'server_manager.dart';
import 'settings.dart';
import 'templates.dart';
import 'terminal_panel.dart';

class ProjectsPage extends StatefulWidget {
  final Api api;
  final Settings settings;
  final List<String> tools;
  final void Function(String path) onOpen;
  final VoidCallback onShowGuide;
  final VoidCallback onToolsChanged;

  const ProjectsPage({
    super.key,
    required this.api,
    required this.settings,
    required this.tools,
    required this.onOpen,
    required this.onShowGuide,
    required this.onToolsChanged,
  });

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  static const home = ServerManager.termuxHome;

  Future<void> _newProject() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _NewProjectDialog(api: widget.api, tools: widget.tools),
    );
    if (path != null) widget.onOpen(path);
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.settings;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/branding/logo.png', width: 28, height: 28),
          const SizedBox(width: 10),
          const Text('Termux IDE'),
        ]),
        actions: [
          IconButton(tooltip: 'Как пользоваться', onPressed: widget.onShowGuide, icon: const Icon(Icons.help_outline)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          FilledButton.icon(onPressed: _newProject, icon: const Icon(Icons.add), label: const Text('Новый проект')),
          OutlinedButton.icon(
            onPressed: () async {
              final p = await pickFolder(context, widget.api, home);
              if (p != null) widget.onOpen(p);
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('Открыть папку'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExtensionsPage(api: widget.api)));
              widget.onToolsChanged();
            },
            icon: const Icon(Icons.extension_outlined),
            label: const Text('Языки и расширения'),
          ),
          OutlinedButton.icon(
            onPressed: () => runInTerminalPage(context, widget.api, cmd: '', cwd: home, title: 'Терминал'),
            icon: const Icon(Icons.terminal),
            label: const Text('Терминал'),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          const Icon(Icons.circle, size: 10, color: Colors.greenAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.tools.isEmpty ? 'Termux подключён' : 'Termux подключён · ${widget.tools.join(', ')}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        const Text('Недавние', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (st.recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('Пока пусто — создай первый проект.', style: TextStyle(color: Colors.white54)),
          ),
        for (final r in st.recent)
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder, color: Color(0xFFDCB67A)),
              title: Text(r.split('/').last),
              subtitle: Text(r.replaceFirst(home, '~'), style: const TextStyle(fontSize: 12)),
              onTap: () => widget.onOpen(r),
              trailing: IconButton(
                tooltip: 'Убрать из списка',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  setState(() => st.recent.remove(r));
                  st.save();
                },
              ),
            ),
          ),
      ]),
    );
  }
}

class _NewProjectDialog extends StatefulWidget {
  final Api api;
  final List<String> tools;
  const _NewProjectDialog({required this.api, required this.tools});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  late List<String> tools = widget.tools;
  late ProjectTemplate tpl = templates.firstWhere(
    (t) => t.needs == null || tools.contains(t.needs),
    orElse: () => templates.last,
  );
  final name = TextEditingController(text: 'hello');
  String parent = '${ServerManager.termuxHome}/projects';
  bool busy = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  LangPack? get _pack {
    for (final p in langPacks) {
      if (p.tool == tpl.needs) return p;
    }
    return null;
  }

  bool get _ready => tpl.needs == null || tools.contains(tpl.needs);

  Future<void> _installNeeded() async {
    final p = _pack;
    if (p == null) return;
    if (p.install == null) {
      await Native.openUrl(p.guideUrl!);
      return;
    }
    await runInTerminalPage(context, widget.api, cmd: p.install!, cwd: ServerManager.termuxHome, title: 'Установка: ${p.title}');
    try {
      final t = (await widget.api.info(refresh: true)).tools;
      if (mounted) setState(() => tools = t);
    } catch (_) {}
  }

  Future<void> _create() async {
    final n = name.text.trim();
    if (n.isEmpty) return;
    if (tpl.strictName && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(n)) {
      setState(() => error = 'Имя: только a-z, 0-9 и _, начинается с буквы');
      return;
    }
    final dir = '$parent/$n';
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (await widget.api.exists(dir)) {
        setState(() {
          busy = false;
          error = 'Папка $n уже существует';
        });
        return;
      }
      await widget.api.mkdir(parent);
      if (tpl.cmd != null) {
        final pkg = 'com.example.${n.replaceAll(RegExp(r'[^a-z0-9_]'), '')}';
        final cmd = tpl.cmd!.replaceAll('{name}', n).replaceAll('{pkg}', pkg);
        if (!mounted) return;
        final code = await runInTerminalPage(context, widget.api, cmd: cmd, cwd: parent, title: 'Создание: ${tpl.title}');
        if (code != 0) {
          setState(() {
            busy = false;
            error = code == null ? 'Создание прервано' : 'Команда завершилась с кодом $code';
          });
          return;
        }
      } else {
        await widget.api.mkdir(dir);
      }
      for (final f in tpl.files.entries) {
        await widget.api.write('$dir/${f.key.replaceAll('{name}', n)}', f.value.replaceAll('{name}', n));
      }
      if (mounted) Navigator.pop(context, dir);
    } catch (e) {
      setState(() {
        busy = false;
        error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый проект'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<ProjectTemplate>(
              initialValue: tpl,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Язык / тип'),
              items: [
                for (final t in templates)
                  DropdownMenuItem(
                    value: t,
                    child: Text(
                      t.needs == null || tools.contains(t.needs) ? t.title : '${t.title}  (нужно установить)',
                      style: TextStyle(color: t.needs == null || tools.contains(t.needs) ? null : Colors.white38),
                    ),
                  ),
              ],
              onChanged: busy ? null : (t) => setState(() => tpl = t!),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: name,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Имя проекта'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text('Папка: ${parent.replaceFirst(ServerManager.termuxHome, '~')}',
                    style: const TextStyle(fontSize: 12, color: Colors.white60)),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final p = await pickFolder(context, widget.api, ServerManager.termuxHome);
                        if (p != null) setState(() => parent = p);
                      },
                child: const Text('Изменить'),
              ),
            ]),
            if (!_ready)
              Card(
                color: const Color(0xFF3A2E12),
                child: ListTile(
                  leading: const Icon(Icons.info_outline, color: Colors.orangeAccent),
                  title: Text('Нужен ${_pack?.title ?? tpl.needs}'),
                  trailing: FilledButton.tonal(
                    onPressed: busy ? null : _installNeeded,
                    child: Text(_pack?.install == null ? 'Инструкция' : 'Установить'),
                  ),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: busy || !_ready ? null : _create, child: const Text('Создать')),
      ],
    );
  }
}
