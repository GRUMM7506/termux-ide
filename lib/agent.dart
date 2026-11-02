// AI agent panel: Claude Code and Codex running in Termux, signed in with the user's
// subscription (Claude Pro/Max, ChatGPT Plus/Pro) — the same CLIs the VS Code extensions use.
//
// The app never sees the tokens: sign-in happens in the official CLI (in a terminal), and the
// chat talks to the CLI in its headless mode:
//   claude -p --input-format stream-json --output-format stream-json   (one process per chat)
//   codex exec --json [resume <thread>] "<prompt>"                       (one process per turn)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'dialogs.dart';
import 'extensions.dart';
import 'git.dart' show shq;
import 'native.dart';
import 'settings.dart';

enum AgentKind { claude, codex }

class AgentMode {
  final String id;
  final String title;
  final String hint;
  const AgentMode(this.id, this.title, this.hint);
}

const _claudeModes = [
  AgentMode('plan', 'Только план', 'Читает проект и предлагает план. Ничего не меняет.'),
  AgentMode('acceptEdits', 'Правки файлов', 'Меняет файлы, но не запускает команды.'),
  AgentMode('auto', 'Авто', 'Правит файлы и запускает безопасные команды, рискованное блокирует.'),
  AgentMode('bypassPermissions', 'Полный доступ', 'Любые правки и команды без ограничений.'),
];

const _codexModes = [
  AgentMode('read-only', 'Только чтение', 'Читает проект и отвечает. Ничего не меняет.'),
  AgentMode('workspace-write', 'Правки в проекте',
      'Песочница: пишет только в папку проекта. Если команды падают с ошибкой sandbox — выбери «Полный доступ».'),
  AgentMode('full', 'Полный доступ', 'Любые правки и команды, без песочницы.'),
];

extension AgentKindX on AgentKind {
  bool get isClaude => this == AgentKind.claude;
  String get title => isClaude ? 'Claude Code' : 'Codex';
  String get tool => isClaude ? 'claude' : 'codex';
  String get plan => isClaude ? 'подписку Claude (Pro / Max)' : 'аккаунт ChatGPT (Plus / Pro)';
  Color get color => isClaude ? const Color(0xFFD97757) : const Color(0xFF10A37F);
  String get installCmd => isClaude ? claudeInstallCmd : codexInstallCmd;
  String get loginCmd => isClaude ? 'claude auth login' : 'codex login';
  String get logoutCmd => isClaude ? 'claude auth logout' : 'codex logout';
  List<AgentMode> get modes => isClaude ? _claudeModes : _codexModes;
  String get defaultMode => isClaude ? 'auto' : 'workspace-write';
  List<String> get modelPresets => isClaude ? const ['opus', 'sonnet', 'haiku'] : const [];

  /// Mode to switch to when the agent was refused a tool.
  String allowMore(String mode) => isClaude
      ? (mode == 'plan' || mode == 'acceptEdits' ? 'auto' : 'bypassPermissions')
      : 'full';
}

enum ItemKind { user, assistant, thinking, tool, error, info, denial }

class ChatItem {
  final ItemKind kind;
  String text;
  String title;
  String output;
  final String? id;
  bool running;
  bool failed;

  ChatItem(this.kind, this.text, {this.title = '', this.output = '', this.id, this.running = false, this.failed = false});

  Map<String, dynamic> toJson() => {
        'k': kind.name,
        't': text,
        if (title.isNotEmpty) 'h': title,
        if (output.isNotEmpty) 'o': output.length > 2000 ? '${output.substring(0, 2000)}…' : output,
        if (failed) 'f': true,
      };

  static ChatItem? fromJson(Map<String, dynamic> m) {
    final kind = ItemKind.values.where((k) => k.name == m['k']).firstOrNull;
    if (kind == null) return null;
    return ChatItem(kind, m['t'] as String? ?? '',
        title: m['h'] as String? ?? '', output: m['o'] as String? ?? '', failed: m['f'] == true);
  }
}

String _clip(String s, [int max = 6000]) => s.length > max ? '${s.substring(0, max)}\n…' : s;

const _editTools = {'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Bash'};

/// State of the agent panel of one project. Lives as long as the project is open.
class AgentController extends ChangeNotifier {
  final Api api;
  final Settings settings;
  final String root;

  /// Files on disk may have changed (refresh tree / git / open editors).
  final VoidCallback onFilesChanged;

  /// Called before a message is sent (save open files so the agent sees them).
  final Future<void> Function() onBeforeSend;

  /// Path of the file open in the editor, for context.
  final String? Function() currentFile;

  AgentController({
    required this.api,
    required this.settings,
    required this.root,
    required this.onFilesChanged,
    required this.onBeforeSend,
    required this.currentFile,
  }) {
    _load(kind);
  }

  final input = TextEditingController();
  final Map<AgentKind, AgentStatus?> status = {};
  final Map<AgentKind, List<ChatItem>> _items = {};
  bool checking = false;
  bool busy = false;
  String model0 = ''; // model reported by the agent
  bool _disposed = false;

  ProcSession? _proc; // claude: the chat process; codex: the current turn
  StreamSubscription<Map<String, dynamic>>? _sub;
  String _stderr = '';
  bool _stopping = false;
  bool _restartAfterTurn = false;
  bool _turnDone = false;
  Timer? _changedTimer;
  Timer? _stopTimer;
  final List<ChatItem> _live = []; // claude: text blocks being streamed
  final Map<String, ChatItem> _byId = {};
  int _reqId = 0;

  Map<String, String> get _cfg => settings.agentByProject.putIfAbsent(root, () => {});

  AgentKind get kind => _cfg['kind'] == 'codex' ? AgentKind.codex : AgentKind.claude;
  String get mode {
    final m = _cfg['mode_${kind.name}'];
    return kind.modes.any((x) => x.id == m) ? m! : kind.defaultMode;
  }

  AgentMode get modeInfo => kind.modes.firstWhere((m) => m.id == mode);
  String get model => _cfg['model_${kind.name}'] ?? '';
  String? get sessionId => _cfg['sid_${kind.name}'];
  bool get includeFile => _cfg['ctx'] != '0';
  List<ChatItem> get items => _items[kind] ?? const [];
  AgentStatus? get current => status[kind];
  bool get ready => current?.installed == true && current?.loggedIn == true;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _saveCfg() => settings.save().catchError((Object _) {});

  String rel(String p) => p.startsWith('$root/') ? p.substring(root.length + 1) : p;

  // ------------------------------------------------------------------ history

  String get _histPath {
    var h = 0x811c9dc5;
    for (final c in root.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${settings.dir}/agent_${h.toRadixString(16)}_${kind.name}.json';
  }

  void _load(AgentKind k) {
    if (_items.containsKey(k)) return;
    final list = <ChatItem>[];
    _items[k] = list;
    final saved = kind == k ? _histPath : null;
    if (saved == null) return;
    try {
      final f = File(saved);
      if (!f.existsSync()) return;
      for (final m in (jsonDecode(f.readAsStringSync()) as List)) {
        final it = ChatItem.fromJson((m as Map).cast<String, dynamic>());
        if (it != null) list.add(it);
      }
    } catch (_) {}
  }

  void _saveHistory() {
    try {
      final list = items;
      final from = list.length > 300 ? list.length - 300 : 0;
      File(_histPath).writeAsStringSync(jsonEncode([for (final i in list.sublist(from)) i.toJson()]));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ settings

  Future<void> checkStatus({bool all = false}) async {
    checking = true;
    _notify();
    try {
      final r = await api.agentStatus(all ? null : kind.tool);
      for (final k in AgentKind.values) {
        if (r[k.tool] != null) status[k] = r[k.tool];
      }
    } catch (e) {
      status[kind] = AgentStatus(error: '$e');
    }
    checking = false;
    _notify();
  }

  bool setKind(AgentKind k) {
    if (busy || k == kind) return !busy;
    _closeProc();
    _cfg['kind'] = k.name;
    _saveCfg();
    _load(k);
    model0 = '';
    _notify();
    if (status[k] == null) checkStatus();
    return true;
  }

  void setMode(String m) {
    _cfg['mode_${kind.name}'] = m;
    _saveCfg();
    _restartLater();
    _notify();
  }

  void setModel(String m) {
    if (m.isEmpty) {
      _cfg.remove('model_${kind.name}');
    } else {
      _cfg['model_${kind.name}'] = m;
    }
    _saveCfg();
    _restartLater();
    _notify();
  }

  void setIncludeFile(bool v) {
    _cfg['ctx'] = v ? '1' : '0';
    _saveCfg();
    _notify();
  }

  /// claude keeps one process per chat: mode / model changes need a restart (with --resume).
  void _restartLater() {
    if (!kind.isClaude) return;
    if (busy) {
      _restartAfterTurn = true;
    } else {
      _closeProc();
    }
  }

  void newChat() {
    if (busy) stop();
    _closeProc();
    _cfg.remove('sid_${kind.name}');
    _saveCfg();
    _items[kind] = [];
    _byId.clear();
    _live.clear();
    model0 = '';
    _saveHistory();
    _notify();
  }

  // ------------------------------------------------------------------ chat

  void _add(ChatItem i) {
    _items.putIfAbsent(kind, () => []).add(i);
    _notify();
  }

  void _error(String text) => _add(ChatItem(ItemKind.error, text));

  Future<void> send([String? text]) async {
    final msg = (text ?? input.text).trim();
    if (msg.isEmpty || busy) return;
    if (text == null) input.clear();
    try {
      await onBeforeSend();
    } catch (_) {}
    _add(ChatItem(ItemKind.user, msg));
    busy = true;
    _stopping = false;
    _turnDone = false;
    _stderr = '';
    _notify();
    final file = includeFile ? currentFile() : null;
    final prompt = file == null ? msg : '[Открыт в редакторе: ${rel(file)}]\n\n$msg';
    try {
      if (kind.isClaude) {
        await _sendClaude(prompt);
      } else {
        await _sendCodex(prompt);
      }
    } catch (e) {
      busy = false;
      _error('Не удалось запустить ${kind.title}: $e');
    }
    _saveHistory();
  }

  Future<void> _listen(ProcSession p, void Function(Map<String, dynamic>) onJson) async {
    _sub?.cancel();
    _sub = p.events.listen((ev) {
      switch (ev['t']) {
        case 'o':
          final line = ev['d'] as String;
          if (!line.startsWith('{')) return;
          try {
            onJson((jsonDecode(line) as Map).cast<String, dynamic>());
          } catch (_) {}
        case 'e':
          _stderr = _stderr + (ev['d'] as String);
          if (_stderr.length > 4000) _stderr = _stderr.substring(_stderr.length - 4000);
        case 'exit':
          _onExit(p, (ev['code'] as num?)?.toInt() ?? -1);
      }
    });
  }

  void _onExit(ProcSession p, int code) {
    if (!identical(p, _proc)) return;
    _proc = null;
    final wasBusy = busy;
    _endTurn();
    if (wasBusy && !_turnDone && !_stopping) {
      final err = _stderr.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '').trim();
      _error('${kind.title} завершился (код $code).${err.isEmpty ? '' : '\n\n${_clip(err, 1500)}'}');
      final low = err.toLowerCase();
      if (sessionId != null && (low.contains('no conversation found') || (low.contains('not found') && low.contains('session')))) {
        _cfg.remove('sid_${kind.name}');
        _saveCfg();
        _add(ChatItem(ItemKind.info, 'Прошлый разговор не найден — следующее сообщение начнёт новый.'));
      } else if (low.contains('login') || low.contains('logged') || low.contains('auth')) {
        checkStatus();
      }
    }
  }

  void _endTurn() {
    busy = false;
    _stopTimer?.cancel();
    for (final i in _byId.values) {
      i.running = false;
    }
    _live.clear();
    if (_stopping) _add(ChatItem(ItemKind.info, 'Остановлено'));
    _stopping = false;
    _changedSoon();
    _saveHistory();
    _notify();
  }

  void stop() {
    final p = _proc;
    if (!busy) return;
    _stopping = true;
    if (p == null) {
      _endTurn();
      return;
    }
    if (kind.isClaude) {
      p.write('${jsonEncode({
            'type': 'control_request',
            'request_id': 'stop-${++_reqId}',
            'request': {'subtype': 'interrupt'},
          })}\n');
    } else {
      p.signal('int');
    }
    _stopTimer?.cancel();
    _stopTimer = Timer(const Duration(seconds: 5), () {
      if (busy) {
        _closeProc();
        _endTurn();
      }
    });
    _notify();
  }

  void _closeProc() {
    _sub?.cancel();
    _sub = null;
    _proc?.close();
    _proc = null;
  }

  void _changedSoon() {
    _changedTimer?.cancel();
    _changedTimer = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed) onFilesChanged();
    });
  }

  // ------------------------------------------------------------------ Claude Code

  Future<void> _sendClaude(String prompt) async {
    var p = _proc;
    if (p == null || !p.running) {
      final sid = sessionId;
      final cmd = StringBuffer('claude -p --input-format stream-json --output-format stream-json --verbose '
          '--include-partial-messages --permission-mode $mode');
      if (model.isNotEmpty) cmd.write(' --model ${shq(model)}');
      if (sid != null && sid.isNotEmpty) cmd.write(' --resume ${shq(sid)}');
      p = await api.startProc(cmd: cmd.toString(), cwd: root, title: 'claude');
      _proc = p;
      _byId.clear();
      await _listen(p, _onClaude);
    }
    p.write('${jsonEncode({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
            ],
          },
        })}\n');
  }

  void _onClaude(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'system':
        if (j['subtype'] == 'init') {
          _setSid(j['session_id']);
          model0 = j['model'] as String? ?? '';
          _notify();
        }
      case 'stream_event':
        final ev = (j['event'] as Map?)?.cast<String, dynamic>() ?? const {};
        if (ev['type'] == 'content_block_start' && (ev['content_block'] as Map?)?['type'] == 'text') {
          final it = ChatItem(ItemKind.assistant, '', running: true);
          _live.add(it);
          _add(it);
        } else if (ev['type'] == 'content_block_delta') {
          final d = (ev['delta'] as Map?) ?? const {};
          if (d['type'] == 'text_delta' && _live.isNotEmpty) {
            _live.last.text += d['text'] as String? ?? '';
            _notify();
          }
        }
      case 'assistant':
        final content = ((j['message'] as Map?)?['content'] as List?) ?? const [];
        for (final raw in content) {
          final b = (raw as Map).cast<String, dynamic>();
          switch (b['type']) {
            case 'text':
              final text = b['text'] as String? ?? '';
              if (_live.isNotEmpty) {
                final it = _live.removeAt(0)
                  ..text = text
                  ..running = false;
                if (text.trim().isEmpty) items.remove(it);
              } else if (text.trim().isNotEmpty) {
                _add(ChatItem(ItemKind.assistant, text));
              }
            case 'tool_use':
              final name = b['name'] as String? ?? 'tool';
              final input = (b['input'] as Map?)?.cast<String, dynamic>() ?? const {};
              final it = ChatItem(ItemKind.tool, _claudeSummary(name, input),
                  title: _claudeTitle(name), id: b['id'] as String?, running: true);
              if (it.id != null) _byId[it.id!] = it;
              _toolNames[it.id ?? ''] = name;
              _add(it);
          }
        }
        _notify();
      case 'user':
        final content = ((j['message'] as Map?)?['content'] as List?) ?? const [];
        for (final raw in content) {
          if (raw is! Map || raw['type'] != 'tool_result') continue;
          final id = raw['tool_use_id'] as String? ?? '';
          final it = _byId[id];
          if (it == null) continue;
          it.running = false;
          it.failed = raw['is_error'] == true;
          it.output = _clip(_resultText(raw['content']));
          if (_editTools.contains(_toolNames[id])) _changedSoon();
        }
        _notify();
      case 'result':
        _setSid(j['session_id']);
        _turnDone = true;
        final ok = j['subtype'] == 'success' && j['is_error'] != true;
        if (!ok && !_stopping) {
          final errs = (j['errors'] as List?)?.join('\n');
          final text = (j['result'] as String?)?.trim();
          _error((text != null && text.isNotEmpty) ? text : (errs ?? 'Ошибка: ${j['subtype']}'));
        }
        final denials = (j['permission_denials'] as List?) ?? const [];
        if (denials.isNotEmpty) {
          final lines = <String>{};
          for (final d in denials) {
            if (d is! Map) continue;
            final name = d['tool_name'] as String? ?? '';
            final input = (d['tool_input'] as Map?)?.cast<String, dynamic>() ?? const {};
            lines.add('• ${_claudeTitle(name)}: ${_claudeSummary(name, input)}');
          }
          _add(ChatItem(ItemKind.denial, lines.join('\n')));
        }
        _endTurn();
        if (_restartAfterTurn) {
          _restartAfterTurn = false;
          _closeProc();
        }
    }
  }

  final Map<String, String> _toolNames = {};

  void _setSid(Object? sid) {
    if (sid is String && sid.isNotEmpty && sid != sessionId) {
      _cfg['sid_${kind.name}'] = sid;
      _saveCfg();
    }
  }

  static String _resultText(Object? c) {
    if (c is String) return c;
    if (c is List) {
      return c.map((e) => e is Map && e['type'] == 'text' ? '${e['text']}' : (e is Map ? '[${e['type']}]' : '$e')).join('\n');
    }
    return c == null ? '' : '$c';
  }

  static String _claudeTitle(String name) => switch (name) {
        'Read' => 'Чтение',
        'Write' => 'Новый файл',
        'Edit' || 'MultiEdit' || 'NotebookEdit' => 'Правка',
        'Bash' => 'Команда',
        'Grep' => 'Поиск в коде',
        'Glob' => 'Поиск файлов',
        'LS' => 'Список файлов',
        'WebFetch' => 'Загрузка страницы',
        'WebSearch' => 'Поиск в интернете',
        'TodoWrite' => 'План',
        'Task' || 'Agent' => 'Подагент',
        'ExitPlanMode' => 'План готов',
        _ => name,
      };

  String _claudeSummary(String name, Map<String, dynamic> input) {
    String? s(String k) => input[k] is String ? input[k] as String : null;
    switch (name) {
      case 'Read' || 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' || 'LS':
        return rel(s('file_path') ?? s('notebook_path') ?? s('path') ?? '');
      case 'Bash':
        return s('command') ?? '';
      case 'Grep':
        final path = s('path');
        return '${s('pattern') ?? ''}${path == null ? '' : '   (${rel(path)})'}';
      case 'Glob':
        return s('pattern') ?? '';
      case 'WebFetch':
        return s('url') ?? '';
      case 'WebSearch':
        return s('query') ?? '';
      case 'TodoWrite':
        final todos = (input['todos'] as List?) ?? const [];
        return todos
            .whereType<Map>()
            .map((t) => '${t['status'] == 'completed' ? '☑' : (t['status'] == 'in_progress' ? '▶' : '☐')} ${t['content'] ?? ''}')
            .join('\n');
      case 'Task' || 'Agent':
        return s('description') ?? s('prompt') ?? '';
      case 'ExitPlanMode':
        return s('plan') ?? '';
    }
    for (final v in input.values) {
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  // ------------------------------------------------------------------ Codex

  Future<void> _sendCodex(String prompt) async {
    final cmd = StringBuffer('codex exec --json --skip-git-repo-check ');
    cmd.write(switch (mode) {
      'read-only' => '-s read-only',
      'full' => '--dangerously-bypass-approvals-and-sandbox',
      _ => '-s workspace-write',
    });
    if (model.isNotEmpty) cmd.write(' -m ${shq(model)}');
    final sid = sessionId;
    if (sid != null && sid.isNotEmpty) cmd.write(' resume ${shq(sid)}');
    cmd.write(' ${shq(prompt.startsWith('-') ? ' $prompt' : prompt)}');
    final p = await api.startProc(cmd: cmd.toString(), cwd: root, stdin: false, title: 'codex');
    _proc = p;
    _byId.clear();
    await _listen(p, _onCodex);
  }

  void _onCodex(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'thread.started':
        _setSid(j['thread_id']);
      case 'item.started' || 'item.updated' || 'item.completed':
        final item = (j['item'] as Map?)?.cast<String, dynamic>();
        if (item == null) return;
        _codexItem(item, done: j['type'] == 'item.completed');
      case 'turn.completed':
        _turnDone = true;
      case 'turn.failed':
        _turnDone = true;
        _error('${((j['error'] as Map?)?['message']) ?? 'Ошибка'}');
      case 'error':
        final m = '${j['message'] ?? 'Ошибка'}';
        if (items.isEmpty || items.last.text != m) _error(m);
    }
  }

  void _codexItem(Map<String, dynamic> item, {required bool done}) {
    final id = '${item['id'] ?? ''}';
    final type = item['type'] as String? ?? '';
    ChatItem upsert(ItemKind k, {String title = ''}) {
      final old = _byId[id];
      if (old != null) return old;
      final it = ChatItem(k, '', title: title, id: id);
      _byId[id] = it;
      _add(it);
      return it;
    }

    switch (type) {
      case 'agent_message':
        upsert(ItemKind.assistant).text = item['text'] as String? ?? '';
      case 'reasoning':
        upsert(ItemKind.thinking).text = item['text'] as String? ?? '';
      case 'command_execution':
        final it = upsert(ItemKind.tool, title: 'Команда')
          ..text = item['command'] as String? ?? ''
          ..output = _clip(item['aggregated_output'] as String? ?? '');
        final code = item['exit_code'];
        it.running = !done && item['status'] == 'in_progress';
        it.failed = item['status'] == 'failed' || (code is num && code != 0);
        if (done) _changedSoon();
      case 'file_change':
        final changes = (item['changes'] as List?) ?? const [];
        final it = upsert(ItemKind.tool, title: 'Изменение файлов')
          ..text = changes
              .whereType<Map>()
              .map((c) => '${switch (c['kind']) { 'add' => '+', 'delete' => '−', _ => '~' }} ${rel('${c['path']}')}')
              .join('\n');
        it.failed = item['status'] == 'failed';
        it.running = false;
        _changedSoon();
      case 'mcp_tool_call':
        final it = upsert(ItemKind.tool, title: 'MCP')..text = '${item['server']}.${item['tool']}';
        it.running = !done;
        it.failed = item['status'] == 'failed';
      case 'web_search':
        final it = upsert(ItemKind.tool, title: 'Поиск в интернете')..text = '${item['query'] ?? ''}';
        it.running = !done;
      case 'todo_list':
        final todo = (item['items'] as List?) ?? const [];
        upsert(ItemKind.tool, title: 'План').text =
            todo.whereType<Map>().map((t) => '${t['completed'] == true ? '☑' : '☐'} ${t['text'] ?? ''}').join('\n');
      case 'error':
        upsert(ItemKind.error).text = item['message'] as String? ?? 'Ошибка';
    }
    _notify();
  }

  // ------------------------------------------------------------------ terminal (full TUI)

  /// Command for the agent's own terminal UI. [resume] continues the current chat.
  String tuiCommand({bool resume = false}) {
    final sid = sessionId;
    final r = resume && sid != null && sid.isNotEmpty;
    if (kind.isClaude) {
      return 'claude --permission-mode $mode${model.isEmpty ? '' : ' --model ${shq(model)}'}'
          '${r ? ' --resume ${shq(sid)}' : ''}';
    }
    return 'codex${mode == 'full' ? ' --dangerously-bypass-approvals-and-sandbox' : ''}'
        '${model.isEmpty ? '' : ' -m ${shq(model)}'}${r ? ' resume ${shq(sid)}' : ''}';
  }

  @override
  void dispose() {
    _disposed = true;
    _changedTimer?.cancel();
    _stopTimer?.cancel();
    _closeProc();
    input.dispose();
    super.dispose();
  }
}

// ==================================================================== UI

class AgentPanel extends StatefulWidget {
  final AgentController agent;

  /// Full-screen terminal for install / sign-in.
  final Future<void> Function(String cmd, String title) onRunPage;

  /// The agent's own terminal UI in the IDE's terminal panel.
  final Future<void> Function(String cmd, String title) onOpenTerminal;

  const AgentPanel({super.key, required this.agent, required this.onRunPage, required this.onOpenTerminal});

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _scroll = ScrollController();
  int _lastCount = 0;

  AgentController get a => widget.agent;

  @override
  void initState() {
    super.initState();
    a.addListener(_onChange);
    if (a.current == null && !a.checking) Future.microtask(a.checkStatus);
  }

  @override
  void dispose() {
    a.removeListener(_onChange);
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    final count = a.items.length;
    final grew = count != _lastCount;
    _lastCount = count;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (grew || pos.maxScrollExtent - pos.pixels < 120) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));

  Future<void> _runPage(String cmd, String title) async {
    await widget.onRunPage(cmd, title);
    await a.checkStatus();
  }

  Future<void> _install() async {
    final k = a.kind;
    if (k.isClaude) {
      final r = await askChoice(
        context,
        'У Claude Code нет официальной сборки для Android, поэтому ставим его через установщик сообщества '
        '(github.com/ferrumclaudepilgrim/claude-code-android): он скачивает официальный linux-arm64 Claude Code '
        'и запускает его через glibc-runner. Займёт 5–10 минут и ~300 МБ.\n\n'
        'Установщик задаст два вопроса. Если Termux у тебя уже давно — на первый («Fresh Termux?») ответь n, на второй — y.',
        ['Установить', 'Подробнее', 'Отмена'],
      );
      if (r == 1) {
        await Native.openUrl('https://github.com/ferrumclaudepilgrim/claude-code-android');
        return;
      }
      if (r != 0) return;
    }
    await _runPage(k.installCmd, 'Установка: ${k.title}');
  }

  Future<void> _login() => _runPage(a.kind.loginCmd, 'Вход: ${a.kind.title}');

  Future<void> _menu(String v) async {
    final k = a.kind;
    switch (v) {
      case 'new':
        a.newChat();
      case 'tui':
        await widget.onOpenTerminal(a.tuiCommand(), k.title);
      case 'tui_resume':
        await widget.onOpenTerminal(a.tuiCommand(resume: true), k.title);
      case 'status':
        await a.checkStatus();
      case 'login':
        await _login();
      case 'logout':
        if (await askChoice(context, 'Выйти из аккаунта в ${k.title}?', ['Выйти', 'Отмена']) == 0) {
          await _runPage(k.logoutCmd, 'Выход: ${k.title}');
        }
      case 'update':
        await _runPage(k.isClaude ? k.installCmd : 'pkg update -y && pkg install -y --only-upgrade codex && codex --version',
            'Обновление: ${k.title}');
    }
  }

  Future<void> _pickModel() async {
    final k = a.kind;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Модель', style: TextStyle(fontWeight: FontWeight.bold))),
          ListTile(
            selected: a.model.isEmpty,
            title: const Text('По умолчанию'),
            subtitle: Text(a.model0.isEmpty ? 'как настроено в ${k.title}' : a.model0),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final m in k.modelPresets)
            ListTile(selected: a.model == m, title: Text(m), onTap: () => Navigator.pop(ctx, m)),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Своя…'), onTap: () => Navigator.pop(ctx, '\u0000')),
        ]),
      ),
    );
    if (v == null) return;
    if (v == '\u0000') {
      final m = await prompt(context, 'Модель', initial: a.model, hint: k.isClaude ? 'например claude-opus-5-5' : 'например gpt-5-codex');
      if (m != null) a.setModel(m.trim());
    } else {
      a.setModel(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final st = a.current;
        final Widget body;
        if (st == null) {
          body = Center(
            child: a.checking
                ? const Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Проверяю агента…', style: TextStyle(color: Colors.white54)),
                  ])
                : TextButton(onPressed: a.checkStatus, child: const Text('Проверить')),
          );
        } else if (!st.installed) {
          body = _setupCard(st);
        } else if (!st.loggedIn) {
          body = _loginCard(st);
        } else {
          body = _chat();
        }
        return Padding(
          padding: EdgeInsets.only(bottom: inset),
          child: Column(children: [
            _header(st),
            Expanded(child: body),
            if (a.ready) _composer(),
          ]),
        );
      },
    );
  }

  Widget _header(AgentStatus? st) {
    Widget chip(AgentKind k) {
      final on = a.kind == k;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          visualDensity: VisualDensity.compact,
          label: Text(k.title, style: const TextStyle(fontSize: 12.5)),
          selected: on,
          selectedColor: k.color.withValues(alpha: .35),
          onSelected: (_) {
            if (!a.setKind(k)) _snack('Дождись ответа или останови агента');
          },
        ),
      );
    }

    final sub = st == null
        ? ''
        : [if (st.version.isNotEmpty) st.version, if (st.detail.isNotEmpty) st.detail, if (a.model0.isNotEmpty) a.model0]
            .join(' · ');
    return Container(
      color: const Color(0xFF202021),
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          chip(AgentKind.claude),
          chip(AgentKind.codex),
          const Spacer(),
          if (a.checking) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          PopupMenuButton<String>(
            tooltip: 'Меню агента',
            onSelected: _menu,
            itemBuilder: (_) => [
              if (a.ready) const PopupMenuItem(value: 'new', child: Text('Новый чат')),
              if (st?.installed == true) ...[
                const PopupMenuItem(value: 'tui', child: Text('Открыть в терминале')),
                if (a.sessionId != null)
                  const PopupMenuItem(value: 'tui_resume', child: Text('Продолжить этот чат в терминале')),
              ],
              const PopupMenuItem(value: 'status', child: Text('Проверить вход')),
              if (st?.installed == true) ...[
                const PopupMenuItem(value: 'login', child: Text('Войти заново')),
                const PopupMenuItem(value: 'logout', child: Text('Выйти из аккаунта')),
                PopupMenuItem(value: 'update', child: Text('Обновить ${a.kind.title}')),
              ],
            ],
          ),
        ]),
        if (sub.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ),
      ]),
    );
  }

  Widget _card({required IconData icon, required String title, required String text, required List<Widget> actions, String? error}) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Icon(icon, size: 44, color: a.kind.color),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.35)),
      if (error != null && error.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(_clip(error, 600), style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontFamily: 'monospace')),
      ],
      const SizedBox(height: 16),
      ...actions,
    ]);
  }

  Widget _setupCard(AgentStatus st) {
    final k = a.kind;
    return _card(
      icon: Icons.download_for_offline_outlined,
      title: '${k.title} не установлен',
      text: k.isClaude
          ? 'Агент Anthropic: читает проект, правит файлы и запускает команды (flutter, gradle, git) прямо в Termux. '
              'Работает по подписке Claude Pro / Max — API-ключ не нужен.'
          : 'Агент OpenAI: читает проект, правит файлы и запускает команды прямо в Termux. '
              'Работает с аккаунтом ChatGPT (Plus / Pro) — API-ключ не нужен. Ставится из официального репозитория Termux.',
      error: st.error,
      actions: [
        FilledButton.icon(onPressed: _install, icon: const Icon(Icons.download), label: Text('Установить ${k.title}')),
        TextButton(onPressed: () => a.checkStatus(), child: const Text('Уже установил — проверить')),
      ],
    );
  }

  Widget _loginCard(AgentStatus st) {
    final k = a.kind;
    return _card(
      icon: Icons.login,
      title: 'Вход в ${k.title}',
      text: 'Войди через ${k.plan}. Откроется браузер; ключ API не нужен, лимиты — как у подписки.\n\n'
          '${k.isClaude ? 'После входа сайт покажет код — скопируй его и вставь в терминал кнопкой ⎘, затем Enter.' : 'После входа браузер сам вернёт тебя на localhost — просто вернись в приложение.'}\n\n'
          'Токен хранится у самого ${k.title} в Termux, приложение его не видит.',
      error: st.error,
      actions: [
        FilledButton.icon(onPressed: _login, icon: const Icon(Icons.login), label: const Text('Войти')),
        TextButton(onPressed: () => a.checkStatus(), child: const Text('Уже вошёл — проверить')),
        TextButton(
            onPressed: () => widget.onOpenTerminal(k.tool, k.title), child: const Text('Открыть в терминале (вход через /login)')),
      ],
    );
  }

  Widget _chat() {
    final list = a.items;
    if (list.isEmpty) {
      const hints = [
        'Объясни структуру проекта',
        'Найди и исправь ошибки',
        'Добавь README с инструкцией запуска',
        'Напиши тесты для основного кода',
      ];
      return ListView(padding: const EdgeInsets.all(16), children: [
        Icon(Icons.smart_toy_outlined, size: 40, color: a.kind.color),
        const SizedBox(height: 10),
        Text('${a.kind.title} видит весь проект и может менять файлы и запускать команды.',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
        const SizedBox(height: 4),
        Text('Режим: ${a.modeInfo.title} — ${a.modeInfo.hint}',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          for (final h in hints) ActionChip(label: Text(h, style: const TextStyle(fontSize: 12.5)), onPressed: () => a.send(h)),
        ]),
      ]);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      itemCount: list.length + (a.busy ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == list.length) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Row(children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Работаю…', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            ]),
          );
        }
        return _item(list[i]);
      },
    );
  }

  Widget _item(ChatItem it) {
    switch (it.kind) {
      case ItemKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.fromLTRB(40, 6, 0, 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFF264F78), borderRadius: BorderRadius.circular(12)),
            child: SelectableText(it.text, style: const TextStyle(fontSize: 14)),
          ),
        );
      case ItemKind.assistant:
        return Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2), child: _RichText(it.text));
      case ItemKind.thinking:
        return _Expandable(
          header: const Text('Размышление', style: TextStyle(fontSize: 12, color: Colors.white38)),
          preview: it.text,
          full: it.text,
          dim: true,
        );
      case ItemKind.tool:
        return _ToolTile(item: it);
      case ItemKind.error:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0x33F14C4C), borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(it.text, style: const TextStyle(fontSize: 13))),
          ]),
        );
      case ItemKind.info:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(it.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white38)),
        );
      case ItemKind.denial:
        final more = a.kind.allowMore(a.mode);
        final moreTitle = a.kind.modes.firstWhere((m) => m.id == more).title;
        final last = identical(it, a.items.lastOrNull);
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0x33E5A50A), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Режим «${a.modeInfo.title}» не разрешил:', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(it.text, style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
            if (last && !a.busy && more != a.mode) ...[
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () {
                  a.setMode(more);
                  a.send('Разрешение выдано (режим «$moreTitle»). Продолжай.');
                },
                child: Text('Разрешить («$moreTitle») и продолжить'),
              ),
            ],
          ]),
        );
    }
  }

  Widget _composer() {
    final k = a.kind;
    final file = a.currentFile();
    Widget pill(IconData icon, String label, VoidCallback onTap, {bool on = true}) => InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: on ? Colors.white24 : Colors.white10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: on ? Colors.white70 : Colors.white30),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(label,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: on ? Colors.white70 : Colors.white30)),
              ),
            ]),
          ),
        );

    return Container(
      color: const Color(0xFF202021),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            PopupMenuButton<String>(
              tooltip: 'Режим доступа',
              onSelected: a.setMode,
              itemBuilder: (_) => [
                for (final m in k.modes)
                  CheckedPopupMenuItem(
                    value: m.id,
                    checked: m.id == a.mode,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(m.title),
                      subtitle: Text(m.hint, style: const TextStyle(fontSize: 11.5)),
                    ),
                  ),
              ],
              child: IgnorePointer(child: pill(Icons.shield_outlined, a.modeInfo.title, () {})),
            ),
            const SizedBox(width: 6),
            pill(Icons.memory, a.model.isEmpty ? 'модель: авто' : a.model, _pickModel),
            const SizedBox(width: 6),
            if (file != null)
              pill(Icons.description_outlined, file.split('/').last, () => a.setIncludeFile(!a.includeFile), on: a.includeFile),
          ]),
        ),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: a.input,
              minLines: 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Задача для ${k.title}…',
                filled: true,
                fillColor: const Color(0xFF2A2A2B),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 6),
          a.busy
              ? IconButton.filledTonal(tooltip: 'Остановить', onPressed: a.stop, icon: const Icon(Icons.stop, color: Colors.redAccent))
              : IconButton.filled(tooltip: 'Отправить', onPressed: () => a.send(), icon: const Icon(Icons.arrow_upward)),
        ]),
      ]),
    );
  }
}

/// Assistant text: plain paragraphs + ``` code blocks.
class _RichText extends StatelessWidget {
  final String text;
  const _RichText(this.text);

  @override
  Widget build(BuildContext context) {
    final parts = text.split('```');
    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (i.isOdd) {
        final nl = p.indexOf('\n');
        if (nl >= 0 && !p.substring(0, nl).contains(' ')) p = p.substring(nl + 1); // drop the language tag
        p = p.trimRight();
        children.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(6)),
          child: Stack(children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(p, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: InkWell(
                onTap: () => Clipboard.setData(ClipboardData(text: p)),
                child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.copy, size: 14, color: Colors.white38)),
              ),
            ),
          ]),
        ));
      } else if (p.trim().isNotEmpty) {
        children.add(SelectableText(p.trim(), style: const TextStyle(fontSize: 14, height: 1.35)));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _Expandable extends StatefulWidget {
  final Widget header;
  final String preview;
  final String full;
  final bool dim;
  const _Expandable({required this.header, required this.preview, required this.full, this.dim = false});

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => setState(() => open = !open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          widget.header,
          Text(open ? widget.full : widget.preview,
              maxLines: open ? null : 2,
              overflow: open ? null : TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: widget.dim ? Colors.white38 : Colors.white70, fontStyle: FontStyle.italic)),
        ]),
      ),
    );
  }
}

class _ToolTile extends StatefulWidget {
  final ChatItem item;
  const _ToolTile({required this.item});

  @override
  State<_ToolTile> createState() => _ToolTileState();
}

class _ToolTileState extends State<_ToolTile> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final icon = it.running
        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(it.failed ? Icons.close : Icons.check, size: 15, color: it.failed ? Colors.redAccent : Colors.greenAccent);
    final canOpen = it.output.isNotEmpty || it.text.contains('\n') || it.text.length > 60;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(color: const Color(0xFF242425), borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: canOpen ? () => setState(() => open = !open) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              icon,
              const SizedBox(width: 8),
              Text(it.title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(it.text.split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white60)),
              ),
              if (canOpen) Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: Colors.white38),
            ]),
            if (open) ...[
              if (it.text.contains('\n') || it.text.length > 60)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText(it.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              if (it.output.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(6),
                  color: const Color(0xFF1A1A1A),
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: SelectableText(it.output,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.white70)),
                  ),
                ),
            ],
          ]),
        ),
      ),
    );
  }
}
