#!/usr/bin/env python3
"""Termux IDE server.

Runs inside Termux and gives the Termux IDE app access to files and real
terminals (PTY). Python standard library only.

Listens on 127.0.0.1 only; every request must carry the token.
Usage: python server.py <token> [port]
"""

import asyncio
import base64
import codecs
import fcntl
import hashlib
import json
import os
import pty
import secrets
import shutil
import signal
import struct
import sys
import termios
import time
import urllib.parse

VERSION = "2.1.0"
HOME = os.environ.get("HOME", "/data/data/com.termux/files/home")
DIR = os.path.join(HOME, ".termux-ide")
PORT = 8765
TOKEN = ""
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SCROLLBACK_CHARS = 200_000
MAX_READ = 8 * 1024 * 1024

TOOLS = [
    "flutter", "dart", "python", "pip", "node", "npm", "java", "javac", "kotlinc", "gradle",
    "clang", "clang++", "make", "cmake", "go", "cargo", "rustc", "ruby", "php", "lua",
    "git", "adb", "aapt2", "claude", "codex",
]

BIN_DIR = os.path.join(DIR, "bin")
URL_OSC = "\x1b]7770;"  # private OSC: "open this URL in the app" (see OPEN_URL_SH)
MAX_PROC_LINE = 64 * 1024 * 1024
PROC_BUFFER = 20_000

# xdg-open / $BROWSER replacement for terminals started by the IDE. Claude Code and
# Codex open the sign-in page with it; the URL goes to the app, which opens the browser
# (Android does not let Termux start activities from the background).
OPEN_URL_SH = r"""#!__PREFIX__/bin/sh
# Termux IDE: открывает ссылки через приложение (вход в Claude Code / Codex).
case "$1" in
  http://*|https://*)
    printf '%s\n' "$1" > "$HOME/.termux-ide/last-url" 2>/dev/null
    if { printf '\033]7770;%s\007' "$1" > /dev/tty; } 2>/dev/null; then exit 0; fi
    exec termux-open-url "$1" ;;
esac
exec termux-open "$@"
"""

sessions = {}
procs = {}
_next_sid = 1
_tools_cache = {"t": 0.0, "tools": []}


def log(*a):
    print(time.strftime("[%H:%M:%S]"), *a, flush=True)


def abs_path(p):
    p = p or HOME
    p = os.path.expanduser(p)
    if not p.startswith("/"):
        p = os.path.join(HOME, p)
    return os.path.normpath(p)


def child_env():
    env = dict(os.environ)
    env["TERMUX_IDE"] = "1"
    env["PATH"] = BIN_DIR + os.pathsep + env.get("PATH", "")
    env["BROWSER"] = os.path.join(BIN_DIR, "xdg-open")
    return env


def install_helpers():
    os.makedirs(BIN_DIR, exist_ok=True)
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    path = os.path.join(BIN_DIR, "xdg-open")
    with open(path, "w") as f:
        f.write(OPEN_URL_SH.replace("__PREFIX__", prefix))
    os.chmod(path, 0o755)


# --------------------------------------------------------------------------- PTY sessions


class Session:
    def __init__(self, cmd, cwd, cols, rows, title):
        global _next_sid
        self.id = _next_sid
        _next_sid += 1
        self.cmd = cmd
        self.title = title or (cmd.split()[0] if cmd else "bash")
        self.cwd = cwd
        self.started = time.time()
        self.ended = None
        self.code = None
        self.scrollback = []
        self.scroll_len = 0
        self.clients = set()
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._carry = ""

        env = child_env()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        argv = ["bash", "-ic", cmd] if cmd else ["bash", "-i"]

        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                os.chdir(cwd)
            except OSError:
                pass
            try:
                os.execvpe("bash", argv, env)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self.resize(cols, rows)
        asyncio.get_running_loop().add_reader(fd, self._readable)
        log(f"session {self.id} started pid={pid} cmd={cmd!r} cwd={cwd}")

    @property
    def running(self):
        return self.code is None

    def info(self):
        return {"id": self.id, "title": self.title, "cmd": self.cmd, "cwd": self.cwd,
                "running": self.running, "code": self.code}

    def resize(self, cols, rows):
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(rows, 2), max(cols, 10), 0, 0))
        except OSError:
            pass

    def write(self, text):
        if self.running:
            try:
                os.write(self.fd, text.encode())
            except OSError:
                pass

    def signal(self, name):
        if not self.running:
            return
        if name == "int":
            self.write("\x03")
            return
        sig = {"term": signal.SIGTERM, "kill": signal.SIGKILL, "hup": signal.SIGHUP,
               "usr1": signal.SIGUSR1, "usr2": signal.SIGUSR2}.get(name)
        if sig is None:
            return
        try:
            os.killpg(self.pid, sig)
        except OSError:
            try:
                os.kill(self.pid, sig)
            except OSError:
                pass
        if sig == signal.SIGTERM:
            asyncio.get_running_loop().call_later(3, lambda: self.signal("kill"))

    def _emit(self, text):
        self.scrollback.append(text)
        self.scroll_len += len(text)
        while self.scroll_len > SCROLLBACK_CHARS and len(self.scrollback) > 1:
            self.scroll_len -= len(self.scrollback.pop(0))
        msg = json.dumps({"t": "o", "d": text})
        for c in list(self.clients):
            c.send_text(msg)

    def _take_urls(self, text):
        """Cuts URL_OSC markers out of the output and sends them to the app as {t: url}."""
        text = self._carry + text
        self._carry = ""
        while True:
            i = text.find(URL_OSC)
            if i < 0:
                return text
            j = text.find("\x07", i)
            if j < 0:
                if len(text) - i < 16384:
                    self._carry, text = text[i:], text[:i]
                return text
            url = text[i + len(URL_OSC):j]
            text = text[:i] + text[j + 1:]
            log(f"session {self.id} open url")
            msg = json.dumps({"t": "url", "d": url})
            for c in list(self.clients):
                c.send_text(msg)

    def _readable(self):
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if data:
            text = self._take_urls(self.decoder.decode(data))
            if text:
                self._emit(text)
            return
        asyncio.get_running_loop().remove_reader(self.fd)
        asyncio.ensure_future(self._reap())

    async def _reap(self):
        status = None
        for _ in range(100):
            try:
                pid, st = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                status = 0
                break
            if pid:
                status = st
                break
            await asyncio.sleep(0.05)
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.code = os.waitstatus_to_exitcode(status) if status is not None else -1
        self.ended = time.time()
        if self.cmd:
            color = "32" if self.code == 0 else "31"
            self._emit(f"\r\n\x1b[{color}m[завершено, код {self.code}]\x1b[0m\r\n")
        msg = json.dumps({"t": "exit", "code": self.code})
        for c in list(self.clients):
            c.send_text(msg)
        log(f"session {self.id} exited code={self.code}")

    def close(self):
        if self.running:
            self.signal("hup")
            asyncio.get_running_loop().call_later(2, lambda: self.signal("kill"))
        sessions.pop(self.id, None)


# --------------------------------------------------------------------------- pipe processes
# Used by the AI agent panel: `claude -p --output-format stream-json`, `codex exec --json`.
# stdout is delivered line by line (JSONL), stderr as text. Messages are numbered (n) and
# buffered, so the app can reconnect and skip what it has already seen.


class ProcSession:
    def __init__(self, cmd, cwd, use_stdin, title):
        global _next_sid
        self.id = _next_sid
        _next_sid += 1
        self.cmd = cmd
        self.cwd = cwd
        self.use_stdin = use_stdin
        self.title = title or "proc"
        self.code = None
        self.ended = None
        self.buffer = []
        self.seq = 0
        self.clients = set()
        self.proc = None

    @property
    def running(self):
        return self.code is None

    def info(self):
        return {"id": self.id, "title": self.title, "running": self.running, "code": self.code}

    async def start(self):
        script = "{ [ -f ~/.bashrc ] && . ~/.bashrc; } >/dev/null 2>&1 </dev/null; " + self.cmd
        self.proc = await asyncio.create_subprocess_exec(
            "bash", "-c", script, cwd=self.cwd, env=child_env(),
            stdin=asyncio.subprocess.PIPE if self.use_stdin else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=MAX_PROC_LINE, start_new_session=True)
        log(f"proc {self.id} started pid={self.proc.pid} cmd={self.cmd!r} cwd={self.cwd}")
        out = asyncio.ensure_future(self._pump_lines())
        err = asyncio.ensure_future(self._pump_err())
        asyncio.ensure_future(self._wait(out, err))

    def _emit(self, obj):
        self.seq += 1
        obj["n"] = self.seq
        msg = json.dumps(obj)
        self.buffer.append(msg)
        if len(self.buffer) > PROC_BUFFER:
            del self.buffer[:len(self.buffer) - PROC_BUFFER]
        for c in list(self.clients):
            c.send_text(msg)

    async def _pump_lines(self):
        r = self.proc.stdout
        while True:
            try:
                line = await r.readline()
            except ValueError:  # line longer than the limit: dropped by the reader
                continue
            if not line:
                return
            text = line.decode("utf-8", errors="replace").rstrip("\r\n")
            if text:
                self._emit({"t": "o", "d": text})

    async def _pump_err(self):
        r = self.proc.stderr
        dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        while True:
            data = await r.read(65536)
            if not data:
                return
            text = dec.decode(data)
            if text:
                self._emit({"t": "e", "d": text})

    async def _wait(self, out, err):
        code = await self.proc.wait()
        try:
            await asyncio.wait_for(asyncio.gather(out, err), 5)
        except Exception:
            pass
        self.code = code
        self.ended = time.time()
        self._emit({"t": "exit", "code": code})
        log(f"proc {self.id} exited code={code}")

    def write(self, text):
        if self.running and self.use_stdin and self.proc.stdin and not self.proc.stdin.is_closing():
            try:
                self.proc.stdin.write(text.encode())
            except Exception:
                pass

    def eof(self):
        if self.proc and self.proc.stdin and not self.proc.stdin.is_closing():
            try:
                self.proc.stdin.close()
            except Exception:
                pass

    def signal(self, name):
        if not self.running or not self.proc:
            return
        sig = {"int": signal.SIGINT, "term": signal.SIGTERM, "kill": signal.SIGKILL}.get(name)
        if sig is None:
            return
        try:
            os.killpg(self.proc.pid, sig)
        except OSError:
            try:
                self.proc.send_signal(sig)
            except Exception:
                pass
        if sig != signal.SIGKILL:
            asyncio.get_running_loop().call_later(4, lambda: self.signal("kill"))

    def close(self):
        self.signal("term")
        procs.pop(self.id, None)


async def ws_proc(reader, writer, headers, q):
    ws = ws_accept(reader, writer, headers)
    pid = int(q.get("id", "0") or 0)
    if pid and pid in procs:
        p = procs[pid]
    elif pid:
        ws.send_text(json.dumps({"t": "gone"}))
        ws.close()
        return
    else:
        p = ProcSession(q.get("cmd", ""), abs_path(q.get("cwd")), q.get("stdin", "1") == "1", q.get("title", ""))
        procs[p.id] = p
        try:
            await p.start()
        except Exception as e:
            procs.pop(p.id, None)
            ws.send_text(json.dumps({"t": "error", "d": str(e)}))
            ws.close()
            return
    p.clients.add(ws)
    ws.send_text(json.dumps({"t": "hello", **p.info()}))
    since = int(q.get("since", "0") or 0)
    for msg in list(p.buffer):
        if json.loads(msg).get("n", 0) > since:
            ws.send_text(msg)
    try:
        while True:
            raw = await ws.recv()
            if raw is None:
                break
            try:
                m = json.loads(raw)
            except ValueError:
                continue
            t = m.get("t")
            if t == "i":
                p.write(m.get("d", ""))
                try:
                    await p.proc.stdin.drain()
                except Exception:
                    pass
            elif t == "eof":
                p.eof()
            elif t == "sig":
                p.signal(m.get("s", ""))
            elif t == "close":
                p.close()
                break
            try:
                await writer.drain()
            except ConnectionError:
                break
    finally:
        p.clients.discard(ws)
        ws.close()


async def gc_sessions():
    while True:
        await asyncio.sleep(60)
        now = time.time()
        for s in list(sessions.values()):
            if not s.running and not s.clients and now - (s.ended or now) > 600:
                sessions.pop(s.id, None)
        for p in list(procs.values()):
            if not p.running and not p.clients and now - (p.ended or now) > 600:
                procs.pop(p.id, None)


# --------------------------------------------------------------------------- WebSocket


class WsConn:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.closed = False

    def _frame(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack("!H", n)
        else:
            head += bytes([127]) + struct.pack("!Q", n)
        return head + payload

    def send_text(self, text):
        if self.closed:
            return
        try:
            self.writer.write(self._frame(0x1, text.encode()))
        except Exception:
            self.closed = True

    async def recv(self):
        """Returns the next text message, or None when the connection is closed."""
        buf = b""
        while True:
            try:
                h = await self.reader.readexactly(2)
            except (asyncio.IncompleteReadError, ConnectionError):
                return None
            fin, opcode = h[0] & 0x80, h[0] & 0x0F
            masked, n = h[1] & 0x80, h[1] & 0x7F
            if n == 126:
                n = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            mask = await self.reader.readexactly(4) if masked else b""
            data = await self.reader.readexactly(n) if n else b""
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                return None
            if opcode == 0x9:
                self.writer.write(self._frame(0xA, data))
                continue
            if opcode == 0xA:
                continue
            buf += data
            if fin:
                return buf.decode("utf-8", errors="replace")

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.writer.write(self._frame(0x8, b""))
                self.writer.close()
            except Exception:
                pass


def ws_accept(reader, writer, headers):
    key = headers.get("sec-websocket-key", "")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    writer.write((
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    return WsConn(reader, writer)


async def ws_term(reader, writer, headers, q):
    ws = ws_accept(reader, writer, headers)

    sid = int(q.get("id", "0") or 0)
    if sid and sid in sessions:
        s = sessions[sid]
    else:
        s = Session(
            cmd=q.get("cmd", ""),
            cwd=abs_path(q.get("cwd")),
            cols=int(q.get("cols", "80") or 80),
            rows=int(q.get("rows", "24") or 24),
            title=q.get("title", ""),
        )
        sessions[s.id] = s
    s.clients.add(ws)
    ws.send_text(json.dumps({"t": "hello", **s.info()}))
    if s.scrollback:
        ws.send_text(json.dumps({"t": "o", "d": "".join(s.scrollback)}))
    if not s.running:
        ws.send_text(json.dumps({"t": "exit", "code": s.code}))

    try:
        while True:
            raw = await ws.recv()
            if raw is None:
                break
            try:
                m = json.loads(raw)
            except ValueError:
                continue
            t = m.get("t")
            if t == "i":
                s.write(m.get("d", ""))
            elif t == "resize":
                s.resize(int(m.get("cols", 80)), int(m.get("rows", 24)))
            elif t == "sig":
                s.signal(m.get("s", ""))
            elif t == "close":
                s.close()
                break
            try:
                await writer.drain()
            except ConnectionError:
                break
    finally:
        s.clients.discard(ws)
        ws.close()


# --------------------------------------------------------------------------- HTTP API


async def detect_tools(refresh=False):
    if not refresh and time.time() - _tools_cache["t"] < 30:
        return _tools_cache["tools"]
    script = "; ".join(f"command -v {t} >/dev/null 2>&1 && echo {t}" for t in TOOLS)
    try:
        p = await asyncio.create_subprocess_exec(
            "bash", "-ic", script, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(p.communicate(), 20)
        found = [l.strip() for l in out.decode().splitlines() if l.strip() in TOOLS]
    except Exception as e:
        log("detect_tools failed:", e)
        found = [t for t in TOOLS if shutil.which(t)]
    _tools_cache.update(t=time.time(), tools=found)
    return found


def list_dir(path):
    out = []
    with os.scandir(path) as it:
        for e in it:
            try:
                is_dir = e.is_dir()
            except OSError:
                is_dir = False
            out.append({"name": e.name, "path": e.path, "dir": is_dir})
    out.sort(key=lambda x: (not x["dir"], x["name"].lower()))
    return out


async def run_exec(cmd, cwd, timeout=120, env=None):
    p = await asyncio.create_subprocess_exec(
        "bash", "-c", cmd, cwd=cwd, env=env, stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout)
    except asyncio.TimeoutError:
        p.kill()
        return {"code": -1, "stdout": "", "stderr": "timeout"}
    return {"code": p.returncode, "stdout": out.decode(errors="replace"), "stderr": err.decode(errors="replace")}


async def agent_status(name):
    """Is the CLI agent installed and signed in? name: claude | codex."""
    pre = "{ [ -f ~/.bashrc ] && . ~/.bashrc; } >/dev/null 2>&1 </dev/null; "
    env = child_env()
    r = await run_exec(pre + f"command -v {name}", HOME, 30, env)
    path = r["stdout"].strip().splitlines()[-1] if r["stdout"].strip() else ""
    if r["code"] != 0 or not path:
        return {"installed": False, "loggedIn": False}
    v = await run_exec(pre + f"{name} --version", HOME, 90, env)
    version = (v["stdout"].strip() or v["stderr"].strip()).splitlines()
    res = {"installed": True, "path": path, "version": version[-1][:80] if version else "",
           "loggedIn": False, "detail": ""}
    if v["code"] != 0:
        res["error"] = (v["stderr"] or v["stdout"]).strip()[-600:]
    if name == "claude":
        a = await run_exec(pre + "claude auth status --json", HOME, 60, env)
        try:
            d = json.loads(a["stdout"][a["stdout"].index("{"):])
            res["loggedIn"] = bool(d.get("loggedIn"))
            res["detail"] = " · ".join(str(d[k]) for k in ("email", "subscriptionType", "authMethod")
                                       if d.get(k) and d.get(k) is not True)
        except (ValueError, AttributeError):
            res["loggedIn"] = a["code"] == 0 and "not logged" not in (a["stdout"] + a["stderr"]).lower()
            res["detail"] = (a["stdout"] or a["stderr"]).strip()[:200]
    else:
        a = await run_exec(pre + "codex login status", HOME, 60, env)
        text = (a["stdout"] + "\n" + a["stderr"]).strip()
        res["loggedIn"] = a["code"] == 0 and "not logged" not in text.lower()
        res["detail"] = text.splitlines()[0][:200] if text else ""
    return res


async def api(method, path, q, body):
    if path == "/api/info":
        return {"version": VERSION, "home": HOME, "pid": os.getpid(),
                "tools": await detect_tools(q.get("refresh") == "1"),
                "sessions": [s.info() for s in sessions.values()]}
    if path == "/api/list":
        p = abs_path(q.get("path"))
        return {"path": p, "entries": list_dir(p)}
    if path == "/api/read":
        p = abs_path(q.get("path"))
        size = os.path.getsize(p)
        if size > MAX_READ:
            raise ValueError(f"файл слишком большой ({size // 1024} КБ)")
        with open(p, "rb") as f:
            data = f.read()
        return {"content": data.decode("utf-8", errors="replace"), "binary": b"\x00" in data[:8192]}
    if path == "/api/exists":
        p = abs_path(q.get("path"))
        return {"exists": os.path.exists(p), "dir": os.path.isdir(p)}
    if path == "/api/write":
        p = abs_path(body["path"])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(body.get("content", ""))
        return {"ok": True}
    if path == "/api/mkdir":
        os.makedirs(abs_path(body["path"]), exist_ok=True)
        return {"ok": True}
    if path == "/api/delete":
        p = abs_path(body["path"])
        if p in ("/", HOME) or not p.startswith("/"):
            raise ValueError(f"нельзя удалить {p}")
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        elif os.path.lexists(p):
            os.remove(p)
        return {"ok": True}
    if path == "/api/rename":
        os.rename(abs_path(body["from"]), abs_path(body["to"]))
        return {"ok": True}
    if path == "/api/exec":
        return await run_exec(body["cmd"], abs_path(body.get("cwd")), int(body.get("timeout", 120)))
    if path == "/api/agent/status":
        names = [n for n in (q.get("agent") or "claude,codex").split(",") if n in ("claude", "codex")]
        results = await asyncio.gather(*(agent_status(n) for n in names))
        return dict(zip(names, results))
    if path == "/api/sessions":
        return {"sessions": [s.info() for s in sessions.values()]}
    if path == "/api/session/close":
        s = sessions.get(int(body["id"]))
        if s:
            s.close()
        return {"ok": True}
    raise LookupError(path)


async def read_body(reader, headers):
    """Request body with Content-Length or chunked transfer encoding."""
    if "chunked" in headers.get("transfer-encoding", "").lower():
        data = bytearray()
        while True:
            size_line = await reader.readuntil(b"\r\n")
            size = int(size_line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                # trailers until an empty line
                while (await reader.readuntil(b"\r\n")) != b"\r\n":
                    pass
                return bytes(data)
            data += await reader.readexactly(size)
            await reader.readexactly(2)
            if len(data) > 64 * 1024 * 1024:
                raise ValueError("тело запроса слишком большое")
    n = int(headers.get("content-length", "0") or 0)
    return await reader.readexactly(n) if n else b""


def http_response(writer, status, obj):
    data = json.dumps(obj).encode()
    reason = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Error"}.get(status, "OK")
    writer.write((f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\n"
                  f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n").encode() + data)


async def handle(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        writer.close()
        return
    try:
        lines = head.decode("latin-1").split("\r\n")
        method, target, _ = lines[0].split(" ", 2)
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        u = urllib.parse.urlsplit(target)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(u.query, keep_blank_values=True).items()}
        token = headers.get("x-token") or q.get("token", "")
        if not secrets.compare_digest(token, TOKEN):
            http_response(writer, 401, {"error": "unauthorized"})
            return
        if u.path == "/ws/term" and headers.get("upgrade", "").lower() == "websocket":
            await ws_term(reader, writer, headers, q)
            return
        if u.path == "/ws/proc" and headers.get("upgrade", "").lower() == "websocket":
            await ws_proc(reader, writer, headers, q)
            return
        body = {}
        raw = await read_body(reader, headers)
        if raw:
            body = json.loads(raw.decode("utf-8"))
        try:
            http_response(writer, 200, await api(method, u.path, q, body))
        except KeyError as e:
            http_response(writer, 400, {"error": f"нет параметра {e}"})
        except LookupError as e:
            http_response(writer, 404, {"error": f"не найдено: {e}"})
        except Exception as e:
            http_response(writer, 500, {"error": str(e)})
    except Exception as e:
        log("request error:", repr(e))
        try:
            http_response(writer, 400, {"error": str(e)})
        except Exception:
            pass
    finally:
        try:
            await writer.drain()
            writer.close()
        except Exception:
            pass


def _is_old_server(argv):
    """Any previous IDE server: the legacy Dart one or another copy of this script."""
    if any(a.endswith("ide_server.dart") for a in argv):
        return True
    return bool(argv) and "python" in os.path.basename(argv[0]) and any(
        a.endswith("/.termux-ide/server.py") for a in argv[1:])


def kill_previous():
    """Stops older servers (pid file + /proc scan) so the port is free."""
    me = os.getpid()
    victims = set()
    try:
        victims.add(int(open(os.path.join(DIR, "server.pid")).read().strip()))
    except (OSError, ValueError):
        pass
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/cmdline", "rb") as f:
                argv = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
        except OSError:
            continue
        if _is_old_server(argv):
            victims.add(int(name))
    victims.discard(me)
    for pid in victims:
        try:
            os.kill(pid, signal.SIGTERM)
            log(f"stopped old server pid={pid}")
        except OSError:
            pass
    if victims:
        time.sleep(0.7)


async def main():
    global TOKEN, PORT
    if len(sys.argv) < 2 or len(sys.argv[1]) < 16:
        print("usage: server.py <token(>=16 chars)> [port]")
        sys.exit(2)
    TOKEN = sys.argv[1]
    if len(sys.argv) > 2:
        PORT = int(sys.argv[2])
    os.makedirs(DIR, exist_ok=True)
    try:
        install_helpers()
    except OSError as e:
        log("install_helpers failed:", e)
    kill_previous()
    with open(os.path.join(DIR, "server.pid"), "w") as f:
        f.write(str(os.getpid()))

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))

    server = None
    for attempt in range(6):
        try:
            server = await asyncio.start_server(handle, "127.0.0.1", PORT, reuse_address=True, limit=1 << 20)
            break
        except OSError as e:
            if e.errno != 98 or attempt == 5:
                raise
            log(f"port {PORT} is busy, retrying ({attempt + 1})")
            kill_previous()
            await asyncio.sleep(1)
    log(f"Termux IDE server {VERSION} on 127.0.0.1:{PORT}, home={HOME}")
    asyncio.ensure_future(gc_sessions())
    await stop
    log("stopping")
    for s in list(sessions.values()):
        s.close()
    for p in list(procs.values()):
        p.close()
    server.close()
    try:
        os.remove(os.path.join(DIR, "server.pid"))
    except OSError:
        pass


if __name__ == "__main__":
    asyncio.run(main())
