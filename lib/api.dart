import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FsEntry {
  final String name;
  final String path;
  final bool dir;
  const FsEntry(this.name, this.path, this.dir);
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class ServerInfo {
  final String version;
  final String home;
  final List<String> tools;
  ServerInfo(this.version, this.home, this.tools);
  bool has(String tool) => tools.contains(tool);
}

class AgentStatus {
  final bool installed;
  final bool loggedIn;
  final String version;
  final String detail;
  final String? error;
  const AgentStatus({this.installed = false, this.loggedIn = false, this.version = '', this.detail = '', this.error});

  factory AgentStatus.fromJson(Map<String, dynamic> m) => AgentStatus(
        installed: m['installed'] == true,
        loggedIn: m['loggedIn'] == true,
        version: m['version'] as String? ?? '',
        detail: m['detail'] as String? ?? '',
        error: m['error'] as String?,
      );
}

class ExecResult {
  final int code;
  final String stdout;
  final String stderr;
  ExecResult(this.code, this.stdout, this.stderr);
}

/// HTTP/WebSocket client of the server running inside Termux (assets/termux/server.py).
class Api {
  String token;
  final int port;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  Api(this.token, {this.port = 8765});

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: q);

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final req = await _http.getUrl(_u(path, q));
    req.headers.set('x-token', token);
    return _read(await req.close());
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final req = await _http.postUrl(_u(path));
    req.headers.set('x-token', token);
    req.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(body));
    req.contentLength = bytes.length; // no chunked encoding
    req.add(bytes);
    return _read(await req.close());
  }

  Future<dynamic> _read(HttpClientResponse res) async {
    final text = await utf8.decoder.bind(res).join();
    final data = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode != 200) {
      throw ApiException(data is Map && data['error'] != null ? '${data['error']}' : 'HTTP ${res.statusCode}');
    }
    return data;
  }

  Future<ServerInfo> info({bool refresh = false}) async {
    final d = await _get('/api/info', refresh ? {'refresh': '1'} : null) as Map<String, dynamic>;
    return ServerInfo(
      d['version'] as String? ?? '0',
      d['home'] as String? ?? '',
      ((d['tools'] as List?) ?? const []).cast<String>(),
    );
  }

  Future<List<FsEntry>> list(String path) async {
    final data = await _get('/api/list', {'path': path}) as Map<String, dynamic>;
    return (data['entries'] as List)
        .map((e) => FsEntry(e['name'] as String, e['path'] as String, e['dir'] as bool))
        .toList();
  }

  Future<({String content, bool binary})> readFile(String path) async {
    final d = await _get('/api/read', {'path': path}) as Map<String, dynamic>;
    return (content: d['content'] as String, binary: d['binary'] == true);
  }

  Future<String> read(String path) async => (await readFile(path)).content;

  Future<bool> exists(String path) async =>
      ((await _get('/api/exists', {'path': path})) as Map<String, dynamic>)['exists'] == true;

  Future<void> write(String path, String content) => _post('/api/write', {'path': path, 'content': content});
  Future<void> mkdir(String path) => _post('/api/mkdir', {'path': path});
  Future<void> delete(String path) => _post('/api/delete', {'path': path});
  Future<void> rename(String from, String to) => _post('/api/rename', {'from': from, 'to': to});

  Future<ExecResult> exec(String cmd, {String? cwd, int timeout = 60}) async {
    final d = await _post('/api/exec', {'cmd': cmd, 'cwd': cwd, 'timeout': timeout}) as Map<String, dynamic>;
    return ExecResult((d['code'] as num).toInt(), d['stdout'] as String, d['stderr'] as String);
  }

  /// Installed / signed-in state of the CLI agents (claude, codex).
  Future<Map<String, AgentStatus>> agentStatus([String? agent]) async {
    final d = await _get('/api/agent/status', agent == null ? null : {'agent': agent}) as Map<String, dynamic>;
    return d.map((k, v) => MapEntry(k, AgentStatus.fromJson(v as Map<String, dynamic>)));
  }

  Uri _ws(String path, Map<String, String> q) => _u(path, {'token': token, ...q}).replace(scheme: 'ws');

  /// Starts a process with pipes (JSONL on stdout). [stdin] false = stdin is /dev/null.
  Future<ProcSession> startProc({required String cmd, required String cwd, bool stdin = true, String title = ''}) =>
      ProcSession._start(this, _ws('/ws/proc', {'cmd': cmd, 'cwd': cwd, 'stdin': stdin ? '1' : '0', 'title': title}));

  /// Opens a terminal (PTY) session. [cmd] empty = interactive bash.
  Future<TermSession> openTerminal({
    String cmd = '',
    required String cwd,
    String title = '',
    int cols = 80,
    int rows = 24,
  }) async {
    final uri = _u('/ws/term', {
      'token': token,
      'cmd': cmd,
      'cwd': cwd,
      'title': title,
      'cols': '$cols',
      'rows': '$rows',
    }).replace(scheme: 'ws');
    final ws = await WebSocket.connect(uri.toString());
    return TermSession._(ws);
  }
}

/// One PTY session on the server.
class TermSession {
  final WebSocket _ws;
  final _out = StreamController<String>(); // buffers until listened
  final _urls = StreamController<String>.broadcast();
  final _exit = Completer<int>();
  int? id;
  bool _closed = false;

  TermSession._(this._ws) {
    _ws.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (m['t']) {
        case 'hello':
          id = (m['id'] as num?)?.toInt();
        case 'o':
          _out.add(m['d'] as String);
        case 'url':
          _urls.add(m['d'] as String);
        case 'exit':
          if (!_exit.isCompleted) _exit.complete((m['code'] as num?)?.toInt() ?? -1);
      }
    }, onDone: () {
      _closed = true;
      if (!_exit.isCompleted) _exit.complete(-1);
      _out.close();
      _urls.close();
    }, onError: (Object e) {
      if (!_out.isClosed) _out.add('\r\n[соединение потеряно: $e]\r\n');
    });
  }

  Stream<String> get output => _out.stream;

  /// Links a program in this terminal asked to open (sign-in pages of Claude Code / Codex).
  Stream<String> get urls => _urls.stream;
  Future<int> get exitCode => _exit.future;
  bool get running => !_exit.isCompleted;

  void _send(Map<String, dynamic> m) {
    if (_closed) return;
    try {
      _ws.add(jsonEncode(m));
    } catch (_) {
      _closed = true;
    }
  }

  void input(String data) => _send({'t': 'i', 'd': data});
  void resize(int cols, int rows) => _send({'t': 'resize', 'cols': cols, 'rows': rows});

  /// int (Ctrl+C) | term | kill | hup | usr1 | usr2
  void signal(String s) => _send({'t': 'sig', 's': s});

  /// Stops the process and forgets the session on the server.
  void close() {
    _send({'t': 'close'});
    _closed = true;
    try {
      _ws.close();
    } catch (_) {}
  }
}

/// A process with pipes on the server (assets/termux/server.py, /ws/proc).
/// Events: {t: o, d: stdout line} · {t: e, d: stderr text} · {t: exit, code}.
/// Reconnects by itself if the connection drops while the process is still running.
class ProcSession {
  final Api _api;
  final _events = StreamController<Map<String, dynamic>>(); // buffers until listened
  WebSocket? _ws;
  int? id;
  int _seen = 0;
  bool _exited = false;
  bool _closed = false;
  int _retries = 0;

  ProcSession._(this._api);

  static Future<ProcSession> _start(Api api, Uri uri) async {
    final p = ProcSession._(api);
    await p._connect(uri);
    return p;
  }

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get running => !_exited && !_closed;

  Future<void> _connect(Uri uri) async {
    final ws = await WebSocket.connect(uri.toString());
    _ws = ws;
    ws.listen((raw) {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = m['t'];
      if (t == 'hello') {
        id = (m['id'] as num?)?.toInt();
        _retries = 0;
        return;
      }
      if (t == 'gone' || t == 'error') {
        if (t == 'error') _add({'t': 'e', 'd': '${m['d']}'});
        _finish(-1);
        return;
      }
      final n = (m['n'] as num?)?.toInt() ?? 0;
      if (n <= _seen) return;
      _seen = n;
      if (t == 'exit') {
        _finish((m['code'] as num?)?.toInt() ?? -1);
      } else {
        _add(m);
      }
    }, onDone: _onDone, onError: (Object _) {});
  }

  void _add(Map<String, dynamic> m) {
    if (!_events.isClosed) _events.add(m);
  }

  void _finish(int code) {
    if (_exited) return;
    _exited = true;
    _add({'t': 'exit', 'code': code});
    _events.close();
    try {
      _ws?.close();
    } catch (_) {}
  }

  Future<void> _onDone() async {
    if (_exited || _closed) return;
    final sid = id;
    if (sid == null || _retries >= 8) {
      _finish(-1);
      return;
    }
    _retries++;
    await Future<void>.delayed(Duration(milliseconds: 400 * _retries));
    if (_exited || _closed) return;
    try {
      await _connect(_api._ws('/ws/proc', {'id': '$sid', 'since': '$_seen'}));
    } catch (_) {
      unawaited(_onDone());
    }
  }

  void _send(Map<String, dynamic> m) {
    if (_exited || _closed) return;
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Writes to the process's stdin.
  void write(String data) => _send({'t': 'i', 'd': data});
  void eof() => _send({'t': 'eof'});

  /// int | term | kill (the whole process group).
  void signal(String s) => _send({'t': 'sig', 's': s});

  /// Kills the process and forgets it on the server.
  void close() {
    if (_closed) return;
    _send({'t': 'close'});
    _closed = true;
    if (!_exited) {
      _exited = true;
      _add({'t': 'exit', 'code': -1});
      _events.close();
    }
    try {
      _ws?.close();
    } catch (_) {}
  }
}
