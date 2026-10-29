#!/bin/bash
# Standalone public-CA HY2 on UDP443. Run from the VPS provider console.
# Installs only studio-hy2; does not remove/reconfigure any existing proxy or SSH.
set -Eeuo pipefail
umask 077
export LC_ALL=C
studio_domain= studio_ip= studio_agree=0
while (($#)); do
    case "$1" in
        --domain) studio_domain=${2:?missing domain}; shift 2 ;;
        --server-ip) studio_ip=${2:?missing IPv4}; shift 2 ;;
        --agree-tos) studio_agree=1; shift ;;
        --help) echo 'Usage: bash deploy-hy2-generic.sh --domain HOST --server-ip IPV4 --agree-tos'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || fail 'Linux root required.'
[[ $studio_agree == 1 ]] || fail "Review the Let's Encrypt subscriber agreement, then add --agree-tos if accepted."
[[ $studio_domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $studio_domain == *.* && ${#studio_domain} -le 253 && $studio_domain != *..* ]] || fail 'Valid lowercase DNS hostname required.'
[[ $studio_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'IPv4 address required.'
test -d /run/systemd/system || fail 'A running systemd host is required.'
studio_systemd=$(systemctl --version | awk 'NR==1{print $2}')
[[ $studio_systemd =~ ^[0-9]+$ && $studio_systemd -ge 247 ]] || fail 'systemd >=247 required for isolated credentials; system not changed.'
test -r /etc/os-release || fail 'Missing OS release.'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || fail 'This script supports Debian and Ubuntu only.'
case $(uname -m) in
    x86_64) studio_arch=amd64; studio_sha=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
    aarch64|arm64) studio_arch=arm64; studio_sha=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
    *) fail 'Only amd64 and arm64 are supported; system not changed.' ;;
esac
studio_conf=/etc/studio-hy2
studio_bin=/opt/studio-hy2
studio_lineage=/etc/letsencrypt/live/studio-hy2
studio_unit=/etc/systemd/system/studio-hy2.service
studio_tmp=
cleanup() { local rc=$?; trap - EXIT; [[ -z $studio_tmp ]] || rm -rf -- "$studio_tmp"; if ((rc)); then echo "Deployment stopped (status $rc). Existing services were not removed. Inspect the preceding error; no insecure fallback was enabled." >&2; fi; exit "$rc"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
command -v flock >/dev/null || fail 'util-linux flock is required before installation.'
exec 9>/run/lock/studio-hy2-install.lock
flock -n 9 || fail 'Another studio-hy2 installation is running.'
# Refuse to overwrite an unrelated installation or follow privileged symlinks.
for p in "$studio_conf" "$studio_bin" "$studio_unit"; do test ! -L "$p" || fail "Unexpected symlink: $p"; done
if test -e "$studio_conf"; then
    test -d "$studio_conf" && test "$(stat -c %u "$studio_conf")" = 0 || fail 'Unsafe existing configuration directory.'
    test -f "$studio_conf/managed.json" || fail 'Existing configuration is not owned by this installer.'
elif test -e "$studio_bin" || test -e "$studio_unit" || test -e "$studio_lineage" || test -e /etc/systemd/system/studio-hy2-renew.service || test -e /etc/systemd/system/studio-hy2-renew.timer; then
    fail 'Existing installation has no ownership marker; inspect it manually.'
fi
echo 'Installing/checking distribution packages...'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends curl ca-certificates openssl python3 iproute2 util-linux iptables certbot
python3 -I - "$studio_domain" "$studio_ip" "$studio_conf" <<'PY'
import ipaddress,json,pathlib,re,socket,subprocess,sys
host,raw,root=sys.argv[1:]; ip=ipaddress.ip_address(raw)
assert ip.version==4 and ip.is_global, 'Public IPv4 required'
assert all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',p) for p in host.split('.')), 'Invalid hostname label'
interfaces=json.loads(subprocess.check_output(['ip','-j','-4','addr','show']))
assert raw in {a['local'] for i in interfaces for a in i.get('addr_info',[])}, 'IPv4 is not assigned to this VPS'
answers={x[4][0] for x in socket.getaddrinfo(host,443,socket.AF_INET,socket.SOCK_DGRAM)}
assert answers=={raw}, 'Hostname must resolve directly and exclusively to this IPv4; disable CDN proxy'
try: v6=socket.getaddrinfo(host,443,socket.AF_INET6,socket.SOCK_DGRAM)
except socket.gaierror: v6=[]
assert not v6, 'Remove AAAA records before using this IPv4-only deployment'
marker=pathlib.Path(root)/'managed.json'
if marker.exists():
 d=json.loads(marker.read_text()); assert d.get('format')==1 and d.get('server_ip')==raw and d.get('domain')==host, 'Existing deployment identity differs'
PY
studio_old_pid=$(systemctl show -p MainPID --value studio-hy2.service 2>/dev/null || true)
studio_udp=$(ss -H -lunp 'sport = :443')
if [[ -n $studio_udp ]]; then
    [[ $studio_old_pid =~ ^[1-9][0-9]*$ && $studio_udp == *"pid=$studio_old_pid,"* ]] || fail 'UDP443 is already used by another service; it was not stopped.'
fi
studio_chain=INPUT
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active$'; then
    studio_chain=ufw-user-input
fi
iptables -w 5 -n -L "$studio_chain" >/dev/null || fail 'Expected iptables input chain is unavailable.'
# An extra native nftables input hook could still drop packets after iptables.
# Do not rewrite such an unrelated firewall automatically.
if command -v nft >/dev/null; then
    nft -j list ruleset | python3 -I -c 'import json,sys; x=json.load(sys.stdin); c=[e["chain"] for e in x.get("nftables",[]) if "chain" in e]; bad=[v for v in c if v.get("hook")=="input" and v.get("family") in ("ip","inet") and not(v.get("family")=="ip" and v.get("table")=="filter" and v.get("name")=="INPUT")]; assert not bad,"Custom nftables input hooks require review; no firewall rules changed"'
fi
studio_tmp=$(mktemp -d /var/tmp/studio-hy2-install.XXXXXXXX)
curl -qfsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --retry 2 \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-$studio_arch.tar.gz" -o "$studio_tmp/core.tar.gz"
printf '%s  %s\n' "$studio_sha" "$studio_tmp/core.tar.gz" | sha256sum -c -
tar -xOf "$studio_tmp/core.tar.gz" "sing-box-1.14.4-linux-$studio_arch/sing-box" > "$studio_tmp/sing-box"
chmod 0755 "$studio_tmp/sing-box"
"$studio_tmp/sing-box" version | head -1
install -d -m 0700 "$studio_conf"
install -d -m 0755 "$studio_bin"
export STUDIO_HY2_DOMAIN="$studio_domain" STUDIO_HY2_IP="$studio_ip" STUDIO_HY2_CHAIN="$studio_chain" STUDIO_HY2_TMP="$studio_tmp"
python3 -I - <<'PY'
import json,os,pathlib
d=pathlib.Path('/etc/studio-hy2'); marker=d/'managed.json'
if not marker.exists():
 marker.write_text(json.dumps({'format':1,'domain':os.environ['STUDIO_HY2_DOMAIN'],'server_ip':os.environ['STUDIO_HY2_IP']})); marker.chmod(0o600)
# These inputs have already passed strict syntax checks. Quote as shell strings.
(d/'identity.env').write_text("STUDIO_IP='"+os.environ['STUDIO_HY2_IP']+"'\nSTUDIO_CHAIN='"+os.environ['STUDIO_HY2_CHAIN']+"'\n")
(d/'identity.env').chmod(0o600)
PY
cat > "$studio_conf/firewall.sh" <<'SH'
#!/bin/bash
set -euo pipefail
umask 077
source /etc/studio-hy2/identity.env
args=(-d "$STUDIO_IP" -p udp --dport 443 -m comment --comment studio-hy2-udp443 -j ACCEPT)
case ${1:-} in
 open)
  if ! iptables -w 5 -C "$STUDIO_CHAIN" "${args[@]}" 2>/dev/null; then iptables -w 5 -I "$STUDIO_CHAIN" 1 "${args[@]}"; fi ;;
 close)
  while iptables -w 5 -C "$STUDIO_CHAIN" "${args[@]}" 2>/dev/null; do iptables -w 5 -D "$STUDIO_CHAIN" "${args[@]}"; done ;;
 *) exit 2 ;;
esac
SH
cat > "$studio_conf/acme-close.sh" <<'SH'
#!/bin/bash
set -euo pipefail
umask 077
source /etc/studio-hy2/identity.env
state=/run/studio-hy2-acme
test ! -L "$state"
install -d -m 0700 "$state"
test ! -L "$state/lock" && test ! -L "$state/current"
exec 8>"$state/lock"; flock -w 20 8
if (($#)); then tag=$1; elif test -f "$state/current"; then read -r tag <"$state/current"; else exit 0; fi
[[ $tag =~ ^studio-hy2-acme-[0-9]+-[0-9]+-[0-9]+$ ]]
args=(-d "$STUDIO_IP" -p tcp --dport 80 -m comment --comment "$tag" -j ACCEPT)
while :; do
 if iptables -w 5 -C "$STUDIO_CHAIN" "${args[@]}" 2>/dev/null; then iptables -w 5 -D "$STUDIO_CHAIN" "${args[@]}"
 else rc=$?; test "$rc" -eq 1 || exit "$rc"; break; fi
done
if [[ $(systemctl show -p LoadState --value "$tag.timer") != not-found ]]; then systemctl stop "$tag.timer"; fi
if test -f "$state/current" && [[ $(cat "$state/current") == "$tag" ]]; then rm -f -- "$state/current"; fi
SH
cat > "$studio_conf/acme-open.sh" <<'SH'
#!/bin/bash
set -Eeuo pipefail
umask 077
source /etc/studio-hy2/identity.env
state=/run/studio-hy2-acme
test ! -L "$state"
install -d -m 0700 "$state"
test ! -L "$state/lock" && test ! -L "$state/current"
exec 8>"$state/lock"; flock -w 20 8
test -z "$(ss -H -ltn 'sport = :80')" || { echo 'TCP80 is occupied; no service was stopped.' >&2; exit 1; }
test ! -e "$state/current"
iptables -w 5 -n -L "$STUDIO_CHAIN" >/dev/null
tag="studio-hy2-acme-$(date +%s)-$$-$RANDOM"
failed() { rc=$1; trap - ERR HUP INT TERM; exec 8>&-; /etc/studio-hy2/acme-close.sh "$tag" || true; exit "$rc"; }
trap 'failed "$?"' ERR
trap 'failed 143' HUP INT TERM
printf '%s\n' "$tag" > "$state/current"
timeout 20s systemd-run --quiet --collect --unit="$tag" --service-type=oneshot --on-active=600s --timer-property=AccuracySec=1s --property=TimeoutStartSec=90s /bin/bash /etc/studio-hy2/acme-close.sh "$tag"
systemctl is-active --quiet "$tag.timer"
iptables -w 5 -I "$STUDIO_CHAIN" 1 -d "$STUDIO_IP" -p tcp --dport 80 -m comment --comment "$tag" -j ACCEPT
exec 8>&-
trap - ERR HUP INT TERM
SH
cat > "$studio_conf/acme-deploy.sh" <<'SH'
#!/bin/sh
set -eu
if [ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/studio-hy2 ] && systemctl is-active --quiet studio-hy2.service; then
 systemctl try-restart studio-hy2.service
fi
SH
chmod 0700 "$studio_conf/"*.sh
echo 'Obtaining/retaining the public-CA certificate (only temporary TCP80 access)...'
certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --no-directory-hooks --standalone --preferred-challenges http-01 --http-01-address "$studio_ip" \
    --cert-name studio-hy2 --key-type ecdsa --keep-until-expiring -d "$studio_domain" \
    --pre-hook "$studio_conf/acme-open.sh" --post-hook "$studio_conf/acme-close.sh" --deploy-hook "$studio_conf/acme-deploy.sh"
openssl verify -purpose sslserver -verify_hostname "$studio_domain" \
    -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$studio_lineage/chain.pem" "$studio_lineage/cert.pem"
openssl x509 -in "$studio_lineage/cert.pem" -checkend 86400 -noout
studio_cert_pub=$(openssl x509 -in "$studio_lineage/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
studio_key_pub=$(openssl pkey -in "$studio_lineage/privkey.pem" -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ $studio_cert_pub == "$studio_key_pub" ]] || fail 'Certificate/key mismatch.'
python3 -I - <<'PY'
import json,os,pathlib,secrets
from urllib.parse import quote
d=pathlib.Path('/etc/studio-hy2'); tmp=pathlib.Path(os.environ['STUDIO_HY2_TMP']); host=os.environ['STUDIO_HY2_DOMAIN']; ip=os.environ['STUDIO_HY2_IP']
auth=d/'auth.private'
if auth.exists():
 assert auth.is_file() and not auth.is_symlink(); password=auth.read_text().strip(); assert len(password)>=40
else:
 password=secrets.token_urlsafe(32); auth.write_text(password+'\n');auth.chmod(0o600)
cert='/run/credentials/studio-hy2.service/'
config={'log':{'level':'warn'},'dns':{'servers':[{'type':'local','tag':'local'}],'strategy':'ipv4_only'},'inbounds':[{'type':'hysteria2','tag':'hy2-in','listen':'0.0.0.0','listen_port':443,'users':[{'name':'client','password':password}],'ignore_client_bandwidth':True,'tls':{'enabled':True,'certificate_path':cert+'cert.pem','key_path':cert+'key.pem'},'masquerade':{'type':'string','status_code':200,'headers':{'Content-Type':'text/html; charset=utf-8'},'content':'<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>\n'}}], 'outbounds':[{'type':'direct','tag':'direct'}], 'route':{'default_domain_resolver':'local','rules':[{'action':'resolve','strategy':'ipv4_only'},{'ip_is_private':True,'action':'reject'},{'ip_cidr':[ip+'/32','::/0'],'action':'reject'}]}}
(tmp/'server.json').write_text(json.dumps(config)); (tmp/'server.json').chmod(0o600)
config['inbounds'][0]['tls'].update(certificate_path='/etc/letsencrypt/live/studio-hy2/fullchain.pem',key_path='/etc/letsencrypt/live/studio-hy2/privkey.pem')
(tmp/'check.json').write_text(json.dumps(config)); (tmp/'check.json').chmod(0o600)
(d/'node.private.txt').write_text('hysteria2://'+quote(password,safe='')+'@'+ip+':443/?sni='+host+'&insecure=0#HY2-'+ip+'\n');(d/'node.private.txt').chmod(0o600)
PY
"$studio_tmp/sing-box" check -c "$studio_tmp/check.json"
cat > "$studio_tmp/studio-hy2.service" <<'UNIT'
[Unit]
Description=Studio public-CA Hysteria2 UDP443
Wants=network-online.target
After=network-online.target ufw.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
DynamicUser=yes
UMask=0077
LoadCredential=server.json:/etc/studio-hy2/server.json
LoadCredential=cert.pem:/etc/letsencrypt/live/studio-hy2/fullchain.pem
LoadCredential=key.pem:/etc/letsencrypt/live/studio-hy2/privkey.pem
ExecStartPre=+/etc/studio-hy2/firewall.sh open
ExecStartPre=/opt/studio-hy2/sing-box check -c %d/server.json
ExecStart=/opt/studio-hy2/sing-box run -c %d/server.json
ExecStopPost=+/etc/studio-hy2/firewall.sh close
RuntimeMaxSec=infinity
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
LimitNOFILE=4096
MemoryMax=256M
TasksMax=64

[Install]
WantedBy=multi-user.target
UNIT
# Retain recovery copies of this installer's previous files, never other services.
for item in "$studio_conf/server.json" "$studio_bin/sing-box" "$studio_unit"; do
    if test -f "$item"; then cp -p -- "$item" "$item.previous"; fi
done
install -m 0755 "$studio_tmp/sing-box" "$studio_bin/sing-box.new"
install -m 0600 "$studio_tmp/server.json" "$studio_conf/server.json.new"
install -m 0644 "$studio_tmp/studio-hy2.service" "$studio_unit.new"
mv -f -- "$studio_bin/sing-box.new" "$studio_bin/sing-box"
mv -f -- "$studio_conf/server.json.new" "$studio_conf/server.json"
mv -f -- "$studio_unit.new" "$studio_unit"
cat > /etc/systemd/system/studio-hy2-renew.service <<'UNIT'
[Unit]
Description=Renew only the Studio HY2 certificate
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --cert-name studio-hy2 --non-interactive --no-random-sleep-on-renew --no-directory-hooks --quiet
UNIT
cat > /etc/systemd/system/studio-hy2-renew.timer <<'UNIT'
[Unit]
Description=Check Studio HY2 certificate twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemd-analyze verify "$studio_unit" /etc/systemd/system/studio-hy2-renew.service /etc/systemd/system/studio-hy2-renew.timer
systemctl daemon-reload
# On UFW systems add the one UDP rule persistently so a normal UFW reload retains it.
if [[ $studio_chain == ufw-user-input ]]; then
    ufw allow in proto udp from any to "$studio_ip" port 443 comment studio-hy2-udp443
fi
echo 'Checking automatic renewal against the CA staging environment...'
certbot renew --cert-name studio-hy2 --non-interactive --no-random-sleep-on-renew --no-directory-hooks --dry-run
test ! -f /run/studio-hy2-acme/current || fail 'Temporary ACME firewall cleanup is incomplete.'
systemctl enable studio-hy2.service studio-hy2-renew.timer
systemctl restart studio-hy2.service
systemctl start studio-hy2-renew.timer
# Type=simple can report started before sing-box has bound its socket.
studio_ready=0
for ((studio_attempt=0; studio_attempt<50; studio_attempt++)); do
    studio_pid=$(systemctl show -p MainPID --value studio-hy2.service)
    if [[ $studio_pid =~ ^[1-9][0-9]*$ ]] && systemctl is-active --quiet studio-hy2.service && \
       ss -H -lunp 'sport = :443' | grep -F "pid=$studio_pid," >/dev/null; then
        studio_ready=1; break
    fi
    sleep 0.2
done
[[ $studio_ready == 1 ]] || fail 'The new service did not become active and listen on UDP443 within 10 seconds.'
systemctl is-active --quiet studio-hy2-renew.timer
echo "READY: HY2 UDP443, strict public-CA certificate for $studio_domain, independent credentials, automatic renewal checked."
echo 'Private import link: /etc/studio-hy2/node.private.txt (root only). Do not publish it.'
echo 'Existing proxy/SSH services are retained. Client Google/YouTube and correct-exit tests are still required before deleting old nodes.'
