#!/usr/bin/env bash
# Studio VLESS guided installer 0.3. Embedded reviewed code; no remote shell installer.
set -Eeuo pipefail
umask 077

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
中文 VLESS + Reality + Vision 一键安装向导 0.3

使用：sudo bash studio-vless.sh
首次运行按回车选择“安装”，核对自动检测的 IP，其余选项通常直接回车。
安装后显示分享链接、终端二维码，并保存 PNG 图片。
再次打开默认“查看分享链接和二维码”，不会重新生成密钥。

直接命令：install --guided | qr | link | status | check | doctor | backup | rollback
修改设置：reconfigure --port 8443
适用：新 Debian 12/13、Ubuntu 22.04/24.04，systemd，amd64/arm64。
选择退出不会安装依赖。程序不修改 SSH、不清空防火墙；云安全组需放行对应 TCP 端口。
HELP
  exit 0
fi

[[ "$(uname -s)" == Linux ]] || { printf '%s\n' '请把此文件上传到 VPS 后运行，不是在 Mac 或 R3S 上运行。' >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || { printf '%s\n' '请使用 sudo bash studio-vless.sh，或在 root 终端运行。' >&2; exit 1; }
[[ -r /etc/os-release ]] || { printf '%s\n' '无法识别 VPS 系统。' >&2; exit 1; }
# The OS-owned release file is local metadata, not downloaded code.
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
  *) printf '%s\n' '本版支持 Debian 12/13、Ubuntu 22.04/24.04。' >&2; exit 1 ;;
esac
[[ -d /run/systemd/system ]] || { printf '%s\n' '需要使用 systemd 的 VPS。' >&2; exit 1; }

if [[ "$#" -eq 0 ]]; then
  studio_default=1
  if [[ -f /etc/studio-vless/OWNER && -L /etc/studio-vless/current ]] &&
     [[ "$(cat /etc/studio-vless/OWNER)" == studio-vless-v1 ]]; then
    studio_default=2
  fi
  printf '\n%s\n' '======== 工作室 VLESS 中文向导 ========' \
    '1. 安装 VLESS + Reality + Vision（新 VPS）' \
    '2. 查看原分享链接和二维码' \
    '3. 查看运行状态' \
    '4. 测试代理连接与出口 IP' \
    '5. 备份配置和密钥' \
    '6. 恢复上一次成功配置' \
    '7. 完整诊断并保存验收报告' \
    '0. 退出'
  printf '请选择，直接回车使用默认 [%s]：' "$studio_default"
  if ! IFS= read -r studio_choice </dev/tty; then
    printf '\n%s\n' '请在交互式 SSH 终端运行；也可以在文件名后加 qr、status 等命令。' >&2
    exit 1
  fi
  studio_choice="${studio_choice:-$studio_default}"
  case "$studio_choice" in
    1) set -- install --guided ;;
    2) set -- qr ;;
    3) set -- status ;;
    4) set -- check ;;
    5) set -- backup ;;
    6)
      printf '%s' '恢复上一配置？默认不执行 [y/N]：'
      IFS= read -r studio_confirm </dev/tty || exit 1
      case "$studio_confirm" in y|Y|yes|YES) set -- rollback ;; *) printf '%s\n' '已取消。'; exit 0 ;; esac
      ;;
    7) set -- doctor ;;
    0) printf '%s\n' '已退出，未安装依赖或修改服务。'; exit 0 ;;
    *) printf '%s\n' '无效选项，请重新运行。' >&2; exit 2 ;;
  esac
fi
case "$1" in install|reconfigure|qr|link|status|check|doctor|backup|rollback) ;; *) printf '%s\n' '未知命令，使用 --help 查看用法。' >&2; exit 2 ;; esac

studio_packages=()
[[ -x /usr/bin/python3 ]] || studio_packages+=(python3)
studio_ca_status="$(dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null || true)"
[[ "$studio_ca_status" == 'install ok installed' ]] || studio_packages+=(ca-certificates)
case "$1" in install|reconfigure|qr) command -v qrencode >/dev/null 2>&1 || studio_packages+=(qrencode) ;; esac
if [[ "${#studio_packages[@]}" -gt 0 ]]; then
  printf '%s\n' '正在通过系统 APT 软件源准备依赖（不改写软件源）…'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${studio_packages[@]}"
fi
/usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || {
  printf '%s\n' '需要系统 Python 3.10 或更新版本。' >&2; exit 1;
}

studio_tmp="$(mktemp -d /var/tmp/studio-vless-installer.XXXXXXXX)"
trap 'rm -rf -- "$studio_tmp"' EXIT
trap 'exit 130' HUP INT TERM
/usr/bin/python3 - "$studio_tmp" <<'STUDIO_PYTHON_PAYLOAD'
import base64, gzip, hashlib, os, sys
from pathlib import Path
encoded = """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
AAA="""
code = gzip.decompress(base64.b64decode("".join(encoded.split()), validate=True))
if len(code) > 1000000 or hashlib.sha256(code).hexdigest() != "46f93ea60ecf94eabaedc804dd016e1f1f14bb9b959b3abd2177b6525a90cd5a":
    raise SystemExit("内置程序校验失败，未执行安装。")
path = Path(sys.argv[1]) / "studio_vless.py"
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as output:
    output.write(code)
STUDIO_PYTHON_PAYLOAD
/usr/bin/python3 "$studio_tmp/studio_vless.py" "$@"
if [[ "$1" == install && -L /etc/studio-vless/current ]]; then
  /usr/bin/python3 - "${BASH_SOURCE[0]}" <<'STUDIO_LOCAL_COMMAND'
import os, sys, tempfile
from pathlib import Path
source = Path(sys.argv[1])
target = Path("/usr/local/bin/studio-vless")
marker = b"# Studio VLESS guided installer "
if not source.is_file() or not source.read_bytes().splitlines()[1].startswith(marker):
    print("未创建管理快捷命令，请继续使用上传的安装文件。")
elif os.path.lexists(target) and (target.is_symlink() or not target.is_file() or not target.read_bytes().splitlines()[1:2] or not target.read_bytes().splitlines()[1].startswith(marker)):
    print("已有其他同名命令，保留原文件。请继续使用上传的安装文件。")
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".studio-vless-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o755)
            output.write(source.read_bytes())
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print("以后在 VPS 输入 sudo studio-vless 即可打开管理菜单。")
STUDIO_LOCAL_COMMAND
fi
