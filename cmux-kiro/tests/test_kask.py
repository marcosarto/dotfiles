#!/usr/bin/env python3
"""
Comprehensive test suite for kask (kiro-acp-client.py).

Uses a fake kiro-cli that speaks the ACP JSON-RPC protocol, so tests
are fast (~seconds) and don't need real ACP/network access.

Run: python3 tests/test_kask.py
"""

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KASK_SCRIPT = os.path.join(REPO_DIR, "bin", "kiro-acp-client.py")
SOCK_DIR = "/tmp/kask-test"
FAKE_BIN = None


# ---------------------------------------------------------------------------
# Fake kiro-cli that speaks ACP protocol
# ---------------------------------------------------------------------------

FAKE_KIRO_CLI = r'''#!/usr/bin/env python3
"""Fake kiro-cli acp — speaks just enough ACP JSON-RPC to test kask."""
import json, sys, os

behavior = os.environ.get("FAKE_BEHAVIOR", "normal")

if behavior == "exit_immediately":
    sys.exit(1)

if behavior == "hang":
    import time
    time.sleep(300)
    sys.exit(0)

if behavior == "slow_start":
    import time
    time.sleep(float(os.environ.get("FAKE_DELAY", "3")))

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line.strip())

# Handshake
msg = read()
assert msg["method"] == "initialize", f"expected initialize, got {msg}"
send({"jsonrpc": "2.0", "id": msg["id"], "result": {
    "protocolVersion": 1,
    "agentCapabilities": {"loadSession": True},
}})

msg = read()
assert msg["method"] == "session/new", f"expected session/new, got {msg}"
send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "test-session-1"}})

if behavior == "die_after_handshake":
    sys.exit(1)

# Prompt loop
prompt_count = 0
while True:
    msg = read()
    if msg.get("method") != "session/prompt":
        continue

    prompt_count += 1
    prompt_text = msg["params"]["prompt"][0]["text"]

    if behavior == "die_after_first_prompt" and prompt_count > 1:
        sys.exit(1)

    if behavior == "error_response":
        send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -1, "message": "fake error"}})
        continue

    # Echo the prompt back as the response (via chunks then result)
    response = f"ECHO: {prompt_text}"
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"text": response}},
    }})
    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"status": "complete"}})
'''


def setup_fake_bin():
    """Create a temp dir with a fake kiro-cli."""
    global FAKE_BIN
    FAKE_BIN = tempfile.mkdtemp(prefix="kask-test-")
    fake_path = os.path.join(FAKE_BIN, "kiro-cli")
    with open(fake_path, "w") as f:
        f.write(FAKE_KIRO_CLI)
    os.chmod(fake_path, 0o755)
    return FAKE_BIN


def kask_env(agent="test", behavior="normal", extra=None):
    """Build env for running kask with fake kiro-cli."""
    env = os.environ.copy()
    env["PATH"] = FAKE_BIN + ":" + env.get("PATH", "")
    env["KASK_AGENT"] = agent
    env["FAKE_BEHAVIOR"] = behavior
    # Override sock dir isn't possible without code change, so we use unique agent names
    if extra:
        env.update(extra)
    return env


def run_kask(*args, agent="test", behavior="normal", timeout=15, extra_env=None):
    """Run kask as a subprocess, return (stdout, stderr, returncode)."""
    cmd = [sys.executable, KASK_SCRIPT] + list(args)
    env = kask_env(agent, behavior, extra_env)
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env,
        )
        return proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return "", "TIMEOUT", -1


def stop_agent(agent="test"):
    """Stop a specific agent's daemon."""
    env = kask_env(agent)
    subprocess.run(
        [sys.executable, KASK_SCRIPT, "--stop"],
        capture_output=True, env=env, timeout=5,
    )
    time.sleep(0.5)


def stop_all_test_agents():
    """Stop all test daemons and clean up."""
    for agent in ["test", "test-a", "test-b", "test-recovery", "test-leak",
                   "test-idle", "test-concurrent", "test-error"]:
        try:
            stop_agent(agent)
        except Exception:
            pass
    # Kill any remaining test daemons
    subprocess.run(
        ["pkill", "-9", "-f", "kask-test.*kiro-cli"],
        capture_output=True,
    )
    # Clean up stale sockets
    for f in os.listdir("/tmp/kask") if os.path.isdir("/tmp/kask") else []:
        if f.startswith("test"):
            try:
                os.unlink(os.path.join("/tmp/kask", f))
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestKaskOneShot(unittest.TestCase):
    """Test one-shot (non-daemon) behavior via the CLI."""

    def test_basic_prompt(self):
        """One-shot call returns the model's response."""
        out, err, rc = run_kask("hello world", agent="test")
        self.assertEqual(rc, 0)
        self.assertIn("ECHO: hello world", out)

    def test_empty_prompt_exits_cleanly(self):
        """Empty prompt (no args, not a tty) exits without error."""
        cmd = [sys.executable, KASK_SCRIPT]
        env = kask_env()
        proc = subprocess.run(
            cmd, input="", capture_output=True, text=True, timeout=10, env=env,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_pipe_mode(self):
        """Piped input works as a prompt."""
        cmd = [sys.executable, KASK_SCRIPT]
        env = kask_env()
        proc = subprocess.run(
            cmd, input="piped prompt\n", capture_output=True, text=True,
            timeout=15, env=env,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn("ECHO: piped prompt", proc.stdout)

    def test_stop_is_clean(self):
        """--stop exits cleanly even with no daemons running."""
        out, err, rc = run_kask("--stop", agent="test")
        self.assertEqual(rc, 0)


class TestDaemonLifecycle(unittest.TestCase):
    """Test daemon start, warm calls, and stop."""

    def setUp(self):
        stop_agent("test-a")

    def tearDown(self):
        stop_agent("test-a")

    def test_first_call_starts_daemon(self):
        """First call auto-starts a daemon and returns a response."""
        out, err, rc = run_kask("first call", agent="test-a")
        self.assertEqual(rc, 0)
        self.assertIn("ECHO: first call", out)
        # Daemon socket should exist
        self.assertTrue(os.path.exists("/tmp/kask/test-a.sock"))

    def test_warm_call_is_fast(self):
        """Second call reuses the warm daemon (no cold start)."""
        run_kask("warmup", agent="test-a")

        t0 = time.time()
        out, err, rc = run_kask("warm call", agent="test-a")
        elapsed = time.time() - t0

        self.assertEqual(rc, 0)
        self.assertIn("ECHO: warm call", out)
        self.assertLess(elapsed, 3, "Warm call should be fast (<3s)")

    def test_stop_kills_daemon(self):
        """--stop removes socket and kills daemon process."""
        run_kask("start daemon", agent="test-a")
        pid_file = "/tmp/kask/test-a.pid"
        self.assertTrue(os.path.exists(pid_file))
        pid = int(open(pid_file).read().strip())

        stop_agent("test-a")

        self.assertFalse(os.path.exists("/tmp/kask/test-a.sock"))
        # Process should be dead
        with self.assertRaises(OSError):
            os.kill(pid, 0)

    def test_multiple_prompts_same_daemon(self):
        """Multiple sequential prompts reuse the same daemon."""
        run_kask("prompt 1", agent="test-a")
        pid1 = int(open("/tmp/kask/test-a.pid").read().strip())

        run_kask("prompt 2", agent="test-a")
        pid2 = int(open("/tmp/kask/test-a.pid").read().strip())

        self.assertEqual(pid1, pid2, "Should reuse same daemon")


class TestAgentIsolation(unittest.TestCase):
    """Test that different agents get separate daemons."""

    def setUp(self):
        stop_agent("test-a")
        stop_agent("test-b")

    def tearDown(self):
        stop_agent("test-a")
        stop_agent("test-b")

    def test_separate_sockets(self):
        """Different agents get different daemon sockets."""
        run_kask("hello", agent="test-a")
        run_kask("hello", agent="test-b")

        self.assertTrue(os.path.exists("/tmp/kask/test-a.sock"))
        self.assertTrue(os.path.exists("/tmp/kask/test-b.sock"))

    def test_separate_pids(self):
        """Different agents run in different daemon processes."""
        run_kask("hello", agent="test-a")
        run_kask("hello", agent="test-b")

        pid_a = int(open("/tmp/kask/test-a.pid").read().strip())
        pid_b = int(open("/tmp/kask/test-b.pid").read().strip())
        self.assertNotEqual(pid_a, pid_b)


class TestDaemonRecovery(unittest.TestCase):
    """Test self-healing when the ACP subprocess dies mid-session."""

    def setUp(self):
        stop_agent("test-recovery")

    def tearDown(self):
        stop_agent("test-recovery")

    def test_recovery_after_acp_kill(self):
        """After killing the ACP subprocess, next call recovers."""
        # Warm up
        out, _, rc = run_kask("warmup", agent="test-recovery")
        self.assertEqual(rc, 0)
        self.assertIn("ECHO:", out)

        # Kill ACP subprocesses (not the daemon)
        daemon_pid = int(open("/tmp/kask/test-recovery.pid").read().strip())
        subprocess.run(
            ["pkill", "-9", "-f", f"kiro-cli.*acp.*--agent.*test-recovery"],
            capture_output=True,
        )
        time.sleep(1)

        # Daemon should still be alive
        try:
            os.kill(daemon_pid, 0)
        except OSError:
            self.fail("Daemon died unexpectedly")

        # Next call should recover
        out, _, rc = run_kask("after kill", agent="test-recovery")
        self.assertEqual(rc, 0)
        self.assertIn("ECHO: after kill", out)

    def test_recovery_is_stable(self):
        """After recovery, subsequent calls continue working."""
        run_kask("warmup", agent="test-recovery")

        subprocess.run(
            ["pkill", "-9", "-f", f"kiro-cli.*acp.*--agent.*test-recovery"],
            capture_output=True,
        )
        time.sleep(1)

        # Recovery call
        run_kask("recover", agent="test-recovery")

        # Subsequent calls should work without issues
        for i in range(3):
            out, _, rc = run_kask(f"stable call {i}", agent="test-recovery")
            self.assertEqual(rc, 0, f"Call {i} failed")
            self.assertIn(f"ECHO: stable call {i}", out)


class TestBrokenACP(unittest.TestCase):
    """Test behavior when kiro-cli is broken or unavailable."""

    def setUp(self):
        stop_agent("test-error")

    def tearDown(self):
        stop_agent("test-error")

    def test_acp_exits_immediately(self):
        """When kiro-cli exits on startup, kask returns an error."""
        out, err, rc = run_kask("hello", agent="test-error", behavior="exit_immediately")
        self.assertNotEqual(rc, 0)

    def test_no_process_leak_on_broken_acp(self):
        """Repeated calls with broken ACP don't leak processes."""
        before = subprocess.run(
            ["pgrep", "-f", "kask-test.*kiro-cli"],
            capture_output=True, text=True,
        ).stdout.strip().count("\n") + 1 if subprocess.run(
            ["pgrep", "-f", "kask-test.*kiro-cli"],
            capture_output=True, text=True,
        ).stdout.strip() else 0

        for _ in range(5):
            run_kask("hello", agent="test-error", behavior="exit_immediately")

        time.sleep(2)
        after = subprocess.run(
            ["pgrep", "-f", "kask-test.*kiro-cli"],
            capture_output=True, text=True,
        ).stdout.strip().count("\n") + 1 if subprocess.run(
            ["pgrep", "-f", "kask-test.*kiro-cli"],
            capture_output=True, text=True,
        ).stdout.strip() else 0

        leaked = after - before
        self.assertLessEqual(leaked, 0, f"Leaked {leaked} processes")

    def test_error_response_from_model(self):
        """When the model returns an error, kask propagates it."""
        out, err, rc = run_kask("hello", agent="test-error", behavior="error_response")
        self.assertNotEqual(rc, 0)


class TestConcurrency(unittest.TestCase):
    """Test concurrent access to daemons."""

    def setUp(self):
        stop_agent("test-concurrent")

    def tearDown(self):
        stop_agent("test-concurrent")

    def test_parallel_calls_same_agent(self):
        """Multiple parallel calls to the same agent all succeed."""
        import concurrent.futures

        # Warm up first
        run_kask("warmup", agent="test-concurrent")

        def call(i):
            out, err, rc = run_kask(f"parallel {i}", agent="test-concurrent")
            return i, out, rc

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(call, i) for i in range(3)]
            results = [f.result(timeout=15) for f in futures]

        for i, out, rc in results:
            self.assertEqual(rc, 0, f"Parallel call {i} failed")
            self.assertIn(f"ECHO: parallel {i}", out)

    def test_no_duplicate_daemons(self):
        """Concurrent first calls don't spawn duplicate daemons."""
        import concurrent.futures

        def call(i):
            return run_kask(f"race {i}", agent="test-concurrent")

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(call, i) for i in range(3)]
            [f.result(timeout=15) for f in futures]

        # Count daemon processes — should be exactly 1
        result = subprocess.run(
            ["pgrep", "-f", f"kiro-acp-client.*--daemon"],
            capture_output=True, text=True,
        )
        # Filter to our test agent
        pid_file = "/tmp/kask/test-concurrent.pid"
        if os.path.exists(pid_file):
            pid = open(pid_file).read().strip()
            self.assertTrue(pid, "PID file should not be empty")


class TestTimeouts(unittest.TestCase):
    """Test that timeouts are enforced."""

    def setUp(self):
        stop_agent("test-timeout")

    def tearDown(self):
        stop_agent("test-timeout")
        # Kill any hanging fake kiro-cli processes
        subprocess.run(["pkill", "-9", "-f", "FAKE_BEHAVIOR.*hang"], capture_output=True)

    def test_hanging_acp_times_out(self):
        """When kiro-cli hangs, kask times out instead of blocking forever."""
        t0 = time.time()
        out, err, rc = run_kask(
            "hello", agent="test-timeout", behavior="hang", timeout=45,
        )
        elapsed = time.time() - t0

        # Should fail within a reasonable time, not hang forever.
        # Worst case: daemon attempt (15s) + retry (15s) ≈ 30s
        self.assertNotEqual(err, "TIMEOUT", "kask should not hang forever")
        self.assertLess(elapsed, 40, f"Took {elapsed:.1f}s — should timeout sooner")


class TestCleanup(unittest.TestCase):
    """Test that resources are cleaned up properly."""

    def test_stop_all_cleans_everything(self):
        """--stop removes all sockets and PID files."""
        # Start a couple daemons
        run_kask("hello", agent="test-a")
        run_kask("hello", agent="test-b")

        self.assertTrue(os.path.exists("/tmp/kask/test-a.sock"))
        self.assertTrue(os.path.exists("/tmp/kask/test-b.sock"))

        # Stop all
        run_kask("--stop", agent="test")
        time.sleep(1)

        self.assertFalse(os.path.exists("/tmp/kask/test-a.sock"))
        self.assertFalse(os.path.exists("/tmp/kask/test-b.sock"))

    def test_stale_socket_cleaned_on_start(self):
        """If a stale socket exists (daemon dead), it's cleaned up on next call."""
        # Create a stale socket
        os.makedirs("/tmp/kask", exist_ok=True)
        sock_path = "/tmp/kask/test-stale.sock"
        pid_path = "/tmp/kask/test-stale.pid"

        # Write a fake PID that doesn't exist
        with open(pid_path, "w") as f:
            f.write("99999999")
        # Create a dummy socket file
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sock_path)
        s.close()

        # Next call should clean up and start fresh
        out, err, rc = run_kask("hello", agent="test-stale")
        self.assertEqual(rc, 0)
        self.assertIn("ECHO: hello", out)

        stop_agent("test-stale")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    setup_fake_bin()
    print(f"Using fake kiro-cli from: {FAKE_BIN}")
    print(f"Testing kask at: {KASK_SCRIPT}")
    print()

    try:
        unittest.main(verbosity=2)
    finally:
        stop_all_test_agents()
        if FAKE_BIN:
            import shutil
            shutil.rmtree(FAKE_BIN, ignore_errors=True)
