#!/usr/bin/env python3
"""
Warm kiro-cli ACP client with daemon mode. Keeps kiro-cli running as a
persistent process and sends prompts via the Agent Client Protocol.

Usage:
  kask "your prompt"          # one-shot (auto-starts daemon if needed)
  kask                        # interactive REPL (direct, no daemon)
  echo "prompt" | kask        # pipe mode (auto-starts daemon if needed)
  kask --stop                 # stop all daemons
"""

import json
import fcntl
import os
import signal
import socket
import subprocess
import sys
import threading
import time

SOCK_DIR = "/tmp/kask"
IDLE_TIMEOUT = 900  # 15 minutes
DEBUG = os.environ.get("KASK_DEBUG", "") == "1" or os.path.islink(os.path.expanduser("~/.cmux-kiro"))

def _debug(agent, msg):
    if not DEBUG:
        return
    try:
        with open(os.path.join(SOCK_DIR, f"{agent}.debug.log"), "a") as f:
            f.write(f"{time.time():.3f} {msg}\n")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

_req_id = 0

def _next_id():
    global _req_id
    _req_id += 1
    return _req_id

def _send(proc, obj):
    line = json.dumps(obj) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()

def _send_request(proc, method, params=None):
    rid = _next_id()
    msg = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        msg["params"] = params
    _send(proc, msg)
    return rid

# ---------------------------------------------------------------------------
# Line reader — reads JSONL from stdout in a thread, dispatches to handler
# ---------------------------------------------------------------------------

class JsonlReader:
    def __init__(self, stream, proc, on_chunk=None):
        self._stream = stream
        self._proc = proc
        self._on_chunk = on_chunk
        self._responses = {}
        self._waiters = {}
        self._chunks = []
        self._dead = False
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        buf = ""
        try:
            for raw in self._stream:
                buf += raw
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    self._dispatch(obj)
        except Exception:
            pass
        # Stream ended (process died) or exception — wake all waiters so they
        # get None instead of blocking until timeout
        self._dead = True
        with self._lock:
            for ev in self._waiters.values():
                ev.set()

    def _dispatch(self, obj):
        if "id" in obj and "method" in obj:
            if obj["method"] == "session/request_permission":
                _send(self._proc, {"jsonrpc": "2.0", "id": obj["id"],
                                    "result": {"granted": True}})
            return

        if "id" in obj and ("result" in obj or "error" in obj):
            rid = obj["id"]
            with self._lock:
                self._responses[rid] = obj
                ev = self._waiters.get(rid)
            if ev:
                ev.set()
            return

        method = obj.get("method", "")
        params = obj.get("params", {})
        if method == "session/update":
            update = params.get("update", {})
            if update.get("sessionUpdate") == "agent_message_chunk":
                text = update.get("content", {}).get("text", "")
                if text:
                    self._chunks.append(text)
                    if self._on_chunk:
                        self._on_chunk(text)

    def wait_response(self, rid, timeout=120):
        ev = threading.Event()
        with self._lock:
            if rid in self._responses:
                return self._responses.pop(rid)
            if self._dead:
                return None
            self._waiters[rid] = ev
        # Poll in short intervals so we notice _dead or process exit quickly
        deadline = time.time() + timeout
        while not ev.is_set() and time.time() < deadline:
            if self._dead or self._proc.poll() is not None:
                break
            ev.wait(timeout=0.5)
        with self._lock:
            self._waiters.pop(rid, None)
            return self._responses.pop(rid, None)

    def collect_chunks(self):
        chunks = self._chunks[:]
        self._chunks.clear()
        return "".join(chunks)

# ---------------------------------------------------------------------------
# ACP Client
# ---------------------------------------------------------------------------

class KiroAcpClient:
    def __init__(self, agent="fast", on_chunk=None):
        cmd = ["kiro-cli", "acp", "--trust-all-tools", "--agent", agent]
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            start_new_session=True,
        )
        self.reader = JsonlReader(self.proc.stdout, self.proc, on_chunk=on_chunk)
        self.session_id = None
        self._stderr_lines = []
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()
        try:
            self._handshake()
        except Exception:
            self.close()
            raise

    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                self._stderr_lines.append(line.rstrip())
                if len(self._stderr_lines) > 50:
                    self._stderr_lines.pop(0)
        except Exception:
            pass

    def recent_stderr(self):
        return "\n".join(self._stderr_lines[-10:])

    def _handshake(self):
        rid = _send_request(self.proc, "initialize", {
            "protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": "kask", "version": "0.2.0"},
        })
        res = self.reader.wait_response(rid, timeout=10)
        if not res or res.get("error"):
            raise RuntimeError(f"ACP initialize failed: {res}")

        rid = _send_request(self.proc, "session/new", {
            "cwd": os.getcwd(), "mcpServers": [],
        })
        res = self.reader.wait_response(rid, timeout=10)
        if not res or res.get("error"):
            raise RuntimeError(f"ACP session/new failed: {res}")
        self.session_id = res["result"]["sessionId"]

    def prompt(self, text, timeout=30):
        # Check if the underlying process is still alive before sending
        if self.proc.poll() is not None:
            raise RuntimeError("ACP process exited unexpectedly")
        self.reader.collect_chunks()
        rid = _send_request(self.proc, "session/prompt", {
            "sessionId": self.session_id,
            "prompt": [{"type": "text", "text": text}],
        })
        res = self.reader.wait_response(rid, timeout=timeout)
        if res is None:
            raise RuntimeError(f"ACP prompt timed out (no response in {timeout}s)")
        if res.get("error"):
            raise RuntimeError(res["error"].get("message", "unknown"))
        return self.reader.collect_chunks()

    def close(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass

# ---------------------------------------------------------------------------
# Daemon — listens on Unix socket, keeps ACP client warm
# ---------------------------------------------------------------------------

def _sock_path(agent):
    return os.path.join(SOCK_DIR, f"{agent}.sock")

def _pid_path(agent):
    return os.path.join(SOCK_DIR, f"{agent}.pid")

def _daemon_alive(agent):
    pid_file = _pid_path(agent)
    if not os.path.exists(pid_file):
        return False
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, OSError):
        return False

def _cleanup_stale(agent):
    for f in [_sock_path(agent), _pid_path(agent)]:
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass

def run_daemon(agent):
    os.makedirs(SOCK_DIR, exist_ok=True)

    if _daemon_alive(agent):
        sys.exit(0)

    _cleanup_stale(agent)

    # Write PID
    with open(_pid_path(agent), "w") as f:
        f.write(str(os.getpid()))

    sock_file = _sock_path(agent)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_file)
    srv.listen(4)
    srv.settimeout(30)

    last_activity = time.time()
    client = None
    first_prompt = True
    prompt_count = 0

    def shutdown(*_):
        nonlocal client
        if client:
            client.close()
        srv.close()
        _cleanup_stale(agent)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        while True:
            if time.time() - last_activity > IDLE_TIMEOUT:
                break

            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            last_activity = time.time()

            try:
                data = b""
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                    if b"\n" in data:
                        break

                prompt_text = data.decode("utf-8").strip()
                if not prompt_text:
                    conn.close()
                    continue

                _debug(agent, f"daemon: received {len(prompt_text)}B prompt")

                # Lazy init ACP client on first prompt
                if client is None:
                    try:
                        _debug(agent, "daemon: cold-starting ACP client")
                        client = KiroAcpClient(agent=agent, on_chunk=lambda t: None)
                        _debug(agent, "daemon: ACP client ready")
                    except Exception as init_err:
                        _debug(agent, f"daemon: ACP init failed: {init_err}")
                        conn.sendall(f"ERROR: {init_err}".encode("utf-8"))
                        conn.close()
                        continue

                try:
                    timeout = 15 if first_prompt else 10
                    _debug(agent, f"daemon: calling prompt() timeout={timeout}")
                    result = client.prompt(prompt_text, timeout=timeout)
                    first_prompt = False
                    prompt_count += 1
                    _debug(agent, f"daemon: prompt() returned {len(result)}B")
                except Exception:
                    stderr = client.recent_stderr() if client else ""
                    _debug(agent, f"daemon: prompt() failed, stderr:\n{stderr}")
                    if client:
                        client.close()
                        client = None
                    raise
                conn.sendall(result.encode("utf-8"))
                # Periodically clear conversation history to prevent context bloat
                if prompt_count >= 10:
                    try:
                        client.prompt("/clear", timeout=5)
                        prompt_count = 0
                    except Exception as e:
                        _debug(agent, f"daemon: /clear failed: {e}")
                        if client:
                            client.close()
                            client = None
                        first_prompt = True
                        prompt_count = 0
            except Exception as e:
                _debug(agent, f"daemon: error: {e}")
                try:
                    conn.sendall(f"ERROR: {e}".encode("utf-8"))
                except Exception:
                    pass
                # ACP process may have died — reset
                if client:
                    client.close()
                    client = None
                    first_prompt = True
                    prompt_count = 0
            finally:
                conn.close()
    finally:
        shutdown()

def send_to_daemon(agent, prompt_text):
    """Send prompt to running daemon, return response text."""
    _debug(agent, f"caller: connect start")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(20)
    sock.connect(_sock_path(agent))
    _debug(agent, f"caller: connected, sending {len(prompt_text)}B")
    sock.sendall((prompt_text + "\n").encode("utf-8"))
    sock.shutdown(socket.SHUT_WR)
    _debug(agent, "caller: sent, waiting for response")
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        if not data:
            _debug(agent, "caller: first byte received")
        data += chunk
    sock.close()
    _debug(agent, f"caller: done, got {len(data)}B")
    return data.decode("utf-8")

def _lock_path(agent):
    return os.path.join(SOCK_DIR, f"{agent}.lock")

def ensure_daemon(agent):
    """Start daemon if not running. Returns True if daemon is available."""
    # Fast path — no lock needed if daemon is already running
    if _daemon_alive(agent) and os.path.exists(_sock_path(agent)):
        return True

    os.makedirs(SOCK_DIR, exist_ok=True)

    # Acquire exclusive lock so only one process can spawn at a time
    lock_fd = open(_lock_path(agent), "w")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        # Re-check under lock — another process may have spawned while we waited
        if _daemon_alive(agent) and os.path.exists(_sock_path(agent)):
            return True

        _cleanup_stale(agent)

        # Launch daemon as a fully detached subprocess
        devnull = open(os.devnull, "r+b")
        env = os.environ.copy()
        env["KASK_AGENT"] = agent
        subprocess.Popen(
            [sys.executable, __file__, "--daemon"],
            stdin=devnull, stdout=devnull, stderr=devnull,
            start_new_session=True, env=env,
        )

        # Wait for socket to appear
        for _ in range(100):
            if os.path.exists(_sock_path(agent)):
                time.sleep(0.1)
                return True
            time.sleep(0.1)
        return False
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()

def _stop_daemon(agent):
    """Stop a specific daemon."""
    pid_file = _pid_path(agent)
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, signal.SIGKILL)
    except (ValueError, OSError, FileNotFoundError):
        pass
    _cleanup_stale(agent)
    time.sleep(0.5)

def stop_all():
    """Stop all running daemons."""
    if not os.path.isdir(SOCK_DIR):
        return
    for f in os.listdir(SOCK_DIR):
        if f.endswith(".pid"):
            path = os.path.join(SOCK_DIR, f)
            try:
                pid = int(open(path).read().strip())
                os.kill(pid, signal.SIGTERM)
            except (ValueError, OSError):
                pass
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        elif f.endswith(".sock"):
            try:
                os.unlink(os.path.join(SOCK_DIR, f))
            except FileNotFoundError:
                pass

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if "--stop" in sys.argv:
        stop_all()
        return

    if "--daemon" in sys.argv:
        agent = os.environ.get("KASK_AGENT", "fast")
        run_daemon(agent)
        return

    agent = os.environ.get("KASK_AGENT", "fast")

    # Interactive REPL — direct mode (no daemon), stays warm in-process
    if len(sys.argv) == 1 and sys.stdin.isatty():
        client = KiroAcpClient(agent=agent, on_chunk=lambda t: (sys.stdout.write(t), sys.stdout.flush()))
        try:
            print("kask (warm kiro ACP client) — type 'quit' to exit")
            while True:
                try:
                    prompt_text = input("\n> ").strip()
                except (EOFError, KeyboardInterrupt):
                    break
                if not prompt_text or prompt_text.lower() in ("quit", "exit"):
                    break
                client.prompt(prompt_text)
                print()
        finally:
            client.close()
        return

    # One-shot or pipe — use daemon for warm prompts
    if len(sys.argv) > 1:
        prompt_text = " ".join(sys.argv[1:])
    else:
        prompt_text = sys.stdin.read().strip()

    if not prompt_text:
        return

    # Try daemon first
    if ensure_daemon(agent):
        try:
            result = send_to_daemon(agent, prompt_text)
        except OSError:
            result = "ERROR: daemon connection failed"

        if result.startswith("ERROR:"):
            # Daemon's client is broken — kill it and start fresh
            _stop_daemon(agent)
            if ensure_daemon(agent):
                try:
                    result = send_to_daemon(agent, prompt_text)
                except OSError:
                    result = "ERROR: retry connection failed"

        if not result.startswith("ERROR:"):
            sys.stdout.write(result)
            if result and not result.endswith("\n"):
                print()
            return

    # Fallback: direct cold start
    client = KiroAcpClient(agent=agent, on_chunk=lambda t: (sys.stdout.write(t), sys.stdout.flush()))
    try:
        client.prompt(prompt_text)
        print()
    finally:
        client.close()

if __name__ == "__main__":
    main()
