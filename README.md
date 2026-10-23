# Studio VLESS 安装向导

为新 Debian / Ubuntu VPS 准备的中文 VLESS + Reality + Vision 安装器。

## 复制一条命令安装

适用于 Debian 12/13、Ubuntu 22.04/24.04，systemd，amd64/arm64。请在 VPS 的 FinalShell / SSH 交互终端中运行；Mac 只用于连接 VPS。

```bash
(studio_sudo=; [ "$(id -u)" -eq 0 ] || studio_sudo=sudo; $studio_sudo bash -c 'set -e; umask 077; [ "$(uname -s)" = Linux ] && [ -t 0 ] && [ -t 1 ] || exit 1; command -v curl >/dev/null && [ -s /etc/ssl/certs/ca-certificates.crt ] || { apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates; }; d=$(mktemp -d /var/tmp/studio-vless-download.XXXXXXXX); trap "rm -rf -- \"$d\"" EXIT; trap "exit 130" HUP INT TERM; curl -fsSL --proto =https --proto-redir =https --connect-timeout 15 --max-time 180 --retry 2 https://raw.githubusercontent.com/niisdasdf/studio-vless-installer/4ba6fdf6d320078be8fd2a3bd412dccdc3294ba7/releases/v0.3/studio-vless.sh -o "$d/install.sh"; echo "9fd619fc8d8b6e82bbabcc9f7384daa1d3ad8d4937168a524f6bac60d347d6ff  $d/install.sh" | sha256sum -c -; bash "$d/install.sh" </dev/tty')
```

命令会自动处理 root/sudo、准备缺少的 curl 和系统 CA、下载固定版本，核对 SHA-256 后打开向导。新服务器按回车选“安装”，核对自动检测的公网 IPv4；端口默认 443，握手域名默认 addons.mozilla.org，其余通常回车即可。

须在商家的云安全组中放行所选 TCP 端口。已启用的 UFW 会添加相应端口规则；其他自定义防火墙根据提示处理。

## 安装完成后

自动生成分享链接、终端二维码和私有 PNG 图片。可把分享链接导入兼容 VLESS/Reality/Vision 的客户端。

```bash
sudo studio-vless
```

root 登录时可以直接输入 `studio-vless`。再次进入默认查看原链接和二维码，保留原身份。

菜单提供状态、连接检测、备份和上一配置回滚。Reality 公私钥、UUID、short ID 自动生成；无需购买域名、申请或续签自己的域名证书。

## 固定发布与检查

- 版本：0.3；核心 sing-box 1.14.3，官方归档按固定 SHA-256 校验。
- [可读 Python 源码](releases/v0.3/studio_vless.py) / [单文件安装器](releases/v0.3/studio-vless.sh)。
- 安装器 SHA-256：`9fd619fc8d8b6e82bbabcc9f7384daa1d3ad8d4937168a524f6bac60d347d6ff`。
- 34 项隔离测试通过；Debian 13 arm64 本地虚拟机实测了安装、低权限服务、开机自启、故障恢复、回滚及二维码解码。
- 本机协议测试与商家公网安全组、实际使用地点的连通性和长期性能分开验收。其余受支持系统/架构尚未逐项实机覆盖。

安装器只管理自身服务和配置；不接管其他脚本的 `/etc/sing-box`，不修改 SSH 或清空防火墙。服务器端域名解析使用 DoH，内核支持时设置 BBR；节点凭据仅在实际安装时生成，此仓库不存储运行中的节点凭据。
