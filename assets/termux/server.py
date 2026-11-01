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

VERSION = "2.0.0"
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
    "git", "adb", "aapt2",
]

sessions = {}
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

        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERMUX_IDE"] = "1"
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

    def _readable(self):
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if data:
            text = self.decoder.decode(data)
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


async def gc_sessions():
    while True:
        await asyncio.sleep(60)
        now = time.time()
        for s in list(sessions.values()):
            if not s.running and not s.clients and now - (s.ended or now) > 600:
                sessions.pop(s.id, None)


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


async def ws_term(reader, writer, headers, q):
    key = headers.get("sec-websocket-key", "")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    writer.write((
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    ws = WsConn(reader, writer)

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


async def run_exec(cmd, cwd, timeout=120):
    p = await asyncio.create_subprocess_exec(
        "bash", "-c", cmd, cwd=cwd, stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout)
    except asyncio.TimeoutError:
        p.kill()
        return {"code": -1, "stdout": "", "stderr": "timeout"}
    return {"code": p.returncode, "stdout": out.decode(errors="replace"), "stderr": err.decode(errors="replace")}


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
    if path == "/api/sessions":
        return {"sessions": [s.info() for s in sessions.values()]}
    if path == "/api/session/close":
        s = sessions.get(int(body["id"]))
        if s:
            s.close()
        return {"ok": True}
    raise LookupError(path)


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
        body = {}
        n = int(headers.get("content-length", "0") or 0)
        if n:
            body = json.loads((await reader.readexactly(n)).decode("utf-8"))
        try:
            http_response(writer, 200, await api(method, u.path, q, body))
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


def kill_previous():
    pidfile = os.path.join(DIR, "server.pid")
    try:
        old = int(open(pidfile).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM)
            time.sleep(0.5)
    except (OSError, ValueError):
        pass


async def main():
    global TOKEN, PORT
    if len(sys.argv) < 2 or len(sys.argv[1]) < 16:
        print("usage: server.py <token(>=16 chars)> [port]")
        sys.exit(2)
    TOKEN = sys.argv[1]
    if len(sys.argv) > 2:
        PORT = int(sys.argv[2])
    os.makedirs(DIR, exist_ok=True)
    kill_previous()
    with open(os.path.join(DIR, "server.pid"), "w") as f:
        f.write(str(os.getpid()))

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))

    server = await asyncio.start_server(handle, "127.0.0.1", PORT, reuse_address=True, limit=1 << 20)
    log(f"Termux IDE server {VERSION} on 127.0.0.1:{PORT}, home={HOME}")
    asyncio.ensure_future(gc_sessions())
    await stop
    log("stopping")
    for s in list(sessions.values()):
        s.close()
    server.close()
    try:
        os.remove(os.path.join(DIR, "server.pid"))
    except OSError:
        pass


if __name__ == "__main__":
    asyncio.run(main())
