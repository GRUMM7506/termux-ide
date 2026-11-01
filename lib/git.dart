import 'package:flutter/material.dart';

import 'api.dart';

/// Single-quotes a string for bash.
String shq(String s) => "'${s.replaceAll("'", r"'\''")}'";

enum GitKind { modified, added, deleted, renamed, copied, typeChange, untracked, conflict }

extension GitKindX on GitKind {
  String get letter => switch (this) {
        GitKind.modified => 'M',
        GitKind.added => 'A',
        GitKind.deleted => 'D',
        GitKind.renamed => 'R',
        GitKind.copied => 'C',
        GitKind.typeChange => 'T',
        GitKind.untracked => 'U',
        GitKind.conflict => '!',
      };

  Color get color => switch (this) {
        GitKind.modified || GitKind.typeChange => const Color(0xFFE2C08D),
        GitKind.added || GitKind.untracked || GitKind.copied => const Color(0xFF73C991),
        GitKind.deleted => const Color(0xFFF14C4C),
        GitKind.renamed => const Color(0xFF4FC1FF),
        GitKind.conflict => const Color(0xFFE4676B),
      };
}

GitKind _kind(String c) => switch (c) {
      'A' => GitKind.added,
      'D' => GitKind.deleted,
      'R' => GitKind.renamed,
      'C' => GitKind.copied,
      'T' => GitKind.typeChange,
      _ => GitKind.modified,
    };

class GitChange {
  /// Path relative to the repository root.
  final String path;
  final String? origPath;
  final GitKind kind;
  final bool staged;
  const GitChange(this.path, this.kind, {this.staged = false, this.origPath});

  String get name => path.split('/').last;
  String get dir => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

class GitCommit {
  final String hash;
  final String author;
  final String date;
  final String subject;
  final String refs;
  const GitCommit(this.hash, this.author, this.date, this.subject, this.refs);
}

/// Parsed `git status --porcelain=v2 --branch -z`.
class GitStatus {
  String branch = '';
  String? upstream;
  int ahead = 0;
  int behind = 0;
  bool hasCommits = true;
  final List<GitChange> staged = [];
  final List<GitChange> changes = [];

  static GitStatus parse(String out) {
    final s = GitStatus();
    final parts = out.split('\x00');
    for (var i = 0; i < parts.length; i++) {
      final e = parts[i];
      if (e.isEmpty) continue;
      if (e.startsWith('# ')) {
        final h = e.substring(2);
        if (h.startsWith('branch.head ')) s.branch = h.substring(12);
        if (h.startsWith('branch.upstream ')) s.upstream = h.substring(16);
        if (h.startsWith('branch.oid ')) s.hasCommits = h.substring(11) != '(initial)';
        if (h.startsWith('branch.ab ')) {
          final ab = h.substring(10).split(' ');
          s.ahead = int.tryParse(ab[0].replaceAll('+', '')) ?? 0;
          s.behind = int.tryParse(ab.length > 1 ? ab[1].replaceAll('-', '') : '0') ?? 0;
        }
        continue;
      }
      final f = e.split(' ');
      switch (e[0]) {
        case '1':
          _add(s, f[1], f.sublist(8).join(' '));
        case '2':
          final orig = i + 1 < parts.length ? parts[++i] : null;
          _add(s, f[1], f.sublist(9).join(' '), orig: orig);
        case 'u':
          s.changes.add(GitChange(f.sublist(10).join(' '), GitKind.conflict));
        case '?':
          s.changes.add(GitChange(e.substring(2), GitKind.untracked));
      }
    }
    return s;
  }

  static void _add(GitStatus s, String xy, String path, {String? orig}) {
    final x = xy[0], y = xy[1];
    if (x != '.') s.staged.add(GitChange(path, _kind(x), staged: true, origPath: orig));
    if (y != '.') s.changes.add(GitChange(path, _kind(y), origPath: orig));
  }
}

/// Git state of one project, shared by the Git panel and the file tree.
class GitController extends ChangeNotifier {
  final Api api;
  final String root;
  GitController(this.api, this.root);

  bool loading = false;
  bool? hasGit;
  bool isRepo = false;
  String? repoRoot;
  String? error;
  GitStatus status = GitStatus();
  List<String> remotes = [];

  /// abs path -> kind (for file tree colors)
  Map<String, GitKind> _marks = {};

  int get count => status.staged.length + status.changes.length;

  Future<ExecResult> run(String args, {int timeout = 60}) =>
      api.exec('git $args', cwd: repoRoot ?? root, timeout: timeout);

  /// Like [run] but throws with git's message on failure.
  Future<String> must(String args) async {
    final r = await run(args);
    if (r.code != 0) throw ApiException((r.stderr.trim().isEmpty ? r.stdout : r.stderr).trim());
    return r.stdout;
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    try {
      // --show-prefix (not --show-toplevel): keeps our path spelling (/data/data/… vs /data/user/0/…).
      final probe = await api.exec(
        'command -v git >/dev/null || { echo NOGIT; exit 0; }; '
        'p=\$(git rev-parse --show-prefix 2>/dev/null) && echo "P:\$p" || echo NOREPO',
        cwd: root,
      );
      final o = probe.stdout.trim();
      hasGit = o != 'NOGIT';
      isRepo = hasGit! && o.startsWith('P:');
      if (isRepo) {
        final prefix = o.substring(2);
        repoRoot = prefix.isEmpty ? root : root.substring(0, root.length - prefix.length).replaceAll(RegExp(r'/+$'), '');
      } else {
        repoRoot = null;
      }
      if (isRepo) {
        final st = await run('status --porcelain=v2 --branch -z --untracked-files=all');
        status = GitStatus.parse(st.stdout);
        remotes = (await run('remote')).stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();
      } else {
        status = GitStatus();
        remotes = [];
      }
      _marks = {
        for (final c in status.staged) '$repoRoot/${c.path}': c.kind,
        for (final c in status.changes) '$repoRoot/${c.path}': c.kind,
      };
      error = null;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  /// Color for a file-tree entry, or null if unchanged.
  Color? colorFor(String path, bool dir) {
    final k = _marks[path];
    if (k != null) return k.color;
    if (dir) {
      final prefix = '$path/';
      for (final p in _marks.keys) {
        if (p.startsWith(prefix)) return const Color(0xFFE2C08D).withValues(alpha: .75);
      }
    }
    return null;
  }

  String abs(GitChange c) => '$repoRoot/${c.path}';

  Future<void> stage(GitChange c) => must('add -A -- ${shq(c.path)}');
  Future<void> stageAll() => must('add -A');

  Future<void> unstage(GitChange c) =>
      status.hasCommits ? must('restore --staged -- ${shq(c.path)}') : must('rm --cached -q -- ${shq(c.path)}');

  Future<void> unstageAll() => status.hasCommits ? must('reset -q') : must('rm --cached -r -q -- .');

  Future<void> discard(GitChange c) {
    if (c.kind == GitKind.untracked) return must('clean -f -- ${shq(c.path)}');
    return must('restore -- ${shq(c.path)}');
  }

  Future<String> diff(GitChange c) async {
    if (c.kind == GitKind.untracked) {
      return (await run('diff --no-color --no-index -- /dev/null ${shq(c.path)}')).stdout;
    }
    return (await run('diff --no-color ${c.staged ? '--cached ' : ''}-- ${shq(c.path)}')).stdout;
  }

  Future<String> show(String hash) => must('show --no-color --stat --patch $hash');

  Future<List<GitCommit>> log({int n = 200}) async {
    final r = await run('log -n $n --date=relative --pretty=format:%h%x1f%an%x1f%ad%x1f%s%x1f%D%x1e');
    if (r.code != 0) return [];
    return [
      for (final rec in r.stdout.split('\x1e'))
        if (rec.trim().isNotEmpty) _commit(rec.trim().split('\x1f')),
    ];
  }

  static GitCommit _commit(List<String> f) {
    String at(int i) => i < f.length ? f[i] : '';
    return GitCommit(at(0), at(1), at(2), at(3), at(4));
  }

  Future<List<String>> branches() async {
    final r = await run("for-each-ref --format='%(refname:short)' refs/heads refs/remotes");
    return r.stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.endsWith('/HEAD')).toList();
  }

  Future<void> checkout(String branch) {
    final remote = remotes.any((r) => branch.startsWith('$r/'));
    final local = remote ? branch.substring(branch.indexOf('/') + 1) : branch;
    return must('switch ${shq(local)}');
  }

  Future<void> createBranch(String name) => must('switch -c ${shq(name)}');

  Future<void> init() async {
    await api.exec('git init -b main', cwd: root);
  }

  Future<({String name, String email})> identity() async {
    final r = await api.exec(r'printf "%s\037%s" "$(git config user.name)" "$(git config user.email)"', cwd: repoRoot ?? root);
    final f = r.stdout.split('\x1f');
    return (name: f[0].trim(), email: f.length > 1 ? f[1].trim() : '');
  }

  Future<void> setIdentity(String name, String email) =>
      api.exec('git config --global user.name ${shq(name)} && git config --global user.email ${shq(email)}');

  /// Commits with a message from a file, so any text is safe.
  Future<void> commit(String message, String home) async {
    final f = '$home/.termux-ide/commit_msg.txt';
    await api.write(f, message);
    await must('commit -q -F ${shq(f)}');
  }

  Future<void> addRemote(String url) => must('remote add origin ${shq(url)}');

  /// Saves a GitHub token for HTTPS push/pull (git credential store).
  Future<void> saveGithubToken(String home, String user, String token) async {
    final path = '$home/.git-credentials';
    var lines = <String>[];
    if (await api.exists(path)) {
      lines = (await api.read(path)).split('\n').where((l) => l.trim().isNotEmpty && !l.contains('@github.com')).toList();
    }
    lines.add('https://${Uri.encodeComponent(user)}:${Uri.encodeComponent(token)}@github.com');
    await api.write(path, '${lines.join('\n')}\n');
    await api.exec('git config --global credential.helper store');
  }

  /// Command for push (adds -u when there is no upstream yet).
  String pushCmd() =>
      status.upstream == null ? 'git push -u origin ${shq(status.branch)}' : 'git push';
}
