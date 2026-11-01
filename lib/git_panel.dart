import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dialogs.dart';
import 'git.dart';
import 'native.dart';

typedef RunInTerminal = Future<int> Function(String cmd, String title);

/// Source Control view (like VS Code).
class GitPanel extends StatefulWidget {
  final GitController git;
  final String home;
  final void Function(String absPath) onOpenFile;
  final RunInTerminal onRunInTerminal;
  final VoidCallback onInstallGit;

  const GitPanel({
    super.key,
    required this.git,
    required this.home,
    required this.onOpenFile,
    required this.onRunInTerminal,
    required this.onInstallGit,
  });

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final _msg = TextEditingController();
  bool _busy = false;

  GitController get git => widget.git;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));
  }

  /// Runs a quick git operation with error reporting and refresh.
  Future<void> _op(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _snack('$e');
    }
    await git.refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remote(String cmd, String title) async {
    await widget.onRunInTerminal(cmd, title);
    await git.refresh();
  }

  // ---------------------------------------------------------------- commit

  Future<bool> _ensureIdentity() async {
    final id = await git.identity();
    if (id.name.isNotEmpty && id.email.isNotEmpty) return true;
    if (!mounted) return false;
    final name = TextEditingController(text: id.name);
    final email = TextEditingController(text: id.email);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Кто автор коммитов?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Git записывает имя и почту в каждый коммит. Укажи их один раз.',
              style: TextStyle(color: Colors.white60)),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Имя')),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Почта (как на GitHub)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty || email.text.trim().isEmpty) return false;
    await git.setIdentity(name.text.trim(), email.text.trim());
    return true;
  }

  Future<void> _commit({bool andPush = false}) async {
    final msg = _msg.text.trim();
    if (msg.isEmpty) {
      _snack('Напиши сообщение коммита');
      return;
    }
    if (git.status.staged.isEmpty) {
      if (git.status.changes.isEmpty) {
        _snack('Нечего коммитить');
        return;
      }
      final r = await askChoice(context, 'Нет подготовленных изменений. Подготовить все изменения и закоммитить?',
          ['Да, все', 'Отмена']);
      if (r != 0) return;
      await git.stageAll();
    }
    if (!await _ensureIdentity()) return;
    var ok = false;
    await _op(() async {
      await git.commit(msg, widget.home);
      ok = true;
    });
    if (!ok) return;
    _msg.clear();
    _snack('Коммит создан');
    if (andPush) await _push();
  }

  // ---------------------------------------------------------------- remote

  Future<bool> _ensureRemote() async {
    if (git.remotes.isNotEmpty) return true;
    final url = await prompt(context, 'Куда отправлять? (remote origin)',
        hint: 'https://github.com/USER/REPO.git');
    if (url == null || url.trim().isEmpty) return false;
    var ok = false;
    await _op(() async {
      await git.addRemote(url.trim());
      ok = true;
    });
    return ok;
  }

  Future<void> _push() async {
    if (!await _ensureRemote()) return;
    await _remote(git.pushCmd(), 'git push');
  }

  Future<void> _githubLogin() async {
    final user = TextEditingController();
    final token = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Вход в GitHub'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'Для push по HTTPS GitHub просит токен вместо пароля. Создай токен с правом «repo» и вставь его сюда. '
              'Он сохранится в ~/.git-credentials внутри Termux.',
              style: TextStyle(color: Colors.white60),
            ),
            TextButton.icon(
              onPressed: () => Native.openUrl(
                  'https://github.com/settings/tokens/new?scopes=repo,workflow&description=Termux%20IDE'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Создать токен на GitHub'),
            ),
            TextField(controller: user, decoration: const InputDecoration(labelText: 'Логин GitHub')),
            TextField(
              controller: token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Токен (ghp_…)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true || user.text.trim().isEmpty || token.text.trim().isEmpty) return;
    await _op(() => git.saveGithubToken(widget.home, user.text.trim(), token.text.trim()));
    _snack('Токен сохранён');
  }

  Future<void> _branches() async {
    final list = await git.branches();
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        builder: (_, sc) => ListView(controller: sc, children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Новая ветка…'),
            onTap: () => Navigator.pop(ctx, '\u0000new'),
          ),
          const Divider(height: 1),
          for (final b in list)
            ListTile(
              dense: true,
              leading: Icon(
                b == git.status.branch ? Icons.check : (b.contains('/') ? Icons.cloud_outlined : Icons.call_split),
                size: 18,
              ),
              title: Text(b),
              selected: b == git.status.branch,
              onTap: () => Navigator.pop(ctx, b),
            ),
        ]),
      ),
    );
    if (choice == null || choice == git.status.branch) return;
    if (choice == '\u0000new') {
      final name = await prompt(context, 'Новая ветка', hint: 'feature/login');
      if (name == null || name.trim().isEmpty) return;
      await _op(() => git.createBranch(name.trim()));
      return;
    }
    await _op(() => git.checkout(choice));
  }

  Future<void> _more(String v) async {
    switch (v) {
      case 'pull':
        await _remote('git pull', 'git pull');
      case 'push':
        await _push();
      case 'sync':
        if (!await _ensureRemote()) return;
        await _remote('git pull && ${git.pushCmd()}', 'git sync');
      case 'fetch':
        await _remote('git fetch --all --prune', 'git fetch');
      case 'branch':
        await _branches();
      case 'log':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => GitLogPage(git: git)));
      case 'stash':
        await _op(() => git.must('stash push -u').then((_) {}));
      case 'stash_pop':
        await _op(() => git.must('stash pop').then((_) {}));
      case 'remote':
        final url = await prompt(context, 'URL удалённого репозитория (origin)', hint: 'https://github.com/USER/REPO.git');
        if (url == null || url.trim().isEmpty) return;
        await _op(() async {
          if (git.remotes.contains('origin')) {
            await git.must('remote set-url origin ${shq(url.trim())}');
          } else {
            await git.addRemote(url.trim());
          }
        });
      case 'login':
        await _githubLogin();
    }
  }

  Future<void> _openDiff(GitChange c) async {
    final text = await git.diff(c);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DiffPage(
        title: c.name,
        subtitle: '${c.staged ? 'подготовлено' : 'изменения'} · ${c.path}',
        diff: text,
        actions: [
          IconButton(
            tooltip: 'Открыть файл',
            onPressed: () {
              Navigator.pop(context);
              widget.onOpenFile(git.abs(c));
            },
            icon: const Icon(Icons.description_outlined),
          ),
          IconButton(
            tooltip: c.staged ? 'Убрать из подготовленных' : 'Подготовить',
            onPressed: () {
              Navigator.pop(context);
              _op(() => c.staged ? git.unstage(c) : git.stage(c));
            },
            icon: Icon(c.staged ? Icons.remove : Icons.add),
          ),
        ],
      ),
    ));
  }

  Future<void> _discard(GitChange c) async {
    final r = await askChoice(
      context,
      c.kind == GitKind.untracked
          ? 'Удалить новый файл ${c.name}? Это нельзя отменить.'
          : 'Отменить изменения в ${c.name}? Это нельзя отменить.',
      ['Отменить изменения', 'Нет'],
    );
    if (r == 0) await _op(() => git.discard(c));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: git,
      builder: (context, _) {
        return Container(
          color: const Color(0xFF1B1B1C),
          child: Column(children: [
            _header(),
            if (git.loading || _busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _body()),
          ]),
        );
      },
    );
  }

  Widget _header() {
    final st = git.status;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12),
      color: const Color(0xFF252526),
      child: Row(children: [
        const Text('GIT', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .5)),
        const SizedBox(width: 8),
        if (git.isRepo)
          Expanded(
            child: InkWell(
              onTap: _branches,
              child: Row(children: [
                const Icon(Icons.call_split, size: 15, color: Colors.white60),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(st.branch, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                ),
                if (st.ahead > 0 || st.behind > 0)
                  Text('  ↑${st.ahead} ↓${st.behind}', style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
              ]),
            ),
          )
        else
          const Spacer(),
        IconButton(
          tooltip: 'Обновить',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: git.refresh,
          icon: const Icon(Icons.refresh),
        ),
        if (git.isRepo)
          PopupMenuButton<String>(
            iconSize: 20,
            onSelected: _more,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pull', child: Text('Pull')),
              PopupMenuItem(value: 'push', child: Text('Push')),
              PopupMenuItem(value: 'sync', child: Text('Синхронизировать (pull + push)')),
              PopupMenuItem(value: 'fetch', child: Text('Fetch')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'branch', child: Text('Ветки…')),
              PopupMenuItem(value: 'log', child: Text('История коммитов')),
              PopupMenuItem(value: 'stash', child: Text('Stash: спрятать изменения')),
              PopupMenuItem(value: 'stash_pop', child: Text('Stash: вернуть')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'remote', child: Text('Remote origin…')),
              PopupMenuItem(value: 'login', child: Text('Вход в GitHub (токен)…')),
            ],
          ),
      ]),
    );
  }

  Widget _body() {
    if (git.hasGit == null) return const SizedBox();
    if (git.hasGit == false) {
      return _empty(Icons.download, 'Git не установлен в Termux.', 'Установить Git', widget.onInstallGit);
    }
    if (!git.isRepo) {
      return _empty(Icons.account_tree_outlined, 'Эта папка — не Git-репозиторий.', 'Инициализировать репозиторий',
          () => _op(git.init));
    }
    final st = git.status;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: CallbackShortcutsCommit(
          onCommit: _commit,
          child: TextField(
            controller: _msg,
            minLines: 1,
            maxLines: 5,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: 'Сообщение коммита (в ветку ${st.branch})',
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _commit,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Коммит'),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            onSelected: (v) => v == 'cp' ? _commit(andPush: true) : _more(v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cp', child: Text('Коммит и Push')),
              PopupMenuItem(value: 'sync', child: Text('Синхронизировать')),
            ],
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.arrow_drop_down)),
          ),
        ]),
      ),
      if (st.ahead > 0 || (st.upstream == null && st.hasCommits && st.staged.isEmpty && st.changes.isEmpty))
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: OutlinedButton.icon(
            onPressed: _push,
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: Text(st.upstream == null ? 'Опубликовать ветку' : 'Push ↑${st.ahead}'),
          ),
        ),
      if (st.behind > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: OutlinedButton.icon(
            onPressed: () => _remote('git pull', 'git pull'),
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: Text('Pull ↓${st.behind}'),
          ),
        ),
      const SizedBox(height: 8),
      if (st.staged.isNotEmpty) ...[
        _section('Подготовленные', st.staged.length,
            IconButton(tooltip: 'Убрать все', iconSize: 18, visualDensity: VisualDensity.compact,
                onPressed: () => _op(git.unstageAll), icon: const Icon(Icons.remove))),
        for (final c in st.staged) _row(c),
      ],
      _section('Изменения', st.changes.length,
          st.changes.isEmpty
              ? null
              : IconButton(tooltip: 'Подготовить все', iconSize: 18, visualDensity: VisualDensity.compact,
                  onPressed: () => _op(git.stageAll), icon: const Icon(Icons.add))),
      if (st.changes.isEmpty && st.staged.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Изменений нет', style: TextStyle(color: Colors.white38)),
        ),
      for (final c in st.changes) _row(c),
      if (git.error != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(git.error!, style: const TextStyle(color: Colors.redAccent))),
    ]);
  }

  Widget _empty(IconData icon, String text, String button, VoidCallback onTap) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: Colors.white24),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: _busy ? null : onTap, child: Text(button)),
        ]),
      ),
    );
  }

  Widget _section(String title, int n, Widget? action) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 2),
      child: Row(children: [
        Expanded(
          child: Text('${title.toUpperCase()}  $n',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white60)),
        ),
        if (action != null) action,
      ]),
    );
  }

  Widget _row(GitChange c) {
    return InkWell(
      onTap: () => _openDiff(c),
      onLongPress: () => widget.onOpenFile(git.abs(c)),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 2),
        child: Row(children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: c.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: c.kind.color,
                    decoration: c.kind == GitKind.deleted ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (c.dir.isNotEmpty)
                  TextSpan(text: '  ${c.dir}', style: const TextStyle(fontSize: 11.5, color: Colors.white38)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!c.staged)
            IconButton(
              tooltip: 'Отменить изменения',
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              onPressed: () => _discard(c),
              icon: const Icon(Icons.undo),
            ),
          IconButton(
            tooltip: c.staged ? 'Убрать из подготовленных' : 'Подготовить',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () => _op(() => c.staged ? git.unstage(c) : git.stage(c)),
            icon: Icon(c.staged ? Icons.remove : Icons.add),
          ),
          SizedBox(
            width: 18,
            child: Text(c.kind.letter,
                style: TextStyle(color: c.kind.color, fontWeight: FontWeight.bold, fontSize: 12.5)),
          ),
        ]),
      ),
    );
  }
}

/// Ctrl+Enter in the commit box = commit.
class CallbackShortcutsCommit extends StatelessWidget {
  final VoidCallback onCommit;
  final Widget child;
  const CallbackShortcutsCommit({super.key, required this.onCommit, required this.child});

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): onCommit},
      child: child,
    );
  }
}

/// Unified diff viewer.
class DiffPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final String diff;
  final List<Widget> actions;
  const DiffPage({super.key, required this.title, required this.subtitle, required this.diff, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    var lines = diff.split('\n');
    final cut = lines.length > 6000;
    if (cut) lines = lines.sublist(0, 6000);
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16)),
          Text(subtitle, style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
        ]),
        actions: actions,
      ),
      body: SafeArea(
        top: false,
        child: diff.trim().isEmpty
            ? const Center(child: Text('Нет изменений для показа', style: TextStyle(color: Colors.white54)))
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 1400,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: lines.length + (cut ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == lines.length) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('… diff слишком большой, показано начало'),
                        );
                      }
                      final l = lines[i];
                      Color? bg;
                      var fg = const Color(0xFFD4D4D4);
                      if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ')) {
                        fg = Colors.white54;
                      } else if (l.startsWith('+')) {
                        bg = const Color(0x332EA043);
                        fg = const Color(0xFF9CDCAA);
                      } else if (l.startsWith('-')) {
                        bg = const Color(0x33F85149);
                        fg = const Color(0xFFF4A3A0);
                      } else if (l.startsWith('@@')) {
                        fg = const Color(0xFF4FC1FF);
                      }
                      return Container(
                        color: bg,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(l,
                            softWrap: false,
                            style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35, color: fg)),
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class GitLogPage extends StatefulWidget {
  final GitController git;
  const GitLogPage({super.key, required this.git});

  @override
  State<GitLogPage> createState() => _GitLogPageState();
}

class _GitLogPageState extends State<GitLogPage> {
  List<GitCommit>? commits;

  @override
  void initState() {
    super.initState();
    widget.git.log().then((c) {
      if (mounted) setState(() => commits = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = commits;
    return Scaffold(
      appBar: AppBar(title: const Text('История коммитов')),
      body: SafeArea(
        top: false,
        child: c == null
            ? const Center(child: CircularProgressIndicator())
            : c.isEmpty
                ? const Center(child: Text('Коммитов пока нет'))
                : ListView.separated(
                    itemCount: c.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final k = c[i];
                      return ListTile(
                        dense: true,
                        title: Text(k.subject, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${k.hash} · ${k.author} · ${k.date}${k.refs.isEmpty ? '' : ' · ${k.refs}'}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onTap: () async {
                          final text = await widget.git.show(k.hash);
                          if (!context.mounted) return;
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => DiffPage(title: k.subject, subtitle: '${k.hash} · ${k.author}', diff: text),
                          ));
                        },
                      );
                    },
                  ),
      ),
    );
  }
}
