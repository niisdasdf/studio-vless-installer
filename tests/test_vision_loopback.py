#!/usr/bin/env python3
"""Optional real Vision/iOS-uTLS integration test; never touches a VPS.

Requires an explicitly supplied trusted sing-box and network access to the
REALITY target (default www.kernel.org:443). Both proxy listeners and the HTTP
echo server bind only 127.0.0.1 on random high ports. Keys stay in a private
temporary directory; all children and files are removed on exit.
"""
import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid


class Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"vision-loopback-ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def free_port(excluding=()):
    while True:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port >= 1024 and port not in excluding:
            return port


def receive(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise RuntimeError("unexpected_eof")
        data += part
    return data


def wait_listener(port, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("core_exited_before_listener")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("listener_timeout")


def proxy_http(socks_port, echo_port):
    with socket.create_connection(("127.0.0.1", socks_port), timeout=20) as sock:
        sock.settimeout(20)
        sock.sendall(b"\x05\x01\x00")
        if receive(sock, 2) != b"\x05\x00":
            raise RuntimeError("socks_auth_failed")
        sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo_port))
        header = receive(sock, 4)
        if header[:2] != b"\x05\x00":
            raise RuntimeError("socks_connect_failed")
        size = {1: 4, 4: 16}.get(header[3])
        if header[3] == 3:
            size = receive(sock, 1)[0]
        if size is None:
            raise RuntimeError("socks_address_failed")
        receive(sock, size + 2)
        sock.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            part = sock.recv(4096)
            if not part:
                break
            data += part
            if len(data) > 65536:
                raise RuntimeError("unexpected_http_size")
    if not data.startswith(b"HTTP/1.0 200 ") or data.split(b"\r\n\r\n", 1)[-1] != b"vision-loopback-ok\n":
        raise RuntimeError("http_echo_mismatch")
    return {"http_status": 200, "echo_match": True, "bytes": len(data)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--target", default="www.kernel.org")
    args = parser.parse_args()
    core = str(args.core.resolve(strict=True))
    version = subprocess.check_output([core, "version"], text=True).splitlines()[0]
    processes, logs, sensitive = [], [], []
    stage, result = "prepare", None
    echo = None
    with tempfile.TemporaryDirectory(prefix="vision-loopback-") as directory:
        root = Path(directory)
        os.chmod(root, 0o700)
        try:
            pair = subprocess.check_output([core, "generate", "reality-keypair"], text=True)
            keys = dict(line.split(": ", 1) for line in pair.strip().splitlines())
            user, short_id = str(uuid.uuid4()), secrets.token_hex(8)
            sensitive = [*keys.values(), user, short_id]
            echo = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Echo)
            threading.Thread(target=echo.serve_forever, daemon=True).start()
            echo_port = echo.server_port
            server_port = free_port((echo_port,))
            socks_port = free_port((echo_port, server_port))
            inbound = {"type": "vless", "tag": "vision", "listen": "127.0.0.1", "listen_port": server_port,
                       "tcp_fast_open": False, "users": [{"uuid": user, "flow": "xtls-rprx-vision"}],
                       "multiplex": {"enabled": False}, "tls": {"enabled": True, "server_name": args.target,
                       "reality": {"enabled": True, "handshake": {"server": args.target, "server_port": 443},
                                   "private_key": keys["PrivateKey"], "short_id": [short_id]}}}
            outbound = {"type": "vless", "tag": "vision", "server": "127.0.0.1", "server_port": server_port,
                        "uuid": user, "flow": "xtls-rprx-vision", "tcp_fast_open": False,
                        "multiplex": {"enabled": False}, "tls": {"enabled": True, "insecure": False,
                        "server_name": args.target, "utls": {"enabled": True, "fingerprint": "ios"},
                        "reality": {"enabled": True, "public_key": keys["PublicKey"], "short_id": short_id}}}
            configs = {"server": {"log": {"level": "warn"}, "inbounds": [inbound],
                                  "outbounds": [{"type": "direct", "tag": "direct"}]},
                       "client": {"log": {"level": "warn"}, "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": socks_port}],
                                  "outbounds": [outbound]}}
            for name, config in configs.items():
                path = root / (name + ".json")
                path.write_text(json.dumps(config))
                os.chmod(path, 0o600)
                stage = name + "_check"
                subprocess.run([core, "check", "-c", str(path)], check=True, capture_output=True, timeout=10)
                log_path = root / (name + ".log")
                log = log_path.open("wb")
                logs.append((name, log_path, log))
                stage = name + "_start"
                process = subprocess.Popen([core, "run", "-c", str(path)], stdout=log, stderr=subprocess.STDOUT)
                processes.append(process)
                wait_listener(server_port if name == "server" else socks_port, process)
            stage = "socks_http_via_vision"
            result = {"ok": True, "version": version, "target": args.target, "flow": "xtls-rprx-vision",
                      "fingerprint": "ios", "loopback_only": True, **proxy_http(socks_port, echo_port)}
        except Exception as error:
            result = {"ok": False, "version": version, "stage": stage, "error": type(error).__name__}
            if isinstance(error, RuntimeError):
                result["reason"] = str(error)
            tails = {}
            for name, path, log in logs:
                log.flush()
                text = path.read_text(errors="replace")[-4000:]
                for secret in sensitive:
                    text = text.replace(secret, "[redacted]")
                if text.strip():
                    tails[name] = text
            if tails:
                result["diagnostic_logs"] = tails
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            for _name, _path, log in logs:
                log.close()
            if echo is not None:
                echo.shutdown()
                echo.server_close()
    result["cleanup_complete"] = True
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
