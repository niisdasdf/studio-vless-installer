# 独立 Hysteria2 部署

在 Debian/Ubuntu VPS 上安装独立的 `studio-hy2` 服务：固定 sing-box 1.14.4、UDP443、随机密码、Let's Encrypt 公开 CA 证书及自动续期。客户端使用服务器 IPv4 和证书域名 SNI，保持 TLS 证书验证开启。脚本不包含预设服务器或域名，也不删除已有 SSH、代理服务或客户端节点。

## 使用

要求 root、运行中的 systemd ≥247、amd64/arm64。域名的 A 记录必须直接且仅指向本机已分配的公网 IPv4，无 AAAA、无 CDN 代理。UDP443 必须空闲；HTTP01 验证时 TCP80 必须空闲且能从公网到达。商家安全组和上游网络规则需允许这些连接。

将下面的域名和 `YOUR_PUBLIC_IPV4` 替换为自己的值，在 VPS 的 root 终端或商家控制台执行。`--agree-tos` 表示接受 [Let's Encrypt 订户协议](https://letsencrypt.org/repository/)。

```bash
curl -qfsSL --proto '=https' --proto-redir '=https' \
  'https://raw.githubusercontent.com/niisdasdf/studio-vless-installer/0ede727f10504c03d412b16340b85f91c6ad3d24/hy2/install.sh' \
  -o install-studio-hy2.sh &&
printf '%s  %s\n' \
  '3770415807fb65c89ceead9ff5328f247b7b194c09df5c71fc796d89123445bd' \
  'install-studio-hy2.sh' | sha256sum -c - &&
bash install-studio-hy2.sh \
  --domain hy2.example.com --server-ip YOUR_PUBLIC_IPV4 --agree-tos
```

下载地址固定到提交，安装脚本也会校验下载的 sing-box 发布包。相同身份重跑会保留密码；已有安装的域名/IP 不匹配时停止。

## 校验与管理

```bash
systemctl status studio-hy2.service --no-pager
systemctl list-timers studio-hy2-renew.timer --no-pager
journalctl -u studio-hy2.service -n 50 --no-pager
cat /etc/studio-hy2/node.private.txt
```

最后一条命令显示包含密码的私有导入链接，仅在自己的终端查看。凭据和链接文件权限为 0600。安装过程检查配置、证书链、域名、密钥匹配、服务 PID 与 UDP443 监听，并执行续期 staging dry-run；全部通过才输出 `READY`。

## 安全与适用边界

- HTTP01 只临时开放带独立标记的 TCP80 规则，正常结束会清理，并预设 600 秒兜底清理 timer。续期每天检查两次，证书更新后重启本服务。
- 服务使用 `DynamicUser` 与 systemd credentials；默认拒绝私网目的地址、服务端自身公网 IPv4 及 IPv6 目的地址。不会启用跳过 TLS 验证的回退配置。
- 支持常规 iptables/UFW。可检测到的额外原生 nftables input hook 会使部署停止；没有 `nft` 命令时无法完成该项检查。自定义或混合防火墙需自行确认；安装不会重写无关规则。
- 端口占用、签发失败或检查失败会中止；已安装的软件包和本脚本创建的部分文件可能保留，不保证整次安装自动回滚。TCP80 兜底清理依赖系统的 systemd/iptables 正常工作。

## 验证范围

本版本已在 Ubuntu 24.04.1 / systemd 255 目标机验证服务就绪、UDP443 监听、公开 CA 证书及续期 staging dry-run。本地检查覆盖 Bash/Python 语法、真实 sing-box 配置、临时防火墙清理与启动等待分支；这不代表所有 Debian/Ubuntu 环境均已实测。

`READY` 只表示服务端检查通过。仍需从实际客户端验证严格 TLS 握手、目标站点访问及出口 IP；服务端就绪不能证明客户端到 VPS 的 UDP 路径可用。确认新节点可用后再迁移绑定或删除旧节点。
