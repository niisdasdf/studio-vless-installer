#!/usr/bin/env python3
"""Scoped VLESS + Reality + Vision installer for a new Debian/Ubuntu VPS.

No shell evaluation, remote installer execution, automatic core updates, firewall
rewrites, SSH changes, or modification of /etc/sing-box.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import shutil
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

APP = "studio-vless-v1"
VERSION = "1.14.3"
# Audited official release, 2026-10-23. A new version requires a new reviewed
# manifest. These are archive digests, not an independent publisher signature.
ARCHIVES = {
    "amd64": "e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee",
    "arm64": "29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e",
}
SERVICE = "studio-vless.service"
DEFAULT_SNI = "addons.mozilla.org"
NONPUBLIC = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
             "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
             "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]


class Problem(Exception):
    pass


def checked(argv, *, timeout=45):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                            timeout=timeout, check=False)
    if result.returncode:
        # Core validation errors can contain configuration data. Do not dump it.
        raise Problem(f"命令未成功：{Path(str(argv[0])).name} {argv[1]}。未输出可能含密钥的原始错误。")
    return result.stdout


def optional_command(argv, timeout=20):
    try:
        return subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                              timeout=timeout, check=False, env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return None


def prepare_clock():
    """Use the OS's existing NTP provider; do not replace chrony or set the clock manually."""
    before = optional_command(["timedatectl", "show", "--property=NTP", "--property=NTPSynchronized"])
    if before is None or before.returncode:
        return {"status": "unverified", "detail": "系统未提供 timedatectl；TLS 证书检查仍强制执行。"}
    if "NTP=yes" not in before.stdout:
        optional_command(["timedatectl", "set-ntp", "true"])
    after = optional_command(["timedatectl", "show", "--property=NTP", "--property=NTPSynchronized"])
    values = dict(line.split("=", 1) for line in (after.stdout if after and not after.returncode else before.stdout).splitlines() if "=" in line)
    return {"status": "enabled" if values.get("NTP") == "yes" else "unverified",
            "synchronized": values.get("NTPSynchronized") == "yes"}


def configure_bbr(root=Path("/"), command=optional_command):
    """Set only two owned sysctls, preserving unrelated files and previous values."""
    target = root / "etc/sysctl.d/90-studio-vless-bbr.conf"
    content = f"# Managed by {APP}\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n"
    if os.path.lexists(target) and (target.is_symlink() or target.read_text() != content):
        return {"status": "skipped", "detail": "同名 sysctl 配置已存在，不覆盖。"}
    def read(name):
        result = command(["sysctl", "-n", name])
        return result.stdout.strip() if result and result.returncode == 0 else None
    available = read("net.ipv4.tcp_available_congestion_control") or ""
    if "bbr" not in available.split():
        command(["modprobe", "tcp_bbr"])
        available = read("net.ipv4.tcp_available_congestion_control") or ""
    if "bbr" not in available.split():
        return {"status": "unsupported", "detail": "当前内核不支持 BBR，保留原拥塞控制。"}
    names = ["net.core.default_qdisc", "net.ipv4.tcp_congestion_control"]
    previous = {name: read(name) for name in names}
    if any(value is None for value in previous.values()):
        return {"status": "skipped", "detail": "无法读取原 TCP 参数，未修改。"}
    changed = []
    try:
        for name, value in zip(names, ["fq", "bbr"]):
            result = command(["sysctl", "-w", name + "=" + value])
            if result is None or result.returncode:
                raise Problem("当前环境不允许设置 TCP 参数。")
            changed.append(name)
        atomic_write(target, content.encode(), 0o644)
        return {"status": "enabled", "qdisc": "fq", "algorithm": "bbr", "previous": previous}
    except (OSError, Problem):
        restored = True
        for name in reversed(changed):
            result = command(["sysctl", "-w", name + "=" + previous[name]])
            restored = restored and result is not None and result.returncode == 0
        return {"status": "skipped" if restored else "attention", "detail": "BBR 设置失败，已尝试恢复原参数。"}


def configure_host_firewall(port, command=optional_command, which=shutil.which):
    """Only add this authenticated server port to an already-active UFW policy."""
    ufw = which("ufw")
    if ufw:
        status = command([ufw, "status"])
        if status and status.returncode == 0 and "Status: active" in status.stdout:
            # Never remove rules, enable UFW, reset policies, or override explicit denies.
            for line in status.stdout.splitlines():
                if re.match(rf"^{port}(?:/tcp)?\s", line.strip()) and re.search(r"\b(DENY|REJECT)\b", line):
                    return {"status": "attention", "manager": "ufw", "detail": f"已有 TCP {port} 拒绝规则，保留原规则，需管理员处理。"}
            result = command([ufw, "allow", str(port) + "/tcp", "comment", APP])
            if result and result.returncode == 0:
                return {"status": "allowed", "manager": "ufw", "port": port, "protocol": "tcp"}
            return {"status": "attention", "manager": "ufw", "detail": "UFW 放行失败，原有 SSH 和其他规则未删除。"}
    nft = which("nft")
    if nft:
        result = command([nft, "-j", "list", "ruleset"])
        if result and result.returncode == 0:
            try:
                for item in json.loads(result.stdout).get("nftables", []):
                    chain = item.get("chain", {})
                    if chain.get("hook") == "input":
                        return {"status": "attention", "detail": "发现自定义主机输入防火墙，未改写；需核对代理端口。"}
            except (TypeError, ValueError):
                pass
    return {"status": "no_active_ufw", "detail": "未发现已启用的 UFW；云安全组仍需单独放行。"}


def atomic_write(path: Path, data: bytes, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix=".new-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def write_json(path, obj):
    atomic_write(path, (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode())


def read_json(path):
    return json.loads(path.read_text())


def public_ipv4(value):
    try:
        ip = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        raise Problem("请填写 VPS 的公网 IPv4 地址。") from None
    if not ip.is_global:
        raise Problem("需要公网 IPv4；不能填写内网、回环或示例地址。")
    return str(ip)


def domain(value):
    value = value.strip().lower().rstrip(".")
    if len(value) > 253 or "." not in value:
        raise Problem("Reality 握手域名格式无效。")
    for label in value.split("."):
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
            raise Problem("握手域名只能是有效的 ASCII 域名，不能带协议、端口或路径。")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise Problem("握手域名不能直接填写 IP。")


def port_number(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]{1,5}", str(value)):
        raise Problem("端口应为 1–65535 的整数。")
    number = int(value)
    if not 1 <= number <= 65535:
        raise Problem("端口应为 1–65535 的整数。")
    return number


def check_handshake(sni):
    # Probe the exact target from the VPS, with certificate verification and TLS1.3.
    records = socket.getaddrinfo(sni, 443, type=socket.SOCK_STREAM)
    if not records or any(not ipaddress.ip_address(r[4][0]).is_global for r in records):
        raise Problem("握手域名没有全部解析到公网地址，拒绝使用。")
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2", "http/1.1"])
    errors = []
    # Avoid slow IPv6 fallback on an IPv4-only VPS.
    for family, socktype, proto, _, address in sorted(records, key=lambda r: r[0] != socket.AF_INET):
        try:
            with socket.socket(family, socktype, proto) as raw:
                raw.settimeout(5)
                raw.connect(address)
                with context.wrap_socket(raw, server_hostname=sni) as tls:
                    if tls.version() == "TLSv1.3":
                        return
        except OSError as error:
            errors.append(type(error).__name__)
    raise Problem("VPS 无法验证握手域名的 TLS 1.3 连接，请更换域名或检查网络和系统时间。")


def make_state(binary: Path, server, port, sni, previous=None):
    if previous:
        result = copy.deepcopy(previous)
    else:
        keys = checked([binary, "generate", "reality-keypair"])
        private = re.search(r"PrivateKey:\s*([A-Za-z0-9_-]{43})", keys)
        public = re.search(r"PublicKey:\s*([A-Za-z0-9_-]{43})", keys)
        if not private or not public:
            raise Problem("无法解析 Reality 密钥对。")
        result = {"app": APP, "version": VERSION, "uuid": str(uuid.uuid4()),
                  "private_key": private[1], "public_key": public[1],
                  "short_id": secrets.token_hex(8)}
    result.update(server=public_ipv4(server), port=port_number(port), sni=domain(sni))
    return result


def server_config(state):
    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {"servers": [{"type": "https", "tag": "resolver", "server": "1.1.1.1",
                              "tls": {"enabled": True, "server_name": "cloudflare-dns.com"}}],
                "final": "resolver", "strategy": "ipv4_only"},
        "inbounds": [{"type": "vless", "tag": "vless-reality", "listen": "0.0.0.0",
                      "listen_port": state["port"],
                      "users": [{"name": "studio", "uuid": state["uuid"], "flow": "xtls-rprx-vision"}],
                      "tls": {"enabled": True, "server_name": state["sni"],
                              "reality": {"enabled": True,
                                          "handshake": {"server": state["sni"], "server_port": 443},
                                          "private_key": state["private_key"],
                                          "short_id": [state["short_id"]]}}}],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"default_domain_resolver": "resolver", "final": "direct",
                  "rules": [{"action": "resolve", "strategy": "ipv4_only"},
                            {"ip_cidr": NONPUBLIC, "action": "reject"}]},
    }


def share_link(state):
    query = urllib.parse.urlencode({"encryption": "none", "security": "reality", "sni": state["sni"],
                                   "fp": "chrome", "pbk": state["public_key"], "sid": state["short_id"],
                                   "type": "tcp", "flow": "xtls-rprx-vision"})
    return f"vless://{state['uuid']}@{state['server']}:{state['port']}?{query}#Studio-VLESS"


def render_qr(state, directory, *, display=True):
    encoder = shutil.which("qrencode")
    if not encoder:
        raise Problem("缺少二维码工具 qrencode，请使用一键安装脚本自动准备依赖，或安装后运行 qr。")
    # Send the credential through stdin; do not expose it in a process argv.
    payload = share_link(state).encode("utf-8")
    png = subprocess.run([encoder, "-t", "PNG", "-m", "4", "-s", "6", "-o", "-"],
                         input=payload, capture_output=True, timeout=15, check=False)
    if png.returncode or not png.stdout.startswith(b"\x89PNG\r\n\x1a\n") or len(png.stdout) > 2_000_000:
        raise Problem("二维码图片未能生成。分享链接仍可正常使用。")
    path = directory / "share-qr.png"
    atomic_write(path, png.stdout)
    if display:
        terminal = subprocess.run([encoder, "-t", "ANSIUTF8", "-m", "4"],
                                  input=payload, capture_output=True, timeout=15, check=False)
        if terminal.returncode:
            raise Problem(f"终端二维码未能显示，图片已保存在 {path}。")
        print("\n用客户端的“扫描二维码”导入（若终端换行，请放宽窗口或使用 PNG 图片）：")
        print(terminal.stdout.decode("utf-8"))
        print(f"二维码图片：{path}")
        print("二维码与分享链接都包含节点凭据，请私下保存。")
    return path


def show_qr_if_available(manager, state):
    try:
        render_qr(state, manager.generation())
    except (Problem, OSError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, Problem) else "二维码未能生成；服务和上方分享链接不受影响。")


def detect_public_ipv4():
    # Ignore environment HTTP proxy variables: detect this VPS's actual exit.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for url in ("https://api.ipify.org", "https://checkip.amazonaws.com"):
        try:
            with opener.open(url, timeout=6) as response:
                return public_ipv4(response.read(128).decode().strip())
        except (Problem, OSError, ValueError):
            pass
    return None


def guided_values(args, *, ask=input, detect=detect_public_ipv4, port_check=None):
    def prompt(label, default, validator):
        while True:
            answer = ask(label + (f" [{default}]" if default else "") + "：").strip()
            value = answer or default
            if not value:
                print("这一项不能为空，请填写 VPS 商家显示的公网 IPv4。")
                continue
            try:
                return validator(value)
            except Problem as error:
                print("请重新选择：" + str(error))
    detected = args.server or detect()
    print("\n推荐配置：VLESS + Reality + Vision；保留固定版本和下载校验。")
    print("检测到的公网 IP 仍需与你购买的 VPS 信息核对；不能从检测结果推断它一定是静态 IP。")
    server = prompt("公网 IPv4，正确就按回车", detected, public_ipv4)
    def free_port(value):
        value = port_number(value)
        (port_check or check_port)(value)
        return value
    port = prompt("监听 TCP 端口，通常直接回车", args.port or "443", free_port)
    sni = prompt("握手域名，通常直接回车", args.sni or DEFAULT_SNI, domain)
    print(f"\n准备安装：{server}:{port}；握手域名 {sni}。")
    print("将创建独立服务，生成分享链接和二维码。")
    while True:
        answer = ask("开始安装？[Y/n]：").strip().lower()
        if answer in {"", "y", "yes"}:
            return server, port, sni
        if answer in {"n", "no"}:
            return None
        print("按回车开始，或输入 n 退出。")


def client_config(state, socks_port):
    return {"log": {"disabled": True},
            "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": socks_port}],
            "outbounds": [{"type": "vless", "tag": "probe", "server": "127.0.0.1",
                           "server_port": state["port"], "uuid": state["uuid"],
                           "flow": "xtls-rprx-vision",
                           "tls": {"enabled": True, "server_name": state["sni"],
                                   "utls": {"enabled": True, "fingerprint": "chrome"},
                                   "reality": {"enabled": True, "public_key": state["public_key"],
                                               "short_id": state["short_id"]}}}],
            "route": {"final": "probe"}}


def receive(sock, count):
    value = b""
    while len(value) < count:
        part = sock.recv(count - len(value))
        if not part:
            raise Problem("SOCKS 连接提前关闭。")
        value += part
    return value


def socks_connect(port, host, target_port=443):
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    try:
        sock.sendall(b"\x05\x01\x00")
        if receive(sock, 2) != b"\x05\x00":
            raise Problem("SOCKS 协商失败。")
        encoded = host.encode("ascii")
        if len(encoded) > 253:
            raise Problem("测试域名过长。")
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", target_port))
        response = receive(sock, 4)
        if response[:2] != b"\x05\x00":
            raise Problem("代理拒绝或无法建立测试连接。")
        count = {1: 4, 4: 16}.get(response[3])
        if response[3] == 3:
            count = receive(sock, 1)[0]
        if count is None:
            raise Problem("SOCKS 返回的地址无效。")
        receive(sock, count + 2)
        return sock
    except BaseException:
        sock.close()
        raise


def proxy_public_ip(port):
    with socks_connect(port, "api.ipify.org") as raw:
        with ssl.create_default_context().wrap_socket(raw, server_hostname="api.ipify.org") as tls:
            tls.sendall(b"GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n")
            response = http.client.HTTPResponse(tls)
            response.begin()
            if response.status != 200:
                raise Problem("HTTPS 出口测试服务未正常响应。")
            return public_ipv4(response.read(128).decode().strip())


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_port(process, port):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        if process.poll() is not None:
            raise Problem("临时测试核心未能启动。")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise Problem("等待临时测试端口超时。")


@contextlib.contextmanager
def running_core(binary, config):
    with tempfile.TemporaryDirectory(prefix="studio-probe-") as folder:
        path = Path(folder) / "config.json"
        write_json(path, config)
        checked([binary, "check", "-c", path])
        process = subprocess.Popen([str(binary), "run", "-c", str(path)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def tunnel_check(binary, state, expected=None):
    socks_port = unused_port()
    with running_core(binary, client_config(state, socks_port)) as process:
        wait_port(process, socks_port)
        observed = proxy_public_ip(socks_port)
    if expected and observed != expected:
        raise Problem(f"实际出口 {observed} 与填写的 VPS IP {expected} 不同；没有将它标记为固定出口测试通过。")
    return observed


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urllib.parse.urlsplit(newurl)
        if url.scheme != "https" or url.hostname not in {
            "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
        }:
            raise Problem("拒绝不在允许列表中的下载跳转。")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def extract_binary(archive, arch, destination):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVES[arch]:
        raise Problem("官方程序 SHA-256 不匹配，拒绝解压或执行。")
    member_name = f"sing-box-{VERSION}-linux-{arch}/sing-box"
    with tarfile.open(archive, "r:gz") as tar:
        members = [entry for entry in tar.getmembers() if entry.name == member_name]
        if len(members) != 1 or not members[0].isfile() or not 0 < members[0].size < 160_000_000:
            raise Problem("压缩包中的程序不符合预期。")
        stream = tar.extractfile(members[0])
        if stream is None:
            raise Problem("无法读取程序。")
        with stream:
            atomic_write(destination, stream.read(), 0o755)


def system_unit(binary):
    return f"""# Managed by {APP}
[Unit]
Description=Studio VLESS Reality Vision
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
DynamicUser=yes
User=studio-vless
LoadCredential=config.json:/etc/studio-vless/current/config.json
ExecStartPre={binary} check -c ${{CREDENTIALS_DIRECTORY}}/config.json
ExecStart={binary} run -c ${{CREDENTIALS_DIRECTORY}}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
LogRateLimitIntervalSec=30s
LogRateLimitBurst=100

[Install]
WantedBy=multi-user.target
"""


class Manager:
    def __init__(self, root=Path("/"), runner=checked):
        root = root.resolve()
        self.root = root
        self.runner = runner
        self.base = root / "opt/studio-vless"
        self.etc = root / "etc/studio-vless"
        self.unit = root / "etc/systemd/system" / SERVICE
        self.binary = self.base / "releases" / VERSION / "sing-box"

    def owned(self, folder):
        marker = folder / "OWNER"
        return (not folder.is_symlink() and marker.is_file() and not marker.is_symlink()
                and folder.stat().st_uid == os.geteuid() and marker.stat().st_uid == os.geteuid()
                and not folder.stat().st_mode & 0o022 and not marker.stat().st_mode & 0o022
                and marker.read_text().strip() == APP)

    def initialize(self):
        for folder, mode in [(self.base, 0o755), (self.etc, 0o700)]:
            if os.path.lexists(folder) and not self.owned(folder):
                raise Problem(f"{folder} 已存在且不属于此安装器，拒绝覆盖。")
        if os.path.lexists(self.unit):
            raise Problem("同名 systemd 服务已经存在，拒绝覆盖。")
        # Detect alternate unit locations as well, without modifying them.
        for directory in ("usr/lib/systemd/system", "lib/systemd/system", "run/systemd/system"):
            if os.path.lexists(self.root / directory / SERVICE):
                raise Problem("发现同名系统服务，拒绝覆盖。")
        for directory in ("etc/systemd/system", "usr/lib/systemd/system", "lib/systemd/system", "run/systemd/system"):
            if os.path.lexists(self.root / directory / (SERVICE + ".d")):
                raise Problem("发现同名服务的额外覆盖配置，拒绝自动安装。")
        for folder, mode in [(self.base, 0o755), (self.etc, 0o700)]:
            folder.mkdir(parents=True, exist_ok=True, mode=mode)
            folder.chmod(mode)
            atomic_write(folder / "OWNER", (APP + "\n").encode())
        (self.etc / "generations").mkdir(mode=0o700, exist_ok=True)

    def require_owned(self):
        if not self.owned(self.etc) or not self.owned(self.base):
            raise Problem("未发现此脚本管理的安装。它不会接管其他脚本的服务。")

    def generation(self, name="current"):
        path = self.etc / name
        if not path.is_symlink():
            return None
        resolved = path.resolve(strict=True)
        if resolved.parent != (self.etc / "generations").resolve() or not re.fullmatch(r"[0-9]{14}-[a-f0-9]{12}", resolved.name):
            raise Problem("配置指针不是有效的本地配置代次。")
        return resolved

    def select(self, name, generation):
        if generation is None:
            (self.etc / name).unlink(missing_ok=True)
            return
        temporary = self.etc / (".pointer-" + secrets.token_hex(8))
        try:
            temporary.symlink_to(Path("generations") / generation.name)
            os.replace(temporary, self.etc / name)
        finally:
            temporary.unlink(missing_ok=True)

    def state(self):
        self.require_owned()
        generation = self.generation()
        if generation is None:
            raise Problem("安装尚未完成，没有可用配置。")
        state = read_json(generation / "state.json")
        if state.get("app") != APP or state.get("version") != VERSION:
            raise Problem("配置版本不属于当前安装器，拒绝自动处理。")
        return state

    def download(self, arch):
        for directory in (self.base / "releases", self.binary.parent):
            if directory.is_symlink():
                raise Problem("程序目录不能是外部符号链接。")
            directory.mkdir(exist_ok=True, mode=0o755)
            directory.chmod(0o755)  # DynamicUser must be able to traverse both.
        # Always verify a fresh official archive before installing/replacing code.
        with tempfile.TemporaryDirectory(prefix="studio-download-") as temporary:
            archive = Path(temporary) / "core.tar.gz"
            url = f"https://github.com/SagerNet/sing-box/releases/download/v{VERSION}/sing-box-{VERSION}-linux-{arch}.tar.gz"
            opener = urllib.request.build_opener(HTTPSRedirect(), urllib.request.ProxyHandler({}))
            with opener.open(url, timeout=30) as response, archive.open("wb") as output:
                count = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    count += len(chunk)
                    if count > 120_000_000:
                        raise Problem("下载大小超出预期。")
                    output.write(chunk)
            extract_binary(archive, arch, self.binary)
        atomic_write(self.binary.parent / "binary.sha256", hashlib.sha256(self.binary.read_bytes()).hexdigest().encode())
        version = self.runner([self.binary, "version"])
        if f"sing-box version {VERSION}\n" not in version:
            raise Problem("程序版本与固定版本不一致。")

    def stage(self, state):
        name = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + secrets.token_hex(6)
        generation = self.etc / "generations" / name
        generation.mkdir(mode=0o700)
        write_json(generation / "state.json", state)
        write_json(generation / "config.json", server_config(state))
        atomic_write(generation / "share-link.txt", (share_link(state) + "\n").encode())
        self.runner([self.binary, "check", "-c", generation / "config.json"])
        return generation

    def service(self, *args):
        return self.runner(["systemctl", *args], timeout=45)

    def activate(self, generation, *, health=tunnel_check, new=False):
        old = self.generation()
        old_previous = self.generation("previous")
        if new and old is not None:
            raise Problem("已有配置，拒绝重新生成身份。需要改端口或域名请用 reconfigure。")
        if old is not None and read_json(old / "config.json") != server_config(read_json(old / "state.json")):
            raise Problem("当前配置含脚本以外的手动修改，拒绝自动覆盖；请先备份并人工检查。")
        candidate = read_json(generation / "state.json")
        if candidate.get("app") != APP or candidate.get("version") != VERSION or read_json(generation / "config.json") != server_config(candidate):
            raise Problem("待启用的配置代次不符合当前安装器的完整配置，拒绝切换。")
        if not new:
            if self.unit.is_symlink() or self.unit.read_text() != system_unit(self.binary):
                raise Problem("服务文件被手动修改，拒绝覆盖；请先人工检查。")
            for directory in ("etc/systemd/system", "usr/lib/systemd/system", "lib/systemd/system", "run/systemd/system"):
                if os.path.lexists(self.root / directory / (SERVICE + ".d")):
                    raise Problem("发现额外的服务覆盖配置，请先人工检查。")
        enabled = False
        try:
            if new:
                atomic_write(self.unit, system_unit(self.binary).encode(), 0o644)
                self.service("daemon-reload")
            self.select("current", generation)
            if new:
                enabled = True
                self.service("enable", "--now", SERVICE)
            else:
                self.service("reset-failed", SERVICE)
                self.service("restart", SERVICE)
            self.service("is-active", "--quiet", SERVICE)
            pid_text = self.service("show", "--property=MainPID", "--value", SERVICE).strip()
            if pid_text:  # Unit fixtures return empty; a real systemd manager returns a PID.
                if not pid_text.isdigit() or int(pid_text) == 0:
                    raise Problem("未找到代理服务主进程。")
                proc = Path("/proc") / pid_text / "status"
                uid = re.search(r"^Uid:\s*(\d+)", proc.read_text(), re.M)
                if not uid or int(uid[1]) == 0:
                    raise Problem("代理服务没有按预期使用非 root 身份运行。")
            state = read_json(generation / "state.json")
            # Retry short service startup / transient test endpoint failures.
            for attempt in range(3):
                try:
                    health(self.binary, state, state["server"])
                    break
                except (Problem, OSError, TimeoutError, http.client.HTTPException):
                    if attempt == 2:
                        raise
                    time.sleep(1)
            self.service("is-active", "--quiet", SERVICE)
            if old is not None:
                self.select("previous", old)
        except BaseException as original:
            # Restore the precise previous generation, including all credentials.
            self.select("current", old)
            self.select("previous", old_previous)
            try:
                if new:
                    if enabled:
                        self.service("disable", "--now", SERVICE)
                    if self.unit.exists() and self.unit.read_text() == system_unit(self.binary):
                        self.unit.unlink()
                    self.service("daemon-reload")
                elif old is not None:
                    self.service("restart", SERVICE)
                    self.service("is-active", "--quiet", SERVICE)
            except BaseException:
                raise Problem("操作失败，配置指针已恢复，但旧服务未能恢复运行。请检查服务日志；备份仍保留。") from original
            if isinstance(original, (KeyboardInterrupt, SystemExit)):
                raise
            reason = str(original) if isinstance(original, Problem) else type(original).__name__
            raise Problem("安装或配置未通过检查，已恢复原配置；首次安装的服务已撤销。原因：" + reason + "。服务日志：journalctl -u studio-vless.service -n 60 --no-pager") from original


def platform_check():
    if platform.system() != "Linux" or os.geteuid() != 0:
        raise Problem("安装和管理命令只能在 VPS 的 Linux 系统中以 root/sudo 运行；不是在 Mac 或 R3S 上运行。")
    values = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    supported = {"debian": {"12", "13"}, "ubuntu": {"22.04", "24.04"}}
    if values.get("VERSION_ID") not in supported.get(values.get("ID"), set()) or not Path("/run/systemd/system").is_dir():
        raise Problem("本版支持使用 systemd 的 Debian 12/13、Ubuntu 22.04/24.04。")
    machine = platform.machine()
    arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine)
    if not arch or not shutil.which("systemctl"):
        raise Problem("需要 amd64/arm64 架构和 systemd。")
    return arch


@contextlib.contextmanager
def install_lock():
    fd = os.open("/run/lock/studio-vless.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != 0 or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode):
            raise Problem("锁文件所有者或权限异常，拒绝使用。")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Problem("另一个安装或检查任务正在进行。") from None
        yield
    finally:
        os.close(fd)


def check_port(port):
    try:
        with socket.socket() as listener:
            listener.bind(("0.0.0.0", port))
    except OSError:
        raise Problem(f"TCP {port} 已被占用或不可绑定；不会替你关闭其他服务或偷偷换端口。") from None


def parser():
    result = argparse.ArgumentParser(description="新 VPS 专用：VLESS + Reality + Vision 安装器（不接管旧脚本配置）。")
    commands = result.add_subparsers(dest="command", required=True)
    for name, helptext in [("install", "首次安装"), ("reconfigure", "保留身份，修改 IP/端口/握手域名")]:
        sub = commands.add_parser(name, help=helptext)
        sub.add_argument("--server", help="VPS 固定公网 IPv4")
        sub.add_argument("--port", help="TCP 监听端口，首次默认 443")
        sub.add_argument("--sni", help=f"Reality 握手域名，首次默认 {DEFAULT_SNI}")
        if name == "install":
            sub.add_argument("--guided", action="store_true", help="中文向导：检测 IP，回车使用默认选项")
    for name, helptext in [("status", "查看运行状态，不输出分享链接"), ("link", "显示现有分享链接"),
                           ("check", "检查配置并完成本机协议/HTTPS 出口测试"), ("rollback", "恢复上一次成功配置"),
                           ("backup", "备份此安装器自己的配置和密钥"), ("qr", "显示分享链接及可扫描二维码"),
                           ("doctor", "重新检查服务、权限、协议、出口并保存验收报告")]:
        commands.add_parser(name, help=helptext)
    return result


def write_acceptance(manager, state, *, runtime=None, protocol_passed=False):
    properties = optional_command(["systemctl", "show", SERVICE, "--property=ActiveState",
                                   "--property=SubState", "--property=MainPID", "--property=User",
                                   "--property=DynamicUser", "--property=NoNewPrivileges", "--property=Restart"])
    service = dict(line.split("=", 1) for line in (properties.stdout if properties and not properties.returncode else "").splitlines() if "=" in line)
    enabled = optional_command(["systemctl", "is-enabled", SERVICE])
    clock = optional_command(["timedatectl", "show", "--property=NTP", "--property=NTPSynchronized"])
    time_status = dict(line.split("=", 1) for line in (clock.stdout if clock and not clock.returncode else "").splitlines() if "=" in line)
    cc = optional_command(["sysctl", "-n", "net.ipv4.tcp_congestion_control"])
    certificate = ssl.get_default_verify_paths()
    generation = manager.generation()
    png = generation / "share-qr.png"
    report = {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "core_version": VERSION, "server": state["server"], "tcp_port": state["port"],
        "protocol": "VLESS + Reality + Vision", "handshake_sni": state["sni"],
        "identity": "Reality 公私钥；无需自有域名证书和 ACME 续签",
        "ca_trust_available": bool(certificate.cafile or certificate.capath),
        "server_dns": "Cloudflare DoH (certificate verification enabled)",
        "service": service, "boot_enabled": bool(enabled and enabled.returncode == 0),
        "system_time": time_status,
        "tcp_congestion_control": cc.stdout.strip() if cc and not cc.returncode else "unverified",
        "config_private": stat.S_IMODE((generation / "config.json").stat().st_mode) == 0o600,
        "qr_png_generated": png.is_file() and png.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"),
        "local_vless_reality_vision_https_passed": protocol_passed,
        "cloud_security_group_verified": False,
        "nanchang_r3s_verified": False,
        "runtime_setup": runtime or {},
    }
    report["local_deployment_checks_passed"] = (
        service.get("ActiveState") == "active" and service.get("DynamicUser") == "yes"
        and service.get("NoNewPrivileges") == "yes" and report["boot_enabled"]
        and report["ca_trust_available"] and report["config_private"] and report["qr_png_generated"]
        and protocol_passed)
    destination = generation / "acceptance.json"
    write_json(destination, report)
    print(f"\n安装验收报告：{destination}")
    print("本机安装验收：" + ("通过" if report["local_deployment_checks_passed"] else "有待处理项，运行 doctor 查看"))
    print(f"开机自启：{'已启用' if report['boot_enabled'] else '未通过'}；服务低权限：{service.get('DynamicUser', '未验证')}；TCP 拥塞控制：{report['tcp_congestion_control']}。")
    for name, result in (runtime or {}).items():
        print(f"{name}：{result.get('status', 'unverified')}" + (f"，{result['detail']}" if result.get('detail') else ""))
    print("云安全组和南昌 R3S 的公网连通性：等待实测。")
    return report


def main(argv=None):
    args = parser().parse_args(argv)
    arch = platform_check()
    os.umask(0o077)
    def interrupted(_number, _frame):
        raise KeyboardInterrupt
    for event in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(event, interrupted)
    with install_lock():
        manager = Manager()
        if args.command == "install":
            if manager.owned(manager.etc) and manager.generation() is not None:
                raise Problem("已经安装；查看链接用 link，修改端口或域名用 reconfigure。不会重新生成密钥。")
            if args.guided:
                selected = guided_values(args)
                if selected is None:
                    print("已取消服务安装。")
                    return 0
                server, port, sni = selected
            else:
                server = public_ipv4(args.server or input("VPS 的固定公网 IPv4：").strip())
                port = port_number(args.port or "443")
                sni = domain(args.sni or DEFAULT_SNI)
            check_port(port)
            clock_setup = prepare_clock()
            print("正在检查握手目标 TLS 1.3；随后下载并校验固定版本官方程序。", flush=True)
            check_handshake(sni)
            manager.initialize()
            manager.download(arch)
            state = make_state(manager.binary, server, port, sni)
            generation = manager.stage(state)
            manager.activate(generation, new=True)
            runtime = {"时间同步": clock_setup, "BBR": configure_bbr(), "主机防火墙": configure_host_firewall(port)}
            print("安装完成，本机完整协议和 HTTPS 出口测试通过。")
            print(f"请在云安全组及已启用的主机防火墙放行 TCP {port}，再从 R3S 测试。")
            print("本机测试不代表公网入站端口已经放通。分享链接：\n" + share_link(state))
            show_qr_if_available(manager, state)
            write_acceptance(manager, state, runtime=runtime, protocol_passed=True)
        else:
            state = manager.state()
            if args.command in {"check", "doctor", "reconfigure", "rollback"}:
                digest = manager.binary.parent / "binary.sha256"
                if not digest.is_file() or manager.binary.is_symlink() or digest.read_text().strip() != hashlib.sha256(manager.binary.read_bytes()).hexdigest():
                    raise Problem("已安装的核心程序与首次校验记录不一致，拒绝执行。")
            if args.command == "link":
                print(share_link(state))
            elif args.command == "qr":
                print("原分享链接：\n" + share_link(state))
                render_qr(state, manager.generation())
            elif args.command == "status":
                manager.service("is-active", "--quiet", SERVICE)
                print(f"服务运行中：固定核心 {state['version']}，TCP {state['port']}，握手域名 {state['sni']}。")
            elif args.command in {"check", "doctor"}:
                passed = False
                try:
                    manager.runner([manager.binary, "check", "-c", manager.generation() / "config.json"])
                    manager.service("is-active", "--quiet", SERVICE)
                    observed = tunnel_check(manager.binary, state, state["server"])
                    passed = True
                    print(f"配置、完整 VLESS/Reality/Vision 与 HTTPS 出口检查通过：{observed}。")
                finally:
                    previous_report = manager.generation() / "acceptance.json"
                    runtime = read_json(previous_report).get("runtime_setup", {}) if previous_report.exists() else {}
                    report = write_acceptance(manager, state, runtime=runtime, protocol_passed=passed)
                if not report["local_deployment_checks_passed"]:
                    raise Problem("本机验收存在待处理项。检查报告及 journalctl -u studio-vless.service -n 60 --no-pager；不要公开含凭据的配置。")
            elif args.command == "reconfigure":
                server = public_ipv4(args.server or state["server"])
                port = port_number(args.port or state["port"])
                sni = domain(args.sni or state["sni"])
                if port != state["port"]:
                    check_port(port)
                check_handshake(sni)
                revised = make_state(manager.binary, server, port, sni, state)
                manager.activate(manager.stage(revised))
                runtime = {"主机防火墙": configure_host_firewall(port)}
                print("配置已更新并通过本机出口测试；UUID、Reality 密钥及 short ID 保持不变。")
                print("端口/域名/IP 有变更时，需要重新导入下面的链接并检查云防火墙：\n" + share_link(revised))
                show_qr_if_available(manager, revised)
                write_acceptance(manager, revised, runtime=runtime, protocol_passed=True)
            elif args.command == "rollback":
                previous = manager.generation("previous")
                if previous is None:
                    raise Problem("没有上一次成功配置可恢复。")
                manager.activate(previous)
                print("已恢复上一配置并通过本机出口检查。查看相应链接请运行 link。")
                restored = manager.state()
                runtime = {"主机防火墙": configure_host_firewall(restored["port"])}
                show_qr_if_available(manager, restored)
                write_acceptance(manager, restored, runtime=runtime, protocol_passed=True)
            elif args.command == "backup":
                folder = Path("/root/studio-vless-backups")
                folder.mkdir(mode=0o700, exist_ok=True)
                folder.chmod(0o700)
                name = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(3) + ".tar.gz"
                destination = folder / name
                with tarfile.open(destination, "w:gz") as tar:
                    tar.add(manager.etc, arcname="etc/studio-vless")
                    tar.add(manager.unit, arcname="etc/systemd/system/" + SERVICE)
                    tuning = Path("/etc/sysctl.d/90-studio-vless-bbr.conf")
                    if tuning.is_file() and not tuning.is_symlink() and tuning.read_text().startswith(f"# Managed by {APP}\n"):
                        tar.add(tuning, arcname="etc/sysctl.d/" + tuning.name)
                destination.chmod(0o600)
                print(f"私有备份：{destination}。内含密钥和分享链接，请勿公开。核心版本固定，程序不包含在配置备份内。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("操作已中断；若中断发生在服务切换阶段，安装器已尝试恢复。", file=sys.stderr)
        raise SystemExit(130)
    except EOFError:
        print("请在交互式 SSH 终端中运行向导；无人值守安装请使用 install --server 明确指定公网 IP。", file=sys.stderr)
        raise SystemExit(1)
    except (Problem, OSError, ValueError, subprocess.SubprocessError, http.client.HTTPException) as error:
        # No traceback: subprocess/configuration objects can contain credentials.
        message = str(error) if isinstance(error, Problem) else "操作未完成，请检查网络、磁盘空间、系统时间和服务状态。"
        print("错误：" + message, file=sys.stderr)
        raise SystemExit(1)
