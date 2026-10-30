#!/bin/bash
# Add HTTPS TCP443 to an existing Studio HY2 download page. No remote payloads.
# Supported: Debian/Ubuntu with systemd >=247, unused TCP80/443, no existing web server.
set -Eeuo pipefail
umask 077
export LC_ALL=C
studio_domain= studio_ip=
while (($#)); do
 case "$1" in
  --domain) studio_domain=${2:?missing hostname}; shift 2;;
  --server-ip) studio_ip=${2:?missing IPv4}; shift 2;;
  --help) echo 'Usage: bash install-download-https.sh --domain HOST --server-ip IPV4'; exit 0;;
  *) echo 'Unknown argument' >&2; exit 2;;
 esac
done
fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || fail 'Linux root required'
test -d /run/systemd/system || fail 'Running systemd required'
source /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || fail 'Only Debian/Ubuntu are supported'
studio_version=$(systemctl --version | awk 'NR==1{print $2}')
[[ $studio_version =~ ^[0-9]+$ && $studio_version -ge 247 ]] || fail 'systemd >=247 required'
for studio_tool in python3 curl openssl ip ss flock iptables sha256sum apt-get dpkg-query; do command -v "$studio_tool" >/dev/null || fail "Missing tool: $studio_tool"; done
exec 9>/run/lock/studio-hy2-install.lock
flock -n 9 || fail 'Another Studio installation is running'
studio_root=/etc/studio-download-https
studio_unit=/etc/systemd/system/studio-download-https.service
studio_webroot=/var/lib/studio-hy2-downloads
studio_hook=/etc/studio-hy2/acme-deploy.sh
studio_expected_hook=bd562b601501b65b2f4f544a6b61233d7ac1cef9eda194ae4f55f81bc2ed3dca
for studio_path in "$studio_root" "$studio_unit" /run/systemd/system/nginx.service; do
 test ! -e "$studio_path" && test ! -L "$studio_path" || fail "Already present; inspect instead of overwriting: $studio_path"
done
for studio_web in nginx caddy; do
 ! command -v "$studio_web" >/dev/null || fail 'An existing web server needs manual integration'
 [[ $(systemctl show -p LoadState --value "$studio_web.service") == not-found ]] || fail 'Existing web-server unit needs review'
done
test ! -e /etc/nginx && test ! -e /etc/caddy || fail 'Existing web-server configuration needs review'
studio_installed_web=$(dpkg-query -W -f='${db:Status-Abbrev}\n' 'nginx*' 'caddy*' 2>/dev/null || true)
! grep -q '^ii ' <<< "$studio_installed_web" || fail 'Existing web-server packages need review'
test -z "$(ss -H -ltn 'sport = :80')" && test -z "$(ss -H -ltn 'sport = :443')" || fail 'TCP80/443 occupied; no service stopped'
if command -v ufw >/dev/null; then
 ! ufw status | grep -q '^Status: active$' || fail 'Active UFW requires a separately reviewed persistent TCP rule'
fi
iptables -w 5 -n -L INPUT >/dev/null
if command -v nft >/dev/null; then
 nft -j list ruleset | python3 -I -c 'import json,sys; x=json.load(sys.stdin); c=[e["chain"] for e in x.get("nftables",[]) if "chain" in e]; bad=[v for v in c if v.get("hook")=="input" and v.get("family") in ("ip","inet") and not(v.get("family")=="ip" and v.get("table")=="filter" and v.get("name")=="INPUT")]; assert not bad,"Custom input hooks need review"'
fi
systemctl is-active --quiet studio-hy2.service || fail 'HY2 must already be active'
python3 -I - "$studio_domain" "$studio_ip" "$studio_webroot" <<'PY'
import hashlib,ipaddress,json,pathlib,re,stat,subprocess,sys
host,ip,raw=sys.argv[1:]
assert len(host)<=253 and '.' in host and all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',s) for s in host.split('.'))
a=ipaddress.ip_address(ip);assert a.version==4 and a.is_global
assert ip in {a['local'] for i in json.loads(subprocess.check_output(['ip','-j','-4','addr','show'])) for a in i.get('addr_info',[])}
root=pathlib.Path(raw)
for p in [pathlib.Path('/etc/studio-hy2'),root,*root.parents]:
 assert not p.is_symlink() and p.is_dir() and p.stat().st_uid==0 and p.stat().st_mode&0o022==0
m=json.loads(pathlib.Path('/etc/studio-hy2/managed.json').read_text());assert m['format']==1 and m['domain']==host and m['server_ip']==ip
allowed={'index.html','file-integrity-guide.txt','project-notes-template.txt','SHA256SUMS'}
assert {p.name for p in root.iterdir()}==allowed
for p in root.iterdir():assert p.is_file() and not p.is_symlink() and p.stat().st_uid==0 and stat.S_IMODE(p.stat().st_mode)==0o644
assert stat.S_IMODE(root.stat().st_mode)==0o755
assert b'<h1>Download Center</h1>' in (root/'index.html').read_bytes()
assert hashlib.sha256(pathlib.Path('/etc/studio-hy2/acme-deploy.sh').read_bytes()).hexdigest()=='bd562b601501b65b2f4f544a6b61233d7ac1cef9eda194ae4f55f81bc2ed3dca'
cfg=json.loads(pathlib.Path('/etc/studio-hy2/server.json').read_text()); h=[x for x in cfg['inbounds'] if x['type']=='hysteria2'];assert len(h)==1 and h[0].get('masquerade')=={'type':'file','directory':raw}
PY
test ! -L "$studio_hook" && test "$(stat -c %u "$studio_hook")" = 0 || fail 'Unsafe existing hook'
openssl verify -purpose sslserver -verify_hostname "$studio_domain" -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted /etc/letsencrypt/live/studio-hy2/chain.pem /etc/letsencrypt/live/studio-hy2/cert.pem
openssl x509 -in /etc/letsencrypt/live/studio-hy2/cert.pem -checkend 86400 -noout
studio_policy=/usr/sbin/policy-rc.d
studio_policy_present=0 studio_policy_installed=0 studio_mask_installed=0 studio_finished=0 studio_package_attempted=0
studio_tmp=$(mktemp -d /var/tmp/studio-download-https.XXXXXXXX)
restore_package_guards(){
 local rc=0
 if [[ $studio_policy_installed == 1 ]]; then
  if test ! -L "$studio_policy" && test -f "$studio_policy" && [[ $(sha256sum "$studio_policy" | cut -d' ' -f1) == "$studio_policy_sha" ]]; then
   if [[ $studio_policy_present == 1 ]]; then cp -p "$studio_tmp/policy.original" "$studio_policy.restore" && mv -f "$studio_policy.restore" "$studio_policy" || rc=1
   else rm -f "$studio_policy" || rc=1; fi
   studio_policy_installed=0
  else echo 'Package policy changed concurrently; leaving it for review' >&2; rc=1; fi
 fi
 if [[ $studio_mask_installed == 1 ]]; then
  if test -L /run/systemd/system/nginx.service && [[ $(readlink /run/systemd/system/nginx.service) == /dev/null ]]; then
   rm /run/systemd/system/nginx.service && systemctl daemon-reload || rc=1
   studio_mask_installed=0
  else echo 'Runtime mask changed concurrently; leaving it for review' >&2; rc=1; fi
 fi
 return "$rc"
}
cleanup(){
 local rc=$?; trap - EXIT ERR
 if [[ $studio_package_attempted == 1 ]]; then systemctl disable nginx.service >/dev/null 2>&1 || true; fi
 restore_package_guards || rc=1
 if [[ $studio_finished != 1 && -x $studio_root/rollback.sh ]]; then "$studio_root/rollback.sh" || { echo 'Automatic rollback needs inspection' >&2; rc=1; }; fi
 if ((rc)); then echo "HTTPS addon stopped. Review $studio_root and $studio_tmp; HY2 credentials were not changed." >&2
 else rm -rf -- "$studio_tmp"; fi
 exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
if test -e "$studio_policy" || test -L "$studio_policy"; then
 test -f "$studio_policy" && test ! -L "$studio_policy" && test "$(stat -c %u "$studio_policy")" = 0 || fail 'Existing package policy is not a root-owned regular file'
 cp -p "$studio_policy" "$studio_tmp/policy.original"; studio_policy_present=1
fi
# Prevent both invoke-rc.d and direct systemctl activation of the newly installed stock nginx.
cat > "$studio_tmp/policy.guard" <<SH
#!/bin/sh
case \$1 in nginx|nginx.service) exit 101;; esac
if test -x '$studio_tmp/policy.original'; then exec '$studio_tmp/policy.original' "\$@"; fi
exit 0
SH
studio_policy_sha=$(sha256sum "$studio_tmp/policy.guard" | cut -d' ' -f1)
install -m 0755 "$studio_tmp/policy.guard" "$studio_policy.new"
mv "$studio_policy.new" "$studio_policy"; studio_policy_installed=1
ln -s /dev/null /run/systemd/system/nginx.service; studio_mask_installed=1
systemctl daemon-reload
studio_package_attempted=1
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends nginx
systemctl disable nginx.service
! systemctl is-active --quiet nginx.service || fail 'New stock nginx unexpectedly active'
test -z "$(ss -H -ltn 'sport = :80')" && test -z "$(ss -H -ltn 'sport = :443')" || fail 'Unexpected listener after package installation'
restore_package_guards
install -d -m 0700 "$studio_root"
cp -p "$studio_hook" "$studio_root/acme-deploy.original"
cat > "$studio_root/firewall.sh" <<SH
#!/bin/bash
set -euo pipefail
args=(-d '$studio_ip' -p tcp --dport 443 -m comment --comment studio-download-https-tcp443 -j ACCEPT)
case \${1:-} in
 open) if ! iptables -w 5 -C INPUT "\${args[@]}" 2>/dev/null; then iptables -w 5 -I INPUT 1 "\${args[@]}"; fi;;
 close) while :; do if iptables -w 5 -C INPUT "\${args[@]}" 2>/dev/null; then iptables -w 5 -D INPUT "\${args[@]}"; else rc=\$?; test "\$rc" -eq 1 || exit "\$rc"; break; fi; done;;
 *) exit 2;;
esac
SH
cat > "$studio_root/acme-deploy.combined" <<'SH'
#!/bin/sh
set -eu
/etc/studio-download-https/acme-deploy.original
if [ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/studio-hy2 ] && systemctl is-active --quiet studio-download-https.service; then
 # LoadCredential copies are refreshed on restart, not nginx HUP reload.
 systemctl try-restart studio-download-https.service
fi
SH
cat > "$studio_root/rollback.sh" <<'SH'
#!/bin/bash
set -euo pipefail
test "$(id -u)" = 0
root=/etc/studio-download-https
systemctl disable --now studio-download-https.service || true
"$root/firewall.sh" close
hook=/etc/studio-hy2/acme-deploy.sh
if cmp -s "$hook" "$root/acme-deploy.combined"; then
 cp -p "$root/acme-deploy.original" "$hook.restore"
 mv -f "$hook.restore" "$hook"
elif ! cmp -s "$hook" "$root/acme-deploy.original"; then
 echo 'Renewal hook changed after installation; preserving it for manual review' >&2; exit 1
fi
echo 'HTTPS companion stopped; its rule removed and original HY2 renewal hook restored. Shared page and disabled package retained.'
SH
chmod 0700 "$studio_root/"*.sh "$studio_root/acme-deploy.original" "$studio_root/acme-deploy.combined"
cat > "$studio_root/nginx.conf" <<CONF
daemon off;
worker_processes 1;
pid /run/studio-download-https/nginx.pid;
error_log stderr warn;
events { worker_connections 256; }
http {
 access_log off;
 server_tokens off;
 sendfile on;
 default_type application/octet-stream;
 types { text/html html; text/plain txt; }
 client_max_body_size 1k;
 client_header_timeout 10s;
 client_body_timeout 10s;
 keepalive_timeout 15s;
 send_timeout 30s;
 client_body_temp_path /run/studio-download-https/client;
 proxy_temp_path /run/studio-download-https/proxy;
 fastcgi_temp_path /run/studio-download-https/fastcgi;
 uwsgi_temp_path /run/studio-download-https/uwsgi;
 scgi_temp_path /run/studio-download-https/scgi;
 server {
  listen $studio_ip:443 ssl http2;
  server_name $studio_domain;
  ssl_certificate /run/credentials/studio-download-https.service/cert.pem;
  ssl_certificate_key /run/credentials/studio-download-https.service/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:TLS:1m;
  ssl_session_timeout 10m;
  ssl_session_tickets off;
  root $studio_webroot;
  disable_symlinks on;
  autoindex off;
  add_header Alt-Svc 'h3=":443"; ma=86400' always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy no-referrer always;
  location = / { default_type text/html; try_files /index.html =404; limit_except GET { deny all; } }
  location = /index.html { try_files \$uri =404; limit_except GET { deny all; } }
  location = /file-integrity-guide.txt { try_files \$uri =404; limit_except GET { deny all; } }
  location = /project-notes-template.txt { try_files \$uri =404; limit_except GET { deny all; } }
  location = /SHA256SUMS { default_type text/plain; try_files \$uri =404; limit_except GET { deny all; } }
  location / { return 404; }
 }
}
CONF
chmod 0600 "$studio_root/nginx.conf"
cat > "$studio_unit" <<'UNIT'
[Unit]
Description=Download center HTTPS
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
DynamicUser=yes
UMask=0077
RuntimeDirectory=studio-download-https
RuntimeDirectoryMode=0700
LoadCredential=nginx.conf:/etc/studio-download-https/nginx.conf
LoadCredential=cert.pem:/etc/letsencrypt/live/studio-hy2/fullchain.pem
LoadCredential=key.pem:/etc/letsencrypt/live/studio-hy2/privkey.pem
ExecStartPre=/usr/sbin/nginx -e stderr -t -q -p /run/studio-download-https/ -c %d/nginx.conf
ExecStartPre=+/etc/studio-download-https/firewall.sh open
ExecStart=/usr/sbin/nginx -e stderr -p /run/studio-download-https/ -c %d/nginx.conf
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -QUIT $MAINPID
ExecStopPost=+/etc/studio-download-https/firewall.sh close
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
KillMode=mixed
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
InaccessiblePaths=/etc/studio-hy2 /etc/letsencrypt
ReadOnlyPaths=/var/lib/studio-hy2-downloads
LimitNOFILE=1024
MemoryMax=64M
TasksMax=16
[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$studio_unit"
systemd-analyze verify "$studio_unit"
systemctl daemon-reload
systemctl enable --now studio-download-https.service
# Type=simple startup can precede the listener; bounded strict local HTTPS checks.
studio_ready=0
for ((studio_attempt=0;studio_attempt<25;studio_attempt++)); do
 if systemctl is-active --quiet studio-download-https.service && curl -q --noproxy '*' --resolve "$studio_domain:443:$studio_ip" -fsS --connect-timeout 1 --max-time 2 "https://$studio_domain/" -o "$studio_tmp/index.html" 2>/dev/null; then
  cmp "$studio_tmp/index.html" "$studio_webroot/index.html"; studio_ready=1; break
 fi
 sleep 0.2
done
[[ $studio_ready == 1 ]] || fail 'HTTPS did not start with a valid certificate and matching index'
curl -q --noproxy '*' --resolve "$studio_domain:443:$studio_ip" -fsS --connect-timeout 3 --max-time 10 "https://$studio_domain/SHA256SUMS" -o "$studio_tmp/SHA256SUMS"
cmp "$studio_tmp/SHA256SUMS" "$studio_webroot/SHA256SUMS"
studio_bad=$(curl -q --noproxy '*' --resolve "$studio_domain:443:$studio_ip" -sS --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' "https://$studio_domain/.env")
[[ $studio_bad == 404 ]] || fail 'Unexpected private-path response'
systemctl is-active --quiet studio-hy2.service
test -z "$(ss -H -ltn 'sport = :80')" || fail 'Unexpected TCP80 listener'
[[ $(sha256sum "$studio_hook" | cut -d' ' -f1) == "$studio_expected_hook" ]] || fail 'HY2 renewal hook changed during installation'
install -m 0700 "$studio_root/acme-deploy.combined" "$studio_hook.new"
mv -f "$studio_hook.new" "$studio_hook"
studio_finished=1
echo 'READY: Strict HTTPS on TCP443 serves the same files as HY2 HTTP/3. TCP80 remains free for renewal.'
echo 'Rollback: bash /etc/studio-download-https/rollback.sh'
