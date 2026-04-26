#!/usr/bin/env python3
"""Bidirectional bridge between a TCP port and a Unix socket.

Usage:
  socket-bridge.py tcp-to-unix <tcp_port> <unix_path>
    Listen on TCP port, forward each connection to the Unix socket.

  socket-bridge.py unix-to-tcp <unix_path> <tcp_port>
    Listen on Unix socket, forward each connection to TCP localhost:port.
"""
import socket, os, sys, threading, signal

def relay(a, b):
    try:
        while True:
            d = a.recv(8192)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try: a.close()
        except: pass
        try: b.close()
        except: pass

def bridge(client, connect_fn):
    try:
        peer = connect_fn()
        threading.Thread(target=relay, args=(client, peer), daemon=True).start()
        relay(peer, client)
    except OSError:
        client.close()

def serve_tcp_to_unix(tcp_port, unix_path):
    """Listen TCP, connect to Unix socket for each client."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", int(tcp_port)))
    srv.listen(16)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=bridge, args=(c, lambda: _connect_unix(unix_path)), daemon=True).start()

def serve_unix_to_tcp(unix_path, tcp_port):
    """Listen Unix socket, connect to TCP for each client."""
    if os.path.exists(unix_path):
        os.unlink(unix_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(unix_path)
    os.chmod(unix_path, 0o700)
    srv.listen(16)
    port = int(tcp_port)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=bridge, args=(c, lambda: _connect_tcp(port)), daemon=True).start()

def _connect_unix(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    return s

def _connect_tcp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", port))
    return s

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    if mode == "tcp-to-unix" and len(sys.argv) == 4:
        serve_tcp_to_unix(sys.argv[2], sys.argv[3])
    elif mode == "unix-to-tcp" and len(sys.argv) == 4:
        serve_unix_to_tcp(sys.argv[2], sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
