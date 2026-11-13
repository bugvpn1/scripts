#!/usr/bin/env bash
#
# setup-singbox.sh — install & configure a sing-box Shadowsocks server.
#
# Usage:
#   sudo ./setup-singbox.sh [--port PORT] [--method METHOD] [--allow CIDR[,CIDR...]]
#                           [--creds-file PATH] [--new-key] [--no-force-ipv4]
#                           [--no-tune] [--warp HOST:PORT | --no-warp]
#
# Examples:
#   sudo ./setup-singbox.sh
#   sudo ./setup-singbox.sh --port 8388 --allow 203.0.113.7/32
#   sudo ./setup-singbox.sh --method chacha20-ietf-poly1305   # old clients
#
# Notes:
#   * Shadowsocks 2022 by default: 2022-blake3-aes-128-gcm on CPUs with AES
#     instructions, 2022-blake3-chacha20-poly1305 otherwise (faster there).
#     The key is printed, saved to --creds-file (default
#     ./singbox-credentials.txt, mode 600, owned by the user who ran sudo) and
#     kept across re-runs; --new-key generates a fresh one.
#   * Shadowsocks 2022 rejects requests whose clock is >30 s off: keep NTP
#     running on both this server and the relay.
#   * --allow limits which client IPs may use the proxy. It is checked after
#     the Shadowsocks handshake, so also firewall TCP+UDP :PORT to those IPs.
#   * Multiplex is enabled server-side: a sing-box relay can carry many user
#     streams over a few connections. Clients without multiplex still work.
#   * Leaves Dante (setup-dante.sh) running so the relay can be switched over
#     without downtime; the script prints how to stop it afterwards.
#   * Forces IPv4 by default: hostname targets resolve to IPv4 first, so a
#     dead IPv6 route is never tried. Disable with --no-force-ipv4.
#   * Enables BBR congestion control (via /etc/sysctl.d/99-setup-singbox.conf;
#     settings the kernel refuses are skipped). Disable with --no-tune.
#   * Sends Google/Apple domains (WARP_DOMAINS below) to the Cloudflare WARP
#     SOCKS5 proxy at 127.0.0.1:40000 (warp-cli proxy mode); everything else
#     goes direct. Change with --warp HOST:PORT, turn off with --no-warp.

set -euo pipefail

PORT=8388
METHOD=""
ALLOW=""
FORCE_IPV4=1
TUNE=1
NEW_KEY=0
CONF=/etc/sing-box/config.json
CREDS_FILE="./singbox-credentials.txt"
TAG="setup-singbox-ss"   # inbound tag; marks a config as ours on re-runs
WARP="127.0.0.1:40000"   # WARP SOCKS5 proxy; empty = off
# Domains routed through WARP. A suffix also matches every subdomain.
WARP_DOMAINS=(
  google.com google.com.hk googleapis.com gstatic.com googleusercontent.com
  ggpht.com gvt1.com gvt2.com withgoogle.com
  apple.com icloud.com mzstatic.com apple-cloudkit.com
)

# ---- parse args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)   PORT="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --allow)  ALLOW="$2"; shift 2 ;;
    --creds-file) CREDS_FILE="$2"; shift 2 ;;
    --new-key) NEW_KEY=1; shift ;;
    --no-force-ipv4) FORCE_IPV4=0; shift ;;
    --no-tune) TUNE=0; shift ;;
    --warp)    WARP="$2"; shift 2 ;;
    --no-warp) WARP=""; shift ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- preflight --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script targets Debian/Ubuntu (apt). Adapt the install step otherwise." >&2
  exit 1
fi

if [[ -z "$METHOD" ]]; then
  if grep -qw aes /proc/cpuinfo; then
    METHOD="2022-blake3-aes-128-gcm"
  else
    METHOD="2022-blake3-chacha20-poly1305"
  fi
fi
case "$METHOD" in
  2022-blake3-aes-128-gcm) KEYLEN=16 ;;
  2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) KEYLEN=32 ;;
  aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) KEYLEN=0 ;;   # legacy: free-form password
  *) echo "Unsupported --method: $METHOD" >&2; exit 1 ;;
esac

# Refuse to fight another program for the port. Our own sing-box holding it (a
# re-run) is fine; ss can't always name the process (e.g. /proc hidepid), so
# also accept the port our existing config already listens on.
OURS=0
if grep -qF "\"tag\": \"${TAG}\"" "$CONF" 2>/dev/null && grep -qF "\"listen_port\": ${PORT}," "$CONF"; then
  OURS=1
fi
LISTENER=$(ss -Hltnp "sport = :${PORT}" 2>/dev/null || true)
if [[ -n "$LISTENER" ]] && [[ "$OURS" -eq 0 ]] && ! grep -q '"sing-box"' <<< "$LISTENER"; then
  echo "Port ${PORT} is already in use:" >&2
  echo "$LISTENER" >&2
  echo "Pick another with --port." >&2
  exit 1
fi

echo ">> Listening port:  $PORT (TCP+UDP)"
echo ">> Method:          $METHOD"
echo ">> Allowed clients: ${ALLOW:-any (key required)}"
echo ">> WARP outbound:   ${WARP:-off}"

WARP_HOST=""; WARP_PORT=""
if [[ -n "$WARP" ]]; then
  WARP_HOST="${WARP%:*}"; WARP_PORT="${WARP##*:}"
  if [[ -z "$WARP_HOST" || ! "$WARP_PORT" =~ ^[0-9]+$ ]]; then
    echo "--warp expects HOST:PORT, got: $WARP" >&2; exit 1
  fi
  # Not fatal: the config is still valid, but Google/Apple fail until WARP is up.
  if [[ "$WARP_HOST" == "127.0.0.1" ]] && [[ -z "$(ss -Hltn "sport = :${WARP_PORT}" 2>/dev/null)" ]]; then
    echo "!! Nothing listens on ${WARP}: Google/Apple traffic will fail until WARP is" >&2
    echo "   running (warp-cli mode proxy; warp-cli proxy port ${WARP_PORT}; warp-cli connect)." >&2
  fi
fi

# ---- install ----------------------------------------------------------------
echo ">> Installing sing-box from the official SagerNet apt repository..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates
mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get update -qq
# confold: on upgrade keep our config.json instead of stopping at dpkg's prompt.
apt-get install -y -qq -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold sing-box
echo ">> $(sing-box version | head -1)"

# ---- key --------------------------------------------------------------------
# gen_rand LEN CHARSET — read /dev/urandom in fixed chunks (no SIGPIPE under
# pipefail) until we have LEN characters from CHARSET.
gen_rand() {
  local len=$1 chars=$2 out=""
  while (( ${#out} < len )); do
    out+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc "$chars")
  done
  printf '%s' "${out:0:len}"
}

# Reuse the key from a config this script wrote (never the package's sample
# config, whose key is public), as long as the method is unchanged.
PASSWORD=""
if [[ "$NEW_KEY" -eq 0 ]] && grep -qF "\"tag\": \"${TAG}\"" "$CONF" 2>/dev/null; then
  OLD_METHOD=$(sed -n 's/^ *"method": "\(.*\)",$/\1/p' "$CONF" | head -1)
  if [[ "$OLD_METHOD" == "$METHOD" ]]; then
    PASSWORD=$(sed -n 's/^ *"password": "\(.*\)",$/\1/p' "$CONF" | head -1)
    [[ -n "$PASSWORD" ]] && echo ">> Keeping existing key (use --new-key to rotate)"
  fi
fi
if [[ -z "$PASSWORD" ]]; then
  if [[ "$KEYLEN" -gt 0 ]]; then
    PASSWORD=$(head -c "$KEYLEN" /dev/urandom | base64 -w0)
  else
    PASSWORD=$(gen_rand 24 'A-Za-z0-9')
  fi
  echo ">> Generated new key"
fi

# ---- write config -----------------------------------------------------------
# Optional route pieces. 127.0.0.0/8 stays allowed for the self-test below.
# Rules run top to bottom; the first match wins.
RULES=()
if [[ -n "$ALLOW" ]]; then
  CIDR_LIST='"127.0.0.0/8"'
  IFS=',' read -ra CIDRS <<< "$ALLOW"
  for cidr in "${CIDRS[@]}"; do
    cidr="$(echo "$cidr" | xargs)"   # trim whitespace
    [[ -z "$cidr" ]] && continue
    CIDR_LIST+=", \"${cidr}\""
  done
  RULES+=("{ \"source_ip_cidr\": [${CIDR_LIST}], \"invert\": true, \"action\": \"reject\" }")
fi
WARP_OUTBOUND=""
if [[ -n "$WARP" ]]; then
  DOMAIN_LIST=$(printf '"%s", ' "${WARP_DOMAINS[@]}"); DOMAIN_LIST="${DOMAIN_LIST%, }"
  # Sniff first: a client that resolved the name itself sends only an IP, and
  # the domain rule below needs the name (TLS SNI / HTTP Host / QUIC).
  RULES+=("{ \"action\": \"sniff\" }")
  # WARP's local proxy is not relied on for UDP: refuse QUIC to these domains
  # so browsers and apps fall back to TCP right away.
  RULES+=("{ \"domain_suffix\": [${DOMAIN_LIST}], \"network\": \"udp\", \"port\": 443, \"action\": \"reject\" }")
  RULES+=("{ \"domain_suffix\": [${DOMAIN_LIST}], \"outbound\": \"warp\" }")
  WARP_OUTBOUND=",
    { \"type\": \"socks\", \"tag\": \"warp\", \"server\": \"${WARP_HOST}\", \"server_port\": ${WARP_PORT}, \"version\": \"5\" }"
fi
ROUTE_RULES=""
if [[ ${#RULES[@]} -gt 0 ]]; then
  ROUTE_RULES="
    \"rules\": ["
  for i in "${!RULES[@]}"; do
    sep=","; [[ $i -eq $(( ${#RULES[@]} - 1 )) ]] && sep=""
    ROUTE_RULES+="
      ${RULES[$i]}${sep}"
  done
  ROUTE_RULES+="
    ],"
fi
RESOLVER=""
if [[ "$FORCE_IPV4" -eq 1 ]]; then
  RESOLVER=",
    \"default_domain_resolver\": { \"server\": \"local\", \"strategy\": \"prefer_ipv4\" }"
fi

if [[ -f "$CONF" ]] && [[ ! -f "${CONF}.orig" ]]; then
  cp "$CONF" "${CONF}.orig"
  echo ">> Backed up original config to ${CONF}.orig"
fi

# sing-box is started with -C /etc/sing-box and merges EVERY .json file there.
for f in "$(dirname "$CONF")"/*.json; do
  [[ -e "$f" && "$f" != "$CONF" ]] && echo "!! $f will be merged into the config too; remove it if unintended." >&2
done

echo ">> Writing $CONF"
# log level warn: "info" writes a line for every proxied connection.
( umask 077
  cat > "$CONF" <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [ { "type": "local", "tag": "local" } ]
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "${TAG}",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "method": "${METHOD}",
      "password": "${PASSWORD}",
      "multiplex": { "enabled": true }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }${WARP_OUTBOUND}
  ],
  "route": {${ROUTE_RULES}
    "final": "direct"${RESOLVER}
  }
}
EOF
)
# The packaged service runs as user "sing-box"; it must read the key, nobody else.
if getent group sing-box >/dev/null; then
  chown root:sing-box "$CONF"
  chmod 640 "$CONF"
else
  chmod 644 "$CONF"
  echo "!! No sing-box group found; $CONF left world-readable so the service can read it." >&2
fi

if ! sing-box check -c "$CONF"; then
  echo "!! sing-box rejected $CONF (see above). Service not restarted." >&2
  exit 1
fi

# ---- memory limit -----------------------------------------------------------
# Go only collects garbage once the heap doubles; GOMEMLIMIT makes it collect
# harder as the process nears half of RAM, which matters on 512 MB boxes.
MEM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/10-setup-singbox.conf" <<EOF
# Managed by setup-singbox.sh — rewritten on every run.
[Service]
Environment=GOMEMLIMIT=$(( MEM_MB / 2 ))MiB
EOF
echo ">> GOMEMLIMIT set to $(( MEM_MB / 2 ))MiB (half of ${MEM_MB} MiB RAM)"

# ---- kernel tuning ----------------------------------------------------------
# BBR keeps throughput up on long or lossy paths. (Keepalive is not tuned here:
# sing-box sets its own per-socket keepalive, 5 min + 75 s probes.) Each
# setting is applied live first and only persisted if the kernel accepted it,
# so boot never trips over unsupported keys.
if [[ "$TUNE" -eq 1 ]]; then
  SYSCTL_FILE=/etc/sysctl.d/99-setup-singbox.conf
  modprobe tcp_bbr 2>/dev/null || true
  TUNED=""
  for kv in net.core.default_qdisc=fq \
            net.ipv4.tcp_congestion_control=bbr; do
    if sysctl -qw "$kv" 2>/dev/null; then
      TUNED+="${kv%%=*} = ${kv#*=}"$'\n'
    else
      echo "!! Kernel refused ${kv}; skipping it." >&2
    fi
  done
  printf '# Managed by setup-singbox.sh — rewritten on every run.\n%s' "$TUNED" > "$SYSCTL_FILE"
  echo ">> Kernel tuning written to $SYSCTL_FILE"
fi

# ---- start ------------------------------------------------------------------
echo ">> Enabling and (re)starting sing-box..."
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

sleep 1
if systemctl is-active --quiet sing-box; then
  echo ">> sing-box is running."
else
  echo "!! sing-box failed to start. Recent logs:" >&2
  journalctl -u sing-box -n 30 --no-pager >&2 || true
  exit 1
fi

# ---- verify -----------------------------------------------------------------
# Run a throwaway sing-box client (SOCKS in, Shadowsocks out to this server)
# and fetch a page through it: proves the key, the method and egress all work.
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
echo ">> Self-test through the server (hostname target, resolved by sing-box)..."
TEST_DIR=$(mktemp -d)
TEST_PORT=$(( 20000 + RANDOM % 20000 ))
cat > "$TEST_DIR/client.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": ${TEST_PORT} } ],
  "outbounds": [
    { "type": "shadowsocks", "server": "127.0.0.1", "server_port": ${PORT},
      "method": "${METHOD}", "password": "${PASSWORD}" }
  ]
}
EOF
sing-box run -c "$TEST_DIR/client.json" >"$TEST_DIR/client.log" 2>&1 &
TEST_PID=$!
if OUT=$(curl -s --max-time 10 --retry 5 --retry-connrefused --retry-delay 1 \
           --socks5-hostname "127.0.0.1:${TEST_PORT}" https://ifconfig.me 2>/dev/null); then
  echo ">> Proxy egress IP: ${OUT}"
  [[ -n "$OUT" ]] && SERVER_IP="$OUT"
else
  echo "!! Self-test failed. Server log: journalctl -u sing-box -n 30" >&2
  sed 's/^/   client: /' "$TEST_DIR/client.log" >&2 || true
fi
if [[ -n "$WARP" ]]; then
  # Through the server, Google should go out via WARP and not bounce to .hk.
  G_URL=$(curl -sL --max-time 15 -o /dev/null -w '%{url_effective}' \
            --socks5-hostname "127.0.0.1:${TEST_PORT}" https://www.google.com 2>/dev/null || true)
  if [[ "$G_URL" == https://www.google.com/* ]]; then
    echo ">> Google via WARP: ${G_URL} (OK)"
  else
    echo "!! Google via WARP: ${G_URL:-request failed}. Check: warp-cli status" >&2
  fi
fi
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true
rm -rf "$TEST_DIR"

if [[ "$KEYLEN" -gt 0 ]] && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
  echo "!! Clock is not NTP-synchronized. Shadowsocks 2022 fails if this server's" >&2
  echo "   or the relay's clock drifts >30 s: apt-get install systemd-timesyncd." >&2
fi

SERVER_IP="${SERVER_IP:-<server-ip>}"

# ---- save & show credentials -----------------------------------------------
# SIP002 URI: 2022 keys are percent-encoded, legacy userinfo is base64url.
if [[ "$KEYLEN" -gt 0 ]]; then
  USERINFO="${METHOD}:$(printf '%s' "$PASSWORD" | sed 's/+/%2B/g; s#/#%2F#g; s/=/%3D/g')"
else
  USERINFO=$(printf '%s' "${METHOD}:${PASSWORD}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
fi
SS_URI="ss://${USERINFO}@${SERVER_IP}:${PORT}"

( umask 077
  cat > "$CREDS_FILE" <<EOF
# sing-box Shadowsocks credentials — generated by setup-singbox.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=${SERVER_IP}
PORT=${PORT}
METHOD=${METHOD}
PASSWORD=${PASSWORD}
URI=${SS_URI}
EOF
)
chmod 600 "$CREDS_FILE"
# Under sudo, hand the file back to the invoking user so they can read it.
if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER": "$CREDS_FILE"
fi

cat <<EOF

Done. Shadowsocks server listening on port ${PORT} (TCP+UDP).

  Host:     ${SERVER_IP}
  Port:     ${PORT}
  Method:   ${METHOD}
  Password: ${PASSWORD}
  URI:      ${SS_URI}

Credentials saved to ${CREDS_FILE} (mode 600).

Relay outbound (sing-box). Add "multiplex" to carry many users' streams
over a few connections:
  {
    "type": "shadowsocks",
    "tag": "exit",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "method": "${METHOD}",
    "password": "${PASSWORD}",
    "multiplex": { "enabled": true, "protocol": "h2mux", "max_connections": 8, "min_streams": 4 }
  }
EOF

if systemctl is-active --quiet danted 2>/dev/null; then
  cat <<EOF

Dante is still running. Once the relay uses this server, stop it with:
  sudo systemctl disable --now danted
EOF
fi