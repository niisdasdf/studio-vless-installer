#!/usr/bin/env bash
# Minimal safety patch of dabadabader/install, commit 9efdde64cb1de338aa7392fa0394c37ed25876c6.
set -euo pipefail
umask 077

VERSION='洪大流量中心 加密部署命令 · v0.2'
GITHUB_PROXY=('' 'https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/')
GH_PROXY=''
TEMP_DIR=''
WORK_DIR='/etc/sing-box'
LOG_DIR="${WORK_DIR}/logs"
CONF_DIR="${WORK_DIR}/conf"
DEFAULT_PORT_REALITY=$((RANDOM % 50001 + 10000))
DEFAULT_PORT_WS=$((RANDOM % 50001 + 10000))
DEFAULT_PORT_SS=$((RANDOM % 50001 + 10000))
TLS_SERVER_DEFAULT='addons.mozilla.org'
DEFAULT_NEWEST_VERSION='1.14.3'
MANAGED_ID='proxyinstaller-minimal-v1'
UNIT_FILE='/etc/systemd/system/sing-box.service'
MENU_FILE='/usr/local/bin/menu'
BBR_FILE='/etc/sysctl.d/90-proxyinstaller-bbr.conf'
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
TRANSACTION_ACTIVE=0
BACKUP_DIR=''
BACKUP_ROOT='/var/backups/proxyinstaller'
BACKUP_KEEP=5
WAS_ACTIVE=0
WAS_ENABLED=0
QDISC_BEFORE=''
CC_BEFORE=''
OWNED_FILES=(sing-box config.json installer.sh server-ip bbr.previous .proxyinstaller-managed
  conf/00_base.json conf/10_vless_tcp_reality.json conf/11_vless_tcp_reality_vision.json conf/12_ss.json conf/13_vmess_ws.json
  conf/reality_private.key conf/reality_public.key conf/vision_private.key conf/vision_public.key)
export DEBIAN_FRONTEND=noninteractive

# ---------- 彩色输出 ----------
ok()     { echo -e "\033[32m\033[01m$*\033[0m"; }
warn()   { echo -e "\033[33m\033[01m$*\033[0m"; }
err()    { echo -e "\033[31m\033[01m$*\033[0m" >&2; }

# ---------- 颜色变量 ----------
ESC=$(printf '\033')
YELLOW="${ESC}[33m"
GREEN="${ESC}[32m"
CYAN="${ESC}[36m"
RED="${ESC}[31m"
RESET="${ESC}[0m"
die()    { err "$*"; exit 1; }

prompt_read() {
  local prompt="$1" var="$2"

  if [ -r /dev/tty ]; then
    # shellcheck disable=SC2229 -- read 将输入写入 var 指定的变量名。
    IFS= read -r -p "$prompt" "$var" </dev/tty || return 1
  else
    # shellcheck disable=SC2229 -- read 将输入写入 var 指定的变量名。
    IFS= read -r -p "$prompt" "$var" || return 1
  fi
}

# ---------- 基础检测 ----------
need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"; }

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64)  SB_ARCH=arm64 ;;
    x86_64|amd64)   SB_ARCH=amd64 ;;
    armv7l)         SB_ARCH=armv7 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

detect_os() {
  local os_id=''
  [ -r /etc/os-release ] && os_id="$(. /etc/os-release; printf '%s' "$ID")"
  case "$os_id" in
    debian|ubuntu) OS_FAMILY='Debian'; PKG_INSTALL='apt-get -y install' ;;
    *) die "此最小补丁目前支持新 Debian/Ubuntu VPS；尚未验证的发行版不会自动安装。" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die '需要使用 systemd 的 VPS。'
}
install_deps() {
  local packages=() command_name package_name
  for pair in wget:wget curl:curl jq:jq tar:tar openssl:openssl ss:iproute2 flock:util-linux timeout:coreutils; do
    command_name="${pair%%:*}"; package_name="${pair#*:}"
    command -v "$command_name" >/dev/null 2>&1 || packages+=("$package_name")
  done
  [ -s /etc/ssl/certs/ca-certificates.crt ] || packages+=(ca-certificates)
  if [ "${#packages[@]}" -gt 0 ]; then
    apt-get update
    apt-get install -y --no-install-recommends "${packages[@]}"
  fi
}
sync_system_time() {
  ok "正在尝试同步系统时间..."

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    systemctl restart chronyd >/dev/null 2>&1 || true
    systemctl restart chrony >/dev/null 2>&1 || true
  fi

  if command -v chronyc >/dev/null 2>&1; then
    chronyc -a makestep >/dev/null 2>&1 || true
  elif command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u time.google.com >/dev/null 2>&1 || true
  fi

  sleep 1
}

# 检测是否需要启用 Github CDN，如能直接连通，则不使用
check_cdn() {
  # 下载优先直连；原有加速地址仅作为后备，所有来源必须通过同一固定摘要校验。
  GH_PROXY=''
}
# ---------- Github 版本 ----------
get_latest_version() {
  # 固定本补丁已验证版本，不再执行远端 force_version 的版本选择。
  printf '%s\n' "$DEFAULT_NEWEST_VERSION"
}
ensure_singbox() {
  [ -x "${WORK_DIR}/sing-box" ] && return 0
  local ver digest official_url tarball proxy downloaded=0
  ver=$(get_latest_version)
  case "$SB_ARCH" in
    amd64) digest='e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee' ;;
    arm64) digest='29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e' ;;
    armv7) digest='8e81ee6bc1db6fec6e0342360e1de7bfabecec8d2e9c480a3563d129f84fb034' ;;
    *) die "不支持的架构：$SB_ARCH" ;;
  esac
  official_url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"
  tarball="${TEMP_DIR}/sing-box.tar.gz"
  ok "下载 sing-box v${ver} (${SB_ARCH}) 并校验 SHA256..."
  for proxy in "${GITHUB_PROXY[@]}"; do
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 \
      --max-filesize 120000000 --retry 1 "${proxy}${official_url}" -o "$tarball"; then
      if printf '%s  %s\n' "$digest" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
        downloaded=1; break
      fi
      warn '下载内容校验失败，拒绝解压或执行，尝试下一来源。'
    fi
    rm -f -- "$tarball"
  done
  [ "$downloaded" -eq 1 ] || die '无法下载通过固定 SHA256 校验的 sing-box。'
  tar xzf "$tarball" -C "$TEMP_DIR" -- "sing-box-${ver}-linux-${SB_ARCH}/sing-box"
  install -m 700 "$TEMP_DIR/sing-box-${ver}-linux-${SB_ARCH}/sing-box" "$WORK_DIR/sing-box"
  rm -f -- "$tarball"
}
ensure_qrencode() {
  command -v qrencode >/dev/null 2>&1 && return 0

  ok "正在安装二维码生成工具..."
  local qr_log="${TEMP_DIR}/qrencode-install.log"
  : > "$qr_log"

  if command -v apt >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt install -y qrencode >>"$qr_log" 2>&1; then
      warn "直接安装失败，尝试更新软件后重试..."
      if ! apt update >"$qr_log" 2>&1; then
        warn "apt update 失败，尝试同步系统时间..."
        sync_system_time

        if ! apt update >>"$qr_log" 2>&1; then
          warn "apt update 仍然失败，跳过二维码功能。"
          return 1
        fi
      fi

      if ! DEBIAN_FRONTEND=noninteractive apt install -y qrencode >>"$qr_log" 2>&1; then
        warn "qrencode 安装失败，跳过二维码功能。"
        return 1
      fi
    fi
  fi

  hash -r 2>/dev/null || true
  ok "二维码工具安装完成。"
}


# ---------- systemd ----------
ensure_systemd_service() {
  cat > "${TEMP_DIR}/sing-box.service" <<'EOF'
# proxyinstaller-minimal-v1
[Unit]
Description=Sing-box Service
After=network.target

[Service]
User=root
Type=simple
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  install -m 644 "${TEMP_DIR}/sing-box.service" "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
}
svc_restart() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sing-box

    # 等待 systemctl 状态稳定
    sleep 1
    if ! systemctl is-active --quiet sing-box; then
        sleep 2
    fi

    systemctl is-active --quiet sing-box \
        && ok "服务已启动。" \
        || die "服务启动失败，查看日志：tail -n 200 ${LOG_DIR}/sing-box.log"

  else
    rc-service sing-box restart
  fi
}

auto_cleanup_old_configs() {
  # 保留函数名以清楚标示原逻辑已停用：未知分片不会被自动删除。
  return 0
}
merge_config() {
  local candidate files=()
  if [ ! -f "${CONF_DIR}/00_base.json" ]; then
    cat > "${CONF_DIR}/00_base.json" <<'EOF'
{
  "log": { "disabled": true },
  "dns": { "servers": [ { "type": "local" } ], "strategy": "prefer_ipv4" },
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  fi
  files=("$CONF_DIR"/*.json)
  candidate=$(mktemp "${WORK_DIR}/.config.XXXXXXXX")
  # 对象递归合并、数组拼接，其余值采用后面的分片；保留 route 等未知顶层字段。
  if ! jq -s '
    def combine(a;b):
      if (a|type)=="object" and (b|type)=="object" then
        reduce (b|keys_unsorted[]) as $k (a; .[$k] =
          (if has($k) then combine(.[$k];b[$k]) else b[$k] end))
      elif (a|type)=="array" and (b|type)=="array" then a+b
      else b end;
    if all(.[]; type=="object") then reduce .[] as $part ({}; combine(.;$part))
    else error("configuration fragments must be JSON objects") end
  ' "${files[@]}" > "$candidate"; then
    rm -f -- "$candidate"; err '配置合并失败，运行配置未替换。'; return 1
  fi
  if ! "${WORK_DIR}/sing-box" check -c "$candidate"; then
    rm -f -- "$candidate"; err '核心配置检查失败，运行配置未替换。'; return 1
  fi
  chmod 600 "$candidate"
  mv -f -- "$candidate" "$WORK_DIR/config.json"
}
# ---------- 公共输入 ----------
valid_ipv4() {
  local address="$1" octet
  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local parts=()
  IFS='.' read -r -a parts <<< "$address"
  for octet in "${parts[@]}"; do (( 10#$octet <= 255 )) || return 1; done
  [[ "$address" != 0.* && "$address" != 127.* ]] || return 1
}

read_ip_default() {
  local endpoint candidate=''
  SERVER_IP=''
  for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    candidate=$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || true)
    candidate="${candidate//$'\r'/}"; candidate="${candidate//$'\n'/}"
    if valid_ipv4 "$candidate"; then SERVER_IP="$candidate"; break; fi
  done
  if [ -z "$SERVER_IP" ]; then
    prompt_read '无法自动获取公网 IPv4，请输入 VPS 的公网 IPv4：' SERVER_IP || die '读取 IP 失败。'
    valid_ipv4 "$SERVER_IP" || die 'IPv4 地址格式不正确。'
  fi
  printf '%s\n' "$SERVER_IP" > "${WORK_DIR}/server-ip"
  ok "检测到公网 IP: ${SERVER_IP}"
}

stored_server_ip() {
  local address
  address=$(cat "${WORK_DIR}/server-ip" 2>/dev/null) || { err '找不到已保存的节点 IP。'; return 1; }
  valid_ipv4 "$address" || { err '保存的节点 IP 无效。'; return 1; }
  printf '%s\n' "$address"
}

valid_domain() {
  local domain="$1" label
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
  [[ "$domain" == *.* && "$domain" != *..* && "$domain" != .* && "$domain" != *. ]] || return 1
  local labels=()
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
  done
}
read_uuid() {
  # Auto-generate UUID silently
  UUID=$(cat /proc/sys/kernel/random/uuid)
  ok "已生成 UUID: ${UUID}"
}

read_port() {
  local hint="$1" def="$2"
  prompt_read "$hint [按回车默认: $def]： " PORT || die "读取输入失败，请在交互式终端中运行脚本。"
  PORT="${PORT:-$def}"
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die '端口必须为数字。'
  PORT=$((10#$PORT))
  (( PORT>=100 && PORT<=65535 )) || die '端口必须在 100~65535。'
}
# ---------- 1) 安装 VLESS + TCP + Reality ----------
install_vless_tcp_reality() {


  ensure_singbox
  ensure_systemd_service
  

  ok "开始安装 VLESS + TCP + Reality 协议"
  read_ip_default
  read_uuid
  prompt_read "Reality 域名（sni/握手域名）[按回车默认: ${TLS_SERVER_DEFAULT}]： " TLS_DOMAIN || die "读取输入失败，请在交互式终端中运行脚本。"
  TLS_DOMAIN="${TLS_DOMAIN:-$TLS_SERVER_DEFAULT}"
  valid_domain "$TLS_DOMAIN" || die "Reality 域名格式无效，请填写不带 https:// 和路径的域名。"
  DEFAULT_PORT_REALITY=$(find_free_port "$DEFAULT_PORT_REALITY")
  read_port "监听端口" "$DEFAULT_PORT_REALITY"
  PORT=$(find_free_port "$PORT")
  enable_bbr

  # 生成密钥对
  local kp priv pub
  kp="$("${WORK_DIR}/sing-box" generate reality-keypair)"
  priv="$(awk '/PrivateKey/{print $NF}' <<<"$kp")"
  pub="$(awk '/PublicKey/{print $NF}' <<<"$kp")"
  [[ "$priv" =~ ^[A-Za-z0-9_-]{43}$ && "$pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Reality 密钥生成失败。"
  echo "$priv" > "${CONF_DIR}/reality_private.key"
  echo "$pub"  > "${CONF_DIR}/reality_public.key"

  cat > "${CONF_DIR}/10_vless_tcp_reality.json" <<EOF
{
  "inbounds": [{
    "type": "vless",
    "tag": "vless-reality",
    "listen": "::",
    "listen_port": ${PORT},
    "users": [{ "uuid": "${UUID}" }],
    "tls": {
      "enabled": true,
      "server_name": "${TLS_DOMAIN}",
      "reality": {
        "enabled": true,
        "handshake": { "server": "${TLS_DOMAIN}", "server_port": 443 },
        "private_key": "${priv}",
        "short_id": [""]
      }
    }
  }]
}
EOF

  merge_config
  svc_restart

  ok "✅ VLESS + TCP + Reality 安装完成"


  ensure_qrencode || true
  link="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TLS_DOMAIN}&fp=chrome&pbk=${pub}&type=tcp#${SERVER_IP}"
  clean_link=$(echo -n "$link" | tr -d '\r\n')
  echo "导入链接："
  echo "$clean_link"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$clean_link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
    echo
     echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
  echo
  else
    warn "未检测到 qrencode，无法生成二维码。"
  fi
}


# ---------- 新增：VLESS + TCP + REALITY + Vision（独立于原选项） ----------
probe_vision_target() {
  local domain="$1" attempt output
  valid_domain "$domain" || { err '目标域名格式无效。'; return 1; }
  for ((attempt=1; attempt<=3; attempt++)); do
    output="${TEMP_DIR}/vision-target-${attempt}.log"
    if ! timeout 15s openssl s_client -4 -connect "${domain}:443" -servername "$domain" \
      -verify_hostname "$domain" -verify_return_error -CAfile /etc/ssl/certs/ca-certificates.crt \
      -tls1_3 -groups X25519 -alpn h2 </dev/null >"$output" 2>&1; then
      err "目标站第 ${attempt}/3 次握手失败；未创建 Vision 节点。"; return 1
    fi
    if ! grep -Eq '(New, TLSv1\.3|Protocol[[:space:]]*:[[:space:]]*TLSv1\.3|Protocol version:[[:space:]]*TLSv1\.3)' "$output" || \
       ! grep -Eq '((Server|Peer) Temp Key:[[:space:]]*X25519|Negotiated TLS1\.3 group:[[:space:]]*X25519)' "$output" || \
       ! grep -Eq 'Verify return code:[[:space:]]*0[[:space:]]*\(ok\)' "$output" || \
       ! grep -Eq 'ALPN protocol:[[:space:]]*h2[[:space:]]*$' "$output"; then
      err "目标站第 ${attempt}/3 次未同时满足 TLS 1.3、X25519、证书验证和 h2；未创建 Vision 节点。"; return 1
    fi
    ok "本 VPS → ${domain}:443：第 ${attempt}/3 次握手检查通过。"
  done
}

vision_port_is_free() {
  local port="$1" available file status
  available=$(find_free_port "$port") || return 2
  [ "$available" = "$port" ] || return 1
  # 未运行的旧分片同样保留其端口，避免重启后才发现重复监听。
  for file in "$CONF_DIR"/*.json; do
    [ -f "$file" ] || continue
    if jq -e --argjson p "$port" '[.. | objects | .listen_port? // empty] | index($p) != null' "$file" >/dev/null; then
      return 1
    else
      status=$?; [ "$status" -eq 1 ] || return 2
    fi
  done
  return 0
}

suggest_vision_port() {
  local candidate="$1" attempt status
  for ((attempt=0; attempt<100; attempt++)); do
    candidate=$(find_free_port "$candidate") || return 1
    if vision_port_is_free "$candidate"; then printf '%s\n' "$candidate"; return 0
    else status=$?; [ "$status" -eq 1 ] || return 1; fi
    candidate=$((candidate + 1)); [ "$candidate" -le 65535 ] || candidate=100
  done
  err '无法确认可用替代端口，请先检查现有监听和配置。'; return 1
}

vision_uri() {
  local file="${CONF_DIR}/11_vless_tcp_reality_vision.json" uuid port sni flow sid pub server_ip
  [ -f "$file" ] || { err '未检测到独立 Vision 配置。'; return 1; }
  uuid=$(jq -er '.inbounds[0].users[0].uuid' "$file") || return 1
  port=$(jq -er '.inbounds[0].listen_port' "$file") || return 1
  sni=$(jq -er '.inbounds[0].tls.server_name' "$file") || return 1
  flow=$(jq -er '.inbounds[0].users[0].flow' "$file") || return 1
  sid=$(jq -er '.inbounds[0].tls.reality.short_id[0]' "$file") || return 1
  pub=$(cat "${CONF_DIR}/vision_public.key") || return 1
  server_ip=$(stored_server_ip) || return 1
  [[ "$uuid" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] && \
    [[ "$port" =~ ^[0-9]{1,5}$ && "$pub" =~ ^[A-Za-z0-9_-]{43}$ && "$sid" =~ ^[a-fA-F0-9]{16}$ ]] && \
    (( 10#$port>=100 && 10#$port<=65535 )) && [ "$flow" = xtls-rprx-vision ] && valid_domain "$sni" || { err 'Vision 分享参数不完整，拒绝生成错误链接。'; return 1; }
  printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=%s&fp=ios&pbk=%s&sid=%s#%s-Vision-iOS\n' \
    "$uuid" "$server_ip" "$port" "$sni" "$pub" "$sid" "$server_ip"
}

show_vision_link() {
  local link
  link=$(vision_uri) || return 1
  echo '🔹 VLESS TCP REALITY Vision · iOS 指纹'
  printf '%s\n' "$link"
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn '二维码生成失败，仍可使用上方分享链接。'
  fi
  echo '客户端导入后核对：MUX、TCP 快速打开、分片、允许不安全关闭；ECH 留空。'
}

install_vless_tcp_reality_vision() {
  local file="${CONF_DIR}/11_vless_tcp_reality_vision.json" path suggested status kp priv pub sid version_output
  for path in "$file" "${CONF_DIR}/vision_private.key" "${CONF_DIR}/vision_public.key"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || die '独立 Vision 配置或密钥已存在；请用管理选项修改，不会覆盖现有节点。'
  done
  ensure_singbox
  version_output=$("${WORK_DIR}/sing-box" version)
  ok "使用已安装核心：${version_output%%$'\n'*}（不升级）"
  if [ -e "${WORK_DIR}/server-ip" ]; then
    SERVER_IP=$(stored_server_ip) || die '已有节点入口 IPv4 无效；拒绝自动覆盖，请先核对原入口。'
    ok "沿用已有节点入口 IPv4: ${SERVER_IP}"
  else
    read_ip_default
  fi
  prompt_read 'REALITY 目标域名 [按回车默认: www.kernel.org]： ' TLS_DOMAIN || die '读取目标域名失败。'
  TLS_DOMAIN="${TLS_DOMAIN:-www.kernel.org}"
  valid_domain "$TLS_DOMAIN" || die '请填写不带协议和路径的有效域名。'
  probe_vision_target "$TLS_DOMAIN" || die '本 VPS 的目标站检查未通过，停止新增节点。'
  suggested=$(suggest_vision_port 443) || die '无法确认可用端口。'
  [ "$suggested" = 443 ] || warn "443 已被监听或现有配置保留；可用替代端口为 ${suggested}，不会抢占旧端口。"
  read_port '新 Vision 节点监听端口' "$suggested"
  if vision_port_is_free "$PORT"; then :
  else status=$?; [ "$status" -eq 1 ] && die '所选端口已被使用或保留，请重新选择。'; die '端口或现有配置检查失败。'; fi
  read_uuid >/dev/null
  kp=$("${WORK_DIR}/sing-box" generate reality-keypair)
  priv=$(awk '$1=="PrivateKey:" && NF==2 {print $2}' <<<"$kp")
  pub=$(awk '$1=="PublicKey:" && NF==2 {print $2}' <<<"$kp")
  [[ "$priv" =~ ^[A-Za-z0-9_-]{43}$ && "$pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Vision 密钥生成失败。'
  sid=$(openssl rand -hex 8)
  [[ "$sid" =~ ^[0-9a-f]{16}$ ]] || die 'Vision short ID 生成失败。'
  printf '%s\n' "$priv" > "${CONF_DIR}/vision_private.key"
  printf '%s\n' "$pub" > "${CONF_DIR}/vision_public.key"
  cat > "$file" <<EOF
{
  "inbounds": [{
    "type": "vless", "tag": "vless-reality-vision",
    "listen": "0.0.0.0", "listen_port": ${PORT}, "tcp_fast_open": false,
    "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
    "multiplex": { "enabled": false },
    "tls": { "enabled": true, "server_name": "${TLS_DOMAIN}",
      "reality": { "enabled": true,
        "handshake": { "server": "${TLS_DOMAIN}", "server_port": 443 },
        "private_key": "${priv}", "short_id": ["${sid}"]
      }
    }
  }]
}
EOF
  chmod 600 "$file" "${CONF_DIR}/vision_private.key" "${CONF_DIR}/vision_public.key"
  merge_config
  ensure_systemd_service
  svc_restart
  ok '独立 Vision 节点已安装；原协议配置和原 REALITY 密钥保留。'
  ok '三次目标站检查仅验证本 VPS 当前的握手兼容性，不代表隐蔽性或长期可用性。'
  ensure_qrencode || true
  show_vision_link
}



# ---------- 2) 安装 VMESS + WS ----------
find_free_port() {
  local port="$1" sockets attempt
  command -v ss >/dev/null 2>&1 || { err '缺少 ss，无法可靠检查端口。'; return 1; }
  sockets=$(ss -H -tuln) || { err '读取监听端口失败。'; return 1; }
  for ((attempt=0; attempt<65436; attempt++)); do
    if ! awk -v port="$port" '$5 ~ ":" port "$" { found=1 } END { exit !found }' <<< "$sockets"; then
      printf '%s\n' "$port"; return 0
    fi
    port=$((port + 1)); [ "$port" -le 65535 ] || port=100
  done
  err '没有找到可用监听端口。'; return 1
}
install_vmess_ws() {
  ok "开始安装 VMESS + WS协议"




  ensure_singbox
  ensure_systemd_service

  read_ip_default
  read_uuid
  DEFAULT_PORT_WS=$(find_free_port "$DEFAULT_PORT_WS")
  read_port "监听端口" "$DEFAULT_PORT_WS"
  PORT=$(find_free_port "$PORT")
  enable_bbr

  local path="/${UUID}-vmess"

  cat > "${CONF_DIR}/13_vmess_ws.json" <<EOF
{
  "inbounds": [
    {
       "type": "vmess",
      "tag": "vmess-ws",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "transport": {
        "type": "ws",
        "path": "${path}"
      }
    }
  ]
}
EOF

  merge_config
  svc_restart

  ok "✅ VMESS + WS 已安装完成"

  ensure_qrencode || true
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' \
        "$SERVER_IP" "$SERVER_IP" "$PORT" "$UUID" "$path")
  b64=$(echo -n "$json" | base64 -w0)

  link="vmess://${b64}"
  clean_link=$(echo -n "$link" | tr -d '\r\n')

  echo "导入链接："
  echo "$clean_link"

  echo
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$clean_link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
    echo
     echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
  echo
  else
    warn "未检测到 qrencode，无法生成二维码。"
  fi
}


# ---------- 3) 安装 Shadowsocks（中转） ----------
install_shadowsocks() {


  ensure_singbox
  ensure_systemd_service

  ok "开始安装 Shadowsocks"
  read_ip_default
   SS_PASS=$(cat /proc/sys/kernel/random/uuid)
  ok "已生成 Shadowsocks 密码: ${SS_PASS}"

   DEFAULT_PORT_SS=$(find_free_port "$DEFAULT_PORT_SS")
  read_port "监听端口" "$DEFAULT_PORT_SS"
  PORT=$(find_free_port "$PORT")
  enable_bbr
  local method="aes-128-gcm"

  cat > "${CONF_DIR}/12_ss.json" <<EOF
{
  "inbounds": [{
    "type": "shadowsocks",
    "tag": "shadowsocks",
    "listen": "::",
    "listen_port": ${PORT},
    "method": "${method}",
    "password": "${SS_PASS}"
  }]
}
EOF
  merge_config
  svc_restart
  ok "✅ Shadowsocks 已安装完成"

  ensure_qrencode || true
  local b64
  b64="$(printf '%s' "${method}:${SS_PASS}@${SERVER_IP}:${PORT}" | base64 | tr -d '\n')"
  link="ss://${b64}#${SERVER_IP}"
  clean_link=$(echo -n "$link" | tr -d '\r\n')

  echo "导入链接："
  echo "$clean_link"

  echo
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$clean_link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
    echo
     echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
    echo
  else
    warn "未检测到 qrencode，无法生成二维码。"
  fi
}

# ---------- 5) 启用 BBR ----------
enable_bbr() {
  local old_qdisc old_cc available temp_bbr
  ok '检查并启用 BBR...'
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if [[ " $available " != *' bbr '* ]]; then
    warn '当前内核不支持 BBR，保留原拥塞控制设置。'; return 0
  fi
  old_qdisc=$(sysctl -n net.core.default_qdisc)
  old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  if ! sysctl -q -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr; then
    sysctl -q -w "net.core.default_qdisc=$old_qdisc" "net.ipv4.tcp_congestion_control=$old_cc" || true
    warn '无法启用 BBR，已尝试恢复原设置。'; return 0
  fi
  if [ ! -f "${WORK_DIR}/bbr.previous" ]; then
    printf '%s\n%s\n' "$old_qdisc" "$old_cc" > "${WORK_DIR}/bbr.previous"
  fi
  temp_bbr=$(mktemp /etc/sysctl.d/.proxyinstaller-bbr.XXXXXXXX)
  printf '# %s\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' "$MANAGED_ID" > "$temp_bbr"
  chmod 644 "$temp_bbr"; mv -f -- "$temp_bbr" "$BBR_FILE"
  ok 'BBR 已启用。'
}
# ---------- 6) 修改端口 ----------
change_port() {
  echo "选择要修改端口的协议："
  echo "1) VLESS Reality"
  echo "2) VMESS WS"
  echo "3) Shadowsocks"
  echo "4) 独立 VLESS REALITY Vision"
  prompt_read "输入 1/2/3/4：" which || die "读取输入失败，请在交互式终端中运行脚本。"
  which="${which//[[:space:]]/}"
  case "$which" in
    1) file="${CONF_DIR}/10_vless_tcp_reality.json" ;;
    2) file="${CONF_DIR}/13_vmess_ws.json" ;;
    3) file="${CONF_DIR}/12_ss.json" ;;
    4) file="${CONF_DIR}/11_vless_tcp_reality_vision.json" ;;
    *) die "无效选择" ;;
  esac

  [ -f "$file" ] || die "未检测到对应协议配置，请先安装该协议。"

  local SUGGESTED_PORT=$((RANDOM % 50001 + 10000))
  SUGGESTED_PORT=$(find_free_port "$SUGGESTED_PORT")

  read_port "新端口" "$SUGGESTED_PORT"
  if [ "$which" = 4 ]; then
    if [ "$PORT" = "$(jq -r '.inbounds[0].listen_port' "$file")" ]; then ok '端口未变。'; return 0; fi
    vision_port_is_free "$PORT" || die '新端口已占用、被现有配置保留或无法检查；没有自动改用其他端口。'
  else PORT=$(find_free_port "$PORT"); fi

  update_json_file "$file" --argjson p "$PORT" '(.. | objects | select(has("listen_port"))).listen_port = $p'

  merge_config
  svc_restart

  ok "端口已修改为: $PORT"
  echo
  echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
  echo
}


# ---------- 7) 修改用户名/密码 ----------
change_user_cred() {
  echo "选择要修改凭据的协议："
  echo "1) VLESS Reality / VMESS WS（会同时修改 UUID）"
  echo "2) Shadowsocks 密码"
  echo "3) 独立 VLESS REALITY Vision UUID"
  prompt_read "输入 1/2/3：" which || die "读取输入失败，请在交互式终端中运行脚本。"
  which="${which//[[:space:]]/}"
  case "$which" in
    1)
      local f1="${CONF_DIR}/10_vless_tcp_reality.json"
      local f2="${CONF_DIR}/13_vmess_ws.json"
      read_uuid
      local credential_file
      credential_file=$(mktemp "${TEMP_DIR}/credential.XXXXXXXX")
      printf '%s' "$UUID" > "$credential_file"
      for f in "$f1" "$f2"; do
        [ -f "$f" ] || continue
        update_json_file "$f" --rawfile u "$credential_file" '(.. | objects | select(has("users")) | .users[]? | select(has("uuid"))).uuid = $u' 
      done
      rm -f -- "$credential_file"
      merge_config
      svc_restart
      ok "VLESS / VMESS UUID 已修改。"
      echo
       echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
      echo
      ;;
    2)
      local f="${CONF_DIR}/12_ss.json"
      [ -f "$f" ] || die "未检测到 Shadowsocks 配置。"
      prompt_read "新的 SS 密码：" newpass || die "读取输入失败，请在交互式终端中运行脚本。"
      [ -n "$newpass" ] || die "密码不可为空。"
      local credential_file
      credential_file=$(mktemp "${TEMP_DIR}/credential.XXXXXXXX")
      printf '%s' "$newpass" > "$credential_file"
      update_json_file "$f" --rawfile p "$credential_file" '(.. | objects | select(has("password"))).password = $p'
      rm -f -- "$credential_file"
      merge_config
      svc_restart
      ok "Shadowsocks 密码已修改。"
      echo
      echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
      echo
      ;;
    3)
      local f="${CONF_DIR}/11_vless_tcp_reality_vision.json" credential_file
      [ -f "$f" ] || die '未检测到独立 Vision 配置。'
      read_uuid
      credential_file=$(mktemp "${TEMP_DIR}/credential.XXXXXXXX")
      printf '%s' "$UUID" > "$credential_file"
      update_json_file "$f" --rawfile u "$credential_file" '.inbounds[0].users[0].uuid = $u'
      rm -f -- "$credential_file"
      merge_config
      svc_restart
      ok '独立 Vision UUID 已修改，其他协议凭据保持原样。'
      ;;
    *) die "无效选择" ;;
  esac
}

# ---------- 8) 卸载 ----------
uninstall_all() {
  warn '即将卸载本补丁管理的 sing-box、协议配置和服务；未知文件与备份会保留。'
  local y qdisc cc
  prompt_read '确认卸载？(y/N): ' y || die '读取输入失败。'
  [[ "${y,,}" == y ]] || { echo '已取消。'; return 0; }
  begin_transaction
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f -- "$UNIT_FILE" "$MENU_FILE" "$BBR_FILE"
  systemctl daemon-reload
  if [ -f "$WORK_DIR/bbr.previous" ]; then
    { IFS= read -r qdisc; IFS= read -r cc; } < "$WORK_DIR/bbr.previous"
    if [[ "$qdisc" =~ ^[a-zA-Z0-9_]+$ && "$cc" =~ ^[a-zA-Z0-9_]+$ ]]; then
      sysctl -q -w "net.core.default_qdisc=$qdisc" "net.ipv4.tcp_congestion_control=$cc" || true
    fi
  fi
  remove_owned_files
  ok '本补丁管理的文件已卸载；备份仍保留在 /var/backups/proxyinstaller。'
  [ ! -e "$WORK_DIR" ] || warn "$WORK_DIR 仍含未知文件，已保留。"
}
# ---------- 9) 查看已生成的链接 ----------
show_generated_links() {
  echo
  echo "=============================="
  echo " 已生成的链接与二维码"
  echo "=============================="
  echo
  local found_any=false

  if [ -f "${CONF_DIR}/11_vless_tcp_reality_vision.json" ]; then
    found_any=true
    show_vision_link
    echo
  fi

  # --- VLESS Reality ---
  local f1="${CONF_DIR}/10_vless_tcp_reality.json"
  if [ -f "$f1" ]; then
    found_any=true
    local uuid port sni pub server_ip
    uuid=$(jq -r '..|objects|select(has("users"))|.users[]?.uuid' "$f1" | head -n1)
    port=$(jq -r '..|objects|select(has("listen_port"))|.listen_port' "$f1" | head -n1)
    sni=$(jq -r '..|objects|select(has("server_name"))|.server_name' "$f1" | head -n1)
    pub=$(cat "${CONF_DIR}/reality_public.key" 2>/dev/null || echo "")
    server_ip=$(stored_server_ip)
    link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&type=tcp#${server_ip}"

    echo "🔹 VLESS Reality"
    echo -e "${YELLOW}${link}${RESET}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
      printf '%s' "$link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
      echo
      echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
      echo
    else
      warn "未检测到 qrencode，无法生成二维码。"
    fi
  fi

  # --- VMESS WS ---
  local f2="${CONF_DIR}/13_vmess_ws.json"
  if [ -f "$f2" ]; then
    found_any=true
    local uuid port path server_ip
    uuid=$(jq -r '..|objects|select(has("users"))|.users[]?.uuid' "$f2" | head -n1)
    port=$(jq -r '..|objects|select(has("listen_port"))|.listen_port' "$f2" | head -n1)
    path=$(jq -r '..|objects|select(has("transport"))|.transport.path' "$f2" | head -n1)
    server_ip=$(stored_server_ip)
    
    # Generate VMESS link (not VLESS)
    local json b64
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' \
          "$server_ip" "$server_ip" "$port" "$uuid" "$path")
    b64=$(echo -n "$json" | base64 -w0)
    link="vmess://${b64}"

    echo "🔹 VMESS WS"
    echo -e "${YELLOW}${link}${RESET}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
      printf '%s' "$link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
      echo
      echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
      echo
    else
      warn "未检测到 qrencode，无法生成二维码。"
    fi
  fi

  # --- Shadowsocks ---
  local f3="${CONF_DIR}/12_ss.json"
  if [ -f "$f3" ]; then
    found_any=true
    local pass port method server_ip b64
    pass=$(jq -r '..|objects|select(has("password"))|.password' "$f3" | head -n1)
    port=$(jq -r '..|objects|select(has("listen_port"))|.listen_port' "$f3" | head -n1)
    method=$(jq -r '..|objects|select(has("method"))|.method' "$f3" | head -n1)
    server_ip=$(stored_server_ip)
    b64=$(printf '%s' "${method}:${pass}@${server_ip}:${port}" | base64 | tr -d '\n')
    link="ss://${b64}#${server_ip}"

    echo "🔹 Shadowsocks"
    echo -e "${YELLOW}${link}${RESET}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
      printf '%s' "$link" | qrencode -t ANSIUTF8 -m 1 -s 1 || warn "二维码生成失败，仍可使用上方分享链接。"
      echo
      echo -e "\033[32m\033[01m如果需要重新打开安装菜单，请输入：\033[0m\033[33mmenu\033[0m"
      echo  
    else
      warn "未检测到 qrencode，无法生成二维码。"
    fi
  fi

  if [ "$found_any" = false ]; then
    warn "未检测到任何已安装的协议配置。"
  fi
}


# ---------- 快捷命令 ----------
install_shortcut() {
  local staged
  staged=$(mktemp "${WORK_DIR}/.installer.XXXXXXXX")
  cp -- "$SCRIPT_SOURCE" "$staged"
  chmod 700 "$staged"; mv -f -- "$staged" "$WORK_DIR/installer.sh"
  cat > "${TEMP_DIR}/menu" <<'EOF'
#!/usr/bin/env bash
# proxyinstaller-minimal-v1
exec bash /etc/sing-box/installer.sh "$@"
EOF
  install -m 700 "${TEMP_DIR}/menu" "$MENU_FILE"
  ok '重新打开安装菜单请输入：menu'
}

# ---------- 小范围变更保护：原路径和菜单不变 ----------
update_json_file() {
  local source="$1" candidate
  shift
  candidate=$(mktemp "${CONF_DIR}/.edit.XXXXXXXX")
  if ! jq "$@" "$source" > "$candidate"; then
    rm -f -- "$candidate"
    die '修改 JSON 失败，原配置未替换。'
  fi
  chmod 600 "$candidate"
  mv -f -- "$candidate" "$source"
}

guard_managed() {
  local path fragment dropins
  dropins=$(systemctl show -p DropInPaths --value sing-box.service 2>/dev/null || true)
  [ -z "$dropins" ] || die "检测到 sing-box 服务的其他覆盖配置，停止修改：$dropins"
  fragment=$(systemctl show -p FragmentPath --value sing-box.service 2>/dev/null || true)
  [ -z "$fragment" ] || [ "$fragment" = "$UNIT_FILE" ] || \
    die "检测到其他部署的 sing-box 服务，不会覆盖：$fragment"
  if [ -e "$WORK_DIR" ] || [ -L "$WORK_DIR" ]; then
    [ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] && \
      [ -f "$WORK_DIR/.proxyinstaller-managed" ] && [ ! -L "$WORK_DIR/.proxyinstaller-managed" ] && \
      [ "$(cat "$WORK_DIR/.proxyinstaller-managed")" = "$MANAGED_ID" ] || \
      die "发现非本补丁管理的 ${WORK_DIR}，已停止覆盖。旧部署需要先单独备份/迁移。"
    for path in "$CONF_DIR" "$LOG_DIR"; do
      [ ! -L "$path" ] || die "管理目录不可为符号链接：$path"
    done
    for path in "${OWNED_FILES[@]}"; do
      [ ! -L "$WORK_DIR/$path" ] || die "管理文件不可为符号链接：$path"
    done
  else
    [ -z "$fragment" ] || die "检测到已有 sing-box 服务：${fragment}；不会覆盖其他部署。"
  fi
  for path in "$UNIT_FILE" "$MENU_FILE" "$BBR_FILE"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] && grep -Fq "# $MANAGED_ID" "$path" || \
        die "检测到其他程序管理的文件，不会覆盖：$path"
    fi
  done
}

action_context() {
  [ -f "$SCRIPT_SOURCE" ] && [ -s "$SCRIPT_SOURCE" ] && [ ! -L "$SCRIPT_SOURCE" ] || \
    die '请先把本脚本下载到普通文件再运行；不支持 bash <(curl ...) 这种入口，以免本地 menu 保存不完整。'
  command -v flock >/dev/null 2>&1 || die '系统缺少 flock，请先安装 util-linux。'
  [ ! -L /run/proxyinstaller.lock ] || die '锁文件不应为符号链接。'
  exec 9>/run/proxyinstaller.lock
  flock -n 9 || die '另一个安装或管理操作正在运行，请稍后重试。'
  TEMP_DIR=$(mktemp -d /tmp/proxyinstaller.XXXXXXXX)
  chmod 700 "$TEMP_DIR"
  guard_managed
}

backup_is_ours() {
  local directory="$1"
  [ "${directory%/*}" = "$BACKUP_ROOT" ] && \
    [[ "${directory##*/}" =~ ^change\.[[:alnum:]]{8}$ ]] && \
    [ -d "$directory" ] && [ ! -L "$directory" ] && \
    [ -f "$directory/.proxyinstaller-backup" ] && [ ! -L "$directory/.proxyinstaller-backup" ] && \
    [ "$(cat "$directory/.proxyinstaller-backup")" = "$MANAGED_ID" ]
}

backup_is_complete() {
  local directory="$1"
  backup_is_ours "$directory" && \
    [ -f "$directory/.complete" ] && [ ! -L "$directory/.complete" ] && \
    [ "$(cat "$directory/.complete")" = complete ]
}

prune_backups() {
  local limit="$1" directory timestamp count
  local backups=()
  while read -r timestamp directory; do backups+=("$directory"); done < <(
    for directory in "$BACKUP_ROOT"/change.*; do
      if backup_is_complete "$directory"; then
        printf '%s %s\n' "$(stat -c %Y "$directory")" "$directory"
      fi
    done | sort -n
  )
  count=${#backups[@]}
  [ "$count" -gt "$limit" ] || return 0
  for directory in "${backups[@]}"; do
    [ "$count" -gt "$limit" ] || break
    [ "$directory" != "$BACKUP_DIR" ] && [ ! -e "$directory/.needs-recovery" ] && [ ! -L "$directory/.needs-recovery" ] || continue
    backup_is_complete "$directory" || die '备份标记发生变化，停止清理。'
    rm -rf -- "$directory"
    count=$((count - 1))
  done
  [ "$count" -le "$limit" ] || die '受保护的失败备份已占满保留配额，请先处理恢复备份；本次未修改配置。'
}

check_backup_space() {
  local size_kib=0 available_kib required_kib
  [ ! -d "$WORK_DIR" ] || size_kib=$(du -sk -- "$WORK_DIR" | awk '{print $1}')
  available_kib=$(df -Pk -- "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
  [[ "$size_kib" =~ ^[0-9]+$ && "$available_kib" =~ ^[0-9]+$ ]] || die '无法确认备份可用空间，本次未修改配置。'
  required_kib=$((size_kib + 32768))
  [ "$available_kib" -ge "$required_kib" ] || \
    die "备份空间不足：需约 $required_kib KiB（含32MiB余量），可用 $available_kib KiB；本次未修改配置。未标记的旧备份不会自动删除。"
}

begin_transaction() {
  local path label
  [ ! -L "$BACKUP_ROOT" ] || die '备份目录不可为符号链接。'
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  # 留出本次快照的位置；只清理已完成且有本补丁标记的旧快照，至少保留已有的有效快照。
  prune_backups "$((BACKUP_KEEP - 1))"
  check_backup_space
  BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/change.XXXXXXXX")
  printf '%s\n' "$MANAGED_ID" > "$BACKUP_DIR/.proxyinstaller-backup"
  [ ! -d "$WORK_DIR" ] || cp -a -- "$WORK_DIR" "$BACKUP_DIR/workdir"
  for label in unit menu bbr; do
    case "$label" in unit) path="$UNIT_FILE";; menu) path="$MENU_FILE";; bbr) path="$BBR_FILE";; esac
    [ ! -f "$path" ] || cp -a -- "$path" "$BACKUP_DIR/$label"
  done
  systemctl is-active --quiet sing-box && WAS_ACTIVE=1 || WAS_ACTIVE=0
  systemctl is-enabled --quiet sing-box 2>/dev/null && WAS_ENABLED=1 || WAS_ENABLED=0
  QDISC_BEFORE=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  CC_BEFORE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  printf 'complete\n' > "$BACKUP_DIR/.complete"
  TRANSACTION_ACTIVE=1
}

remove_owned_files() {
  local name
  for name in "${OWNED_FILES[@]}"; do rm -f -- "$WORK_DIR/$name"; done
  rmdir -- "$CONF_DIR" "$LOG_DIR" "$WORK_DIR" 2>/dev/null || true
}

rollback_transaction() {
  local path label failed=0
  warn "操作未完成，正在恢复：$BACKUP_DIR"
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  remove_owned_files
  if [ -d "$BACKUP_DIR/workdir" ]; then
    mkdir -p "$WORK_DIR"
    cp -a -- "$BACKUP_DIR/workdir/." "$WORK_DIR/" || failed=1
  fi
  for label in unit menu bbr; do
    case "$label" in unit) path="$UNIT_FILE";; menu) path="$MENU_FILE";; bbr) path="$BBR_FILE";; esac
    if [ -f "$BACKUP_DIR/$label" ]; then cp -a -- "$BACKUP_DIR/$label" "$path" || failed=1
    else rm -f -- "$path" || failed=1; fi
  done
  systemctl daemon-reload || failed=1
  [ "$WAS_ENABLED" -ne 1 ] || systemctl enable sing-box >/dev/null 2>&1 || failed=1
  [ "$WAS_ACTIVE" -ne 1 ] || systemctl start sing-box || failed=1
  [ -z "$QDISC_BEFORE" ] || sysctl -q -w "net.core.default_qdisc=$QDISC_BEFORE" || failed=1
  [ -z "$CC_BEFORE" ] || sysctl -q -w "net.ipv4.tcp_congestion_control=$CC_BEFORE" || failed=1
  TRANSACTION_ACTIVE=0
  if [ "$failed" -eq 0 ]; then warn '已恢复变更前的配置和服务状态。'
  else
    printf 'manual recovery required\n' > "$BACKUP_DIR/.needs-recovery"
    err "自动恢复有步骤失败，备份已保护不会自动清理，请检查：$BACKUP_DIR"
  fi
}

finish_transaction() {
  TRANSACTION_ACTIVE=0
  ok "变更前备份：${BACKUP_DIR}（最多保留${BACKUP_KEEP}份完整备份；未知旧目录不自动删除）"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  [ "$TRANSACTION_ACTIVE" -ne 1 ] || rollback_transaction
  # 未进入变更事务的复制失败不会影响原配置；仅移除本次、带标记且未完成的副本。
  if [ -n "$BACKUP_DIR" ] && backup_is_ours "$BACKUP_DIR" && ! backup_is_complete "$BACKUP_DIR"; then
    rm -rf -- "$BACKUP_DIR"
  fi
  [ -z "$TEMP_DIR" ] || rm -rf -- "$TEMP_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

run_change() {
  local operation="$1"
  action_context
  case "$operation" in
    change_port|change_user_cred|uninstall_all)
      [ -d "$WORK_DIR" ] || die '尚未检测到本补丁管理的安装。' ;;
  esac
  if [ "$operation" = uninstall_all ]; then
    uninstall_all
    [ "$TRANSACTION_ACTIVE" -ne 1 ] || finish_transaction
    return 0
  fi
  begin_transaction
  mkdir -p "$WORK_DIR" "$CONF_DIR" "$LOG_DIR"
  chmod 700 "$WORK_DIR" "$CONF_DIR" "$LOG_DIR"
  printf '%s\n' "$MANAGED_ID" > "$WORK_DIR/.proxyinstaller-managed"
  install_deps
  "$operation"
  if [ -f "$WORK_DIR/.proxyinstaller-managed" ]; then install_shortcut; fi
  finish_transaction
}

show_links_action() {
  action_context
  [ -d "$WORK_DIR" ] || die '尚未检测到本补丁管理的安装。'
  show_generated_links
}

# ---------- 主菜单 ----------
main_menu() {
  clear 2>/dev/null || true

  echo -e "${GREEN}洪大流量中心 加密部署命令${RESET}"
  echo "版本：v0.2"
  echo "==================================="
  echo "1) 安装 VLESS + TCP + REALITY（原版，无 Vision）"
  echo "2) 安装 VMESS + WS"
  echo "3) 安装 Shadowsocks (AES-128-GCM)"
  echo "4) 启用 BBR 加速"
  echo "5) 修改端口"
  echo "6) 修改用户名/密码"
  echo "7) 卸载脚本"
  echo "8) 查看已生成的链接"
  echo "9) 退出"
  echo "10) 安装 VLESS + TCP + REALITY + Vision（iOS 指纹）"
  echo
  prompt_read "请选择 [1-10]: " opt || die "读取输入失败，请在交互式终端中运行脚本。"
  opt="${opt//[[:space:]]/}"
  case "$opt" in
    1) run_change install_vless_tcp_reality ;;
    2) run_change install_vmess_ws ;;
    3) run_change install_shadowsocks ;;
    4) run_change enable_bbr ;;
    5) run_change change_port ;;
    6) run_change change_user_cred ;;
    7) run_change uninstall_all ;;
    8) show_links_action ;;
    9) exit 0 ;;
    10) run_change install_vless_tcp_reality_vision ;;
    *) echo "无效选择";;
  esac
}

# ---------- 引导 ----------
need_root
detect_arch
detect_os
main_menu
