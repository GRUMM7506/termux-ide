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
        case 'exit':
          if (!_exit.isCompleted) _exit.complete((m['code'] as num?)?.toInt() ?? -1);
      }
    }, onDone: () {
      _closed = true;
      if (!_exit.isCompleted) _exit.complete(-1);
      _out.close();
    }, onError: (Object e) {
      if (!_out.isClosed) _out.add('\r\n[соединение потеряно: $e]\r\n');
    });
  }

  Stream<String> get output => _out.stream;
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
