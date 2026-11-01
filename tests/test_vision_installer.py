#!/usr/bin/env python3
"""Temp-path installer regression tests; no VPS/router/network/service changes.

Run with Bash >=4 and jq. --core optionally checks generated JSON using an
already installed trusted sing-box; it only runs `generate` and `check`.
System services, package operations, TLS probes, and downloads are mocked.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

REPO = Path(__file__).resolve().parents[1]
SCRIPT = next((p for p in (REPO / "patches/original-v0.2/installer.sh",
                          REPO / "patches/original-v0.1/installer.sh") if p.exists()))
BASH = os.environ.get("STUDIO_TEST_BASH", shutil.which("bash"))
CORE = os.environ.get("STUDIO_TEST_CORE")
UUID = "22222222-2222-4222-8222-222222222222"


def quote(value):
    return shlex.quote(str(value))


def tree(path):
    return {str(p.relative_to(path)): (p.stat().st_mode & 0o777, p.read_bytes())
            for p in path.rglob("*") if p.is_file()}


class VisionInstaller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        version = subprocess.check_output([BASH, "--version"], text=True)
        if int(re.search(r"version (\d+)", version)[1]) < 4:
            raise unittest.SkipTest("Bash >=4 required; set STUDIO_TEST_BASH or --bash")
        if not shutil.which("jq"):
            raise unittest.SkipTest("jq is required")
        cls.source_bytes = SCRIPT.read_bytes()
        cls.source = cls.source_bytes.decode()
        # Strip only the known bootstrap; never execute root/OS checks or menu
        # implicitly while loading the actual function definitions.
        cls.definitions = cls.source.split("# ---------- 引导 ----------", 1)[0]
        if cls.definitions == cls.source:
            raise AssertionError("known bootstrap boundary missing")
        cls.keys = {"PrivateKey": "C" * 43, "PublicKey": "D" * 43}
        if CORE:
            pair = subprocess.check_output([CORE, "generate", "reality-keypair"], text=True)
            cls.keys = dict(line.split(": ", 1) for line in pair.strip().splitlines())

    @classmethod
    def tearDownClass(cls):
        if SCRIPT.read_bytes() != cls.source_bytes:
            raise AssertionError("installer changed during validation; rerun against frozen source")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vision-installer-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("managed/conf", "managed/logs", "stage", "systemd", "bin", "backups", "state"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        self.work = self.root / "managed"
        self.conf = self.work / "conf"
        self.defs = self.root / "definitions.sh"
        self.defs.write_text(self.definitions)
        self.old = {"inbounds": [{"type": "vless", "tag": "vless-reality", "listen": "::",
            "listen_port": 29065, "users": [{"uuid": "11111111-1111-4111-8111-111111111111"}],
            "tls": {"enabled": True, "server_name": "addons.mozilla.org", "reality": {
                "enabled": True, "handshake": {"server": "addons.mozilla.org", "server_port": 443},
                "private_key": "A" * 43, "short_id": [""]}}}]}
        for name, value in (("10_vless_tcp_reality.json", self.old),
                            ("00_base.json", {"log": {"disabled": True}, "outbounds": [{"type": "direct", "tag": "direct"}]}),
                            ("90_custom.json", {"route": {"final": "direct"}})):
            (self.conf / name).write_text(json.dumps(value))
        (self.conf / "reality_private.key").write_text("A" * 43 + "\n")
        (self.conf / "reality_public.key").write_text("B" * 43 + "\n")
        (self.work / "server-ip").write_text("198.51.100.10\n")
        (self.work / ".proxyinstaller-managed").write_text("proxyinstaller-minimal-v1\n")
        (self.work / "config.json").write_text(json.dumps({"outbounds": [{"type": "direct"}], **self.old}))
        (self.root / "systemd/sing-box.service").write_text("# proxyinstaller-minimal-v1\noriginal unit\n")
        (self.root / "bin/menu").write_text("# proxyinstaller-minimal-v1\noriginal menu\n")
        core = self.work / "sing-box"
        core.write_text("#!/usr/bin/env bash\ncase \"$1\" in\n"
                        "version) printf 'sing-box version 1.14.3\\n';;\n"
                        "generate) printf '%s\\n' " + quote("PrivateKey: " + self.keys["PrivateKey"]) + " " + quote("PublicKey: " + self.keys["PublicKey"]) + ";;\n"
                        "check) [ ! -e \"$TEST_ROOT/state/fail-check\" ];;\n*) exit 98;;\nesac\n")
        core.chmod(0o700)
        self.legacy = {p: (self.conf / p).read_bytes() for p in
                       ("10_vless_tcp_reality.json", "reality_private.key", "reality_public.key", "90_custom.json")}

    def run_shell(self, body, *, success=True, probe_mock=True):
        (self.root / "stage").mkdir(exist_ok=True)
        prefix = f"""set -euo pipefail
source {quote(self.defs)}
export TEST_ROOT={quote(self.root)}
WORK_DIR="$TEST_ROOT/managed"; CONF_DIR="$WORK_DIR/conf"; LOG_DIR="$WORK_DIR/logs"
TEMP_DIR="$TEST_ROOT/stage"; BACKUP_ROOT="$TEST_ROOT/backups"
UNIT_FILE="$TEST_ROOT/systemd/sing-box.service"; MENU_FILE="$TEST_ROOT/bin/menu"; BBR_FILE="$TEST_ROOT/bbr.conf"
SCRIPT_SOURCE={quote(SCRIPT)}
SB_ARCH=amd64
action_context() {{ guard_managed; }}
install_deps() {{ return 0; }}
ensure_singbox() {{ return 0; }}
enable_bbr() {{ return 0; }}
ensure_qrencode() {{ return 1; }}
qrencode() {{ cat >/dev/null; }}
sleep() {{ return 0; }}
clear() {{ return 0; }}
read_uuid() {{ UUID={quote(UUID)}; }}
read_ip_default() {{ touch "$TEST_ROOT/state/ip-detected"; SERVER_IP=198.51.100.10; printf '%s\\n' "$SERVER_IP" > "$WORK_DIR/server-ip"; }}
read_port() {{ PORT=34443; }}
prompt_read() {{ printf -v "$2" '%s' "www.kernel.org"; }}
ss() {{ return 0; }}
df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\ntest 999999 0 999999 0%% /\\n'; }}
stat() {{ python3 -c 'import os,sys; print(int(os.stat(sys.argv[2]).st_mtime))' "$2" "$3"; }}
sysctl() {{ case "$*" in *default_qdisc*) printf 'fq\\n';; *congestion_control*) printf 'cubic\\n';; esac; }}
systemctl() {{
 printf '%s\\n' "$*" >> "$TEST_ROOT/state/service.log"
 case "$1" in
 is-active) test -e "$TEST_ROOT/state/active";; is-enabled) test -e "$TEST_ROOT/state/enabled";;
 start) touch "$TEST_ROOT/state/active";; stop) rm -f "$TEST_ROOT/state/active";;
 enable) touch "$TEST_ROOT/state/enabled";; disable) rm -f "$TEST_ROOT/state/enabled";;
 restart) test ! -e "$TEST_ROOT/state/fail-restart" && touch "$TEST_ROOT/state/active";;
 *) return 0;; esac
}}
"""
        if probe_mock:
            prefix += 'probe_vision_target() { test ! -e "$TEST_ROOT/state/fail-tls"; }\n'
        proc = subprocess.run([BASH, "-c", prefix + body], capture_output=True, text=True,
                              errors="replace", timeout=30)
        if success:
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
        return proc

    def install(self, **kwargs):
        return self.run_shell("run_change install_vless_tcp_reality_vision\n", **kwargs)

    def assert_legacy_preserved(self):
        for name, value in self.legacy.items():
            self.assertEqual((self.conf / name).read_bytes(), value, name)

    def test_new_vision_preserves_legacy_and_custom_fragment(self):
        self.install()
        self.assert_legacy_preserved()
        cfg = json.loads((self.work / "config.json").read_text())
        self.assertEqual(len(cfg["inbounds"]), 2)
        self.assertEqual(cfg["route"], {"final": "direct"})
        old = next(i for i in cfg["inbounds"] if i["listen_port"] == 29065)
        self.assertEqual(old, self.old["inbounds"][0])

    def test_existing_entry_ip_is_preserved_without_outbound_ip_detection(self):
        entry = self.work / "server-ip"
        entry.write_bytes(b"198.51.100.20\n")
        self.install()
        self.assertEqual(entry.read_bytes(), b"198.51.100.20\n")
        self.assertFalse((self.root / "state/ip-detected").exists())
        uri = urllib.parse.urlsplit(self.run_shell("vision_uri\n").stdout.strip())
        self.assertEqual(uri.hostname, "198.51.100.20")
        text = self.run_shell("show_generated_links\n").stdout
        self.assertEqual(len(re.findall(r"@198\.51\.100\.20:", text)), 2)

    def test_invalid_existing_entry_ip_is_rejected_without_overwrite(self):
        (self.work / "server-ip").write_bytes(b"invalid-existing-entry\n")
        before = tree(self.work)
        self.install(success=False)
        self.assertEqual(tree(self.work), before)
        self.assertFalse((self.root / "state/ip-detected").exists())

    def test_vision_flow_sid_uri_and_reexport_agree(self):
        self.install()
        path = self.conf / "11_vless_tcp_reality_vision.json"
        inbound = json.loads(path.read_text())["inbounds"][0]
        self.assertEqual(inbound["users"][0], {"uuid": UUID, "flow": "xtls-rprx-vision"})
        sid = inbound["tls"]["reality"]["short_id"][0]
        self.assertRegex(sid, r"^[0-9a-f]{16}$")
        self.assertNotIn("transport", inbound)
        self.assertEqual(inbound.get("multiplex"), {"enabled": False})
        self.assertIs(inbound.get("tcp_fast_open"), False)
        self.assertFalse(inbound["tls"].get("insecure", False))
        self.assertNotIn("ech", inbound["tls"])
        self.assertNotIn("fragment", inbound["tls"])
        before = tree(self.work)
        a = self.run_shell("vision_uri\n").stdout.strip()
        b = self.run_shell("vision_uri\n").stdout.strip()
        self.assertEqual(a, b)
        uri = urllib.parse.urlsplit(a)
        q = urllib.parse.parse_qs(uri.query)
        self.assertEqual((uri.username, uri.hostname, uri.port), (UUID, "198.51.100.10", 34443))
        for k, v in {"flow": "xtls-rprx-vision", "sid": sid, "sni": "www.kernel.org", "fp": "ios", "security": "reality", "type": "tcp"}.items():
            self.assertEqual(q[k], [v])
        self.assertEqual(q["pbk"], [(self.conf / "vision_public.key").read_text().strip()])
        self.assertEqual(tree(self.work), before)
        for name in ("11_vless_tcp_reality_vision.json", "vision_private.key", "vision_public.key"):
            self.assertEqual((self.conf / name).stat().st_mode & 0o777, 0o600)

    def test_menu_eight_exports_both_legacy_and_vision(self):
        self.install()
        text = self.run_shell("show_generated_links\n").stdout
        links = re.findall(r"vless://[^\s\x1b]+", text)
        self.assertEqual(len(links), 2)
        self.assertTrue(any("flow=xtls-rprx-vision" in s and "fp=ios" in s for s in links))
        self.assertTrue(any("fp=chrome" in s and "flow=" not in s for s in links))

    def test_vision_port_and_uuid_edits_preserve_legacy_keys_and_flow(self):
        self.install()
        path = self.conf / "11_vless_tcp_reality_vision.json"
        old_tls = json.loads(path.read_text())["inbounds"][0]["tls"]
        self.run_shell('prompt_read() { printf -v "$2" 4; }\nread_port() { PORT=35555; }\nrun_change change_port\n')
        replacement = "33333333-3333-4333-8333-333333333333"
        self.run_shell('prompt_read() { printf -v "$2" 3; }\nread_uuid() { UUID=' + quote(replacement) + '; }\nrun_change change_user_cred\n')
        n = json.loads(path.read_text())["inbounds"][0]
        self.assertEqual(n["listen_port"], 35555)
        self.assertEqual(n["users"][0], {"uuid": replacement, "flow": "xtls-rprx-vision"})
        self.assertEqual(n["tls"], old_tls)
        self.assert_legacy_preserved()
        uri = urllib.parse.urlsplit(self.run_shell("vision_uri\n").stdout.strip())
        self.assertEqual((uri.username, uri.port), (replacement, 35555))

    def test_tls_failure_restores_files_and_service_state(self):
        before = tree(self.work)
        (self.root / "state/active").touch()
        (self.root / "state/fail-tls").touch()
        unit = (self.root / "systemd/sing-box.service").read_bytes()
        self.install(success=False)
        self.assertEqual(tree(self.work), before)
        self.assertEqual((self.root / "systemd/sing-box.service").read_bytes(), unit)
        self.assertTrue((self.root / "state/active").exists())
        self.assertFalse((self.root / "state/enabled").exists())

    def test_merge_failure_rolls_back_new_owned_files(self):
        before = tree(self.work)
        (self.root / "state/fail-check").touch()
        self.install(success=False)
        self.assertEqual(tree(self.work), before)
        self.assertFalse((self.conf / "vision_private.key").exists())

    def test_restart_failure_rolls_back_and_keeps_backup(self):
        before = tree(self.work)
        (self.root / "state/active").touch()
        (self.root / "state/fail-restart").touch()
        self.install(success=False)
        self.assertEqual(tree(self.work), before)
        backups = list((self.root / "backups").glob("change.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / ".complete").read_text().strip(), "complete")
        self.assertTrue((self.root / "state/active").exists())

    def test_existing_vision_credentials_are_not_overwritten(self):
        (self.conf / "vision_private.key").write_text("existing-credential\n")
        before = tree(self.work)
        self.install(success=False)
        self.assertEqual(tree(self.work), before)

    def test_occupied_port_is_refused_and_free_alternative_can_be_selected(self):
        mock = "ss() { printf 'tcp LISTEN 0 4096 0.0.0.0:34443 0.0.0.0:*\\n'; }\n"
        before = tree(self.work)
        self.run_shell(mock + "run_change install_vless_tcp_reality_vision\n", success=False)
        self.assertEqual(tree(self.work), before)
        alternative = self.run_shell(mock + "suggest_vision_port 34443\n").stdout.strip()
        self.assertEqual(alternative, "34444")
        self.run_shell(mock + "read_port() { PORT=34444; }\nrun_change install_vless_tcp_reality_vision\n")
        inbound = json.loads((self.conf / "11_vless_tcp_reality_vision.json").read_text())["inbounds"][0]
        self.assertEqual(inbound["listen_port"], 34444)
        self.assert_legacy_preserved()

    def test_backup_includes_vision_and_owned_removal_preserves_unknown(self):
        self.install()
        vision = (self.conf / "11_vless_tcp_reality_vision.json").read_bytes()
        self.run_shell('begin_transaction\nprintf "%s\\n" "$BACKUP_DIR" > "$TEST_ROOT/backup-path"\nTRANSACTION_ACTIVE=0\nremove_owned_files\n')
        backup = Path((self.root / "backup-path").read_text().strip())
        self.assertEqual((backup / "workdir/conf/11_vless_tcp_reality_vision.json").read_bytes(), vision)
        for name in ("11_vless_tcp_reality_vision.json", "vision_private.key", "vision_public.key"):
            self.assertFalse((self.conf / name).exists())
        self.assertTrue((self.conf / "90_custom.json").exists())

    def test_main_menu_ten_dispatches_vision_and_preserves_nine_choices(self):
        proc = self.run_shell('prompt_read() { printf -v "$2" 10; }\nrun_change() { printf "DISPATCH:%s\\n" "$1"; }\nmain_menu\n')
        for number in range(1, 11):
            self.assertRegex(proc.stdout, rf"(?m)^{number}\)")
        self.assertIn("DISPATCH:install_vless_tcp_reality_vision", proc.stdout)
        self.assertIn("洪大流量中心 加密部署命令", proc.stdout)
        for domain in ("wepc.au", "neemo.au", "pingip.cn"):
            self.assertNotIn(domain, proc.stdout)

    def test_bad_core_archive_never_unpacks_or_executes(self):
        (self.work / "sing-box").unlink()
        body = self.definitions[self.definitions.index("ensure_singbox() {"):self.definitions.index("ensure_qrencode() {")]
        self.run_shell(body + '\ncurl() { while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf bad > "$2"; return 0; fi; shift; done; return 2; }\nsha256sum() { cat >/dev/null; return 1; }\ntar() { touch "$TEST_ROOT/state/unpacked"; }\ninstall() { touch "$TEST_ROOT/state/executed"; }\nensure_singbox\n', success=False)
        self.assertFalse((self.root / "state/unpacked").exists())
        self.assertFalse((self.root / "state/executed").exists())
        self.assertFalse((self.work / "sing-box").exists())

    def test_tls_probe_requires_strict_tls13_sni_and_hostname_validation(self):
        self.run_shell('timeout() { shift; "$@"; }\nopenssl() { printf "%s\\n" "$*" >> "$TEST_ROOT/state/tls-args"; printf "Protocol version: TLSv1.3\\nProtocol  : TLSv1.3\\nServer Temp Key: X25519, 253 bits\\nALPN protocol: h2\\nVerification: OK\\nVerify return code: 0 (ok)\\n"; }\nprobe_vision_target www.kernel.org\n', probe_mock=False)
        calls = (self.root / "state/tls-args").read_text().splitlines()
        self.assertGreaterEqual(len(calls), 3)
        for call in calls:
            for arg in ("-tls1_3", "-verify_return_error", "-verify_hostname www.kernel.org", "-servername www.kernel.org"):
                self.assertIn(arg, call)

    def test_tls_probe_rejects_certificate_or_connection_failure(self):
        self.run_shell('timeout() { shift; "$@"; }\nopenssl() { return 1; }\nprobe_vision_target www.kernel.org\n',
                       success=False, probe_mock=False)

    def test_download_instructions_pin_commit_and_current_digest(self):
        command = SCRIPT.parent / "一键安装命令.txt"
        if SCRIPT.parent.name != "original-v0.2" or not command.exists():
            self.skipTest("v0.2 immutable download command not staged yet; rerun before release")
        text = command.read_text()
        self.assertIn(hashlib.sha256(self.source_bytes).hexdigest(), text)
        self.assertRegex(text, r"raw\.githubusercontent\.com/[^\s/]+/[^\s/]+/[0-9a-f]{40}/patches/original-v0\.2/installer\.sh")
        self.assertIn("sha256sum -c -", text)
        self.assertNotRegex(text, r"curl[^\n]*\|\s*(?:sudo\s+)?bash")

    def test_real_core_accepts_generated_server_and_ios_client(self):
        if not CORE:
            self.skipTest("pass --core for real sing-box schema validation")
        self.install()
        subprocess.run([CORE, "check", "-c", str(self.work / "config.json")], check=True, capture_output=True)
        n = json.loads((self.conf / "11_vless_tcp_reality_vision.json").read_text())["inbounds"][0]
        client = {"inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 34444}], "outbounds": [{"type": "vless", "server": "198.51.100.10", "server_port": n["listen_port"], "uuid": UUID, "flow": "xtls-rprx-vision", "tls": {"enabled": True, "insecure": False, "server_name": n["tls"]["server_name"], "utls": {"enabled": True, "fingerprint": "ios"}, "reality": {"enabled": True, "public_key": self.keys["PublicKey"], "short_id": n["tls"]["reality"]["short_id"][0]}}}]}
        path = self.root / "client.json"
        path.write_text(json.dumps(client))
        subprocess.run([CORE, "check", "-c", str(path)], check=True, capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--installer", type=Path)
    parser.add_argument("--bash")
    parser.add_argument("--core")
    opts, rest = parser.parse_known_args()
    SCRIPT = opts.installer.resolve() if opts.installer else SCRIPT
    BASH = opts.bash or BASH
    CORE = opts.core or CORE
    unittest.main(argv=[sys.argv[0], *rest])
