#!/usr/bin/env bash
# =============================================================================
# claw-stealth — server setup
#
# Run as root on a fresh Ubuntu 22.04+ VPS. Installs Docker, generates a
# Reality keypair / UUID / shortID, writes the sing-box server config, starts
# it, and prints the exact client config (+ QR) to use on your laptop.
#
# Idempotent: secrets are generated once and cached in
# /etc/claw-stealth/credentials.env; re-running reuses them. Use --regenerate
# to roll new secrets.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/sing-box.server.json.tmpl"

STATE_DIR="/etc/claw-stealth"
CRED_FILE="$STATE_DIR/credentials.env"
CONFIG_FILE="$STATE_DIR/sing-box.server.json"
COMPOSE_FILE="$STATE_DIR/docker-compose.yml"
CLIENT_FILE="$STATE_DIR/sing-box.client.json"
DATA_DIR="$STATE_DIR/data"

SINGBOX_IMAGE="${SINGBOX_IMAGE:-ghcr.io/sagernet/sing-box:v1.13.12}"

# --- defaults / CLI ----------------------------------------------------------
MODE=""
TUNNEL_PORT=443
REALITY_TARGET="www.microsoft.com"
WS_DOMAIN=""
ACME_EMAIL=""
CF_API_TOKEN=""
WS_PATH=""
SERVER_ADDR=""
REGENERATE=false
ASSUME_YES=false

c_reset='\033[0m'; c_cyan='\033[1;36m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_grn='\033[1;32m'
log()  { printf "${c_cyan}[claw-stealth]${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}[claw-stealth]${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}[claw-stealth] WARN:${c_reset} %s\n" "$*" >&2; }
die()  { printf "${c_red}[claw-stealth] ERROR:${c_reset} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
claw-stealth server setup

Usage: sudo ./setup-server.sh [options]

Options:
  --mode <reality|ws>     Tunnel mode (default: prompt; reality recommended)
  --port <n>              Listen port (default: 443)
  --reality-target <host> Reality handshake/SNI target (default: www.microsoft.com)
  --server-addr <ip|host> Address clients dial (default: auto-detect public IP)
  --domain <host>         [ws] Cloudflare-proxied hostname, e.g. cdn-edge.example.com
  --email <addr>          [ws] email for Let's Encrypt
  --cf-token <token>      [ws] Cloudflare API token (Zone:DNS:Edit) for ACME DNS-01
  --ws-path <path>        [ws] WebSocket path (default: random)
  --regenerate            Roll fresh UUID / keypair / shortID
  --image <ref>           sing-box image (default: ghcr.io/sagernet/sing-box:v1.13.12)
  -y, --yes               Non-interactive; use defaults
  -h, --help              This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)           MODE="${2:-}"; shift 2;;
    --port)           TUNNEL_PORT="${2:-}"; shift 2;;
    --reality-target) REALITY_TARGET="${2:-}"; shift 2;;
    --server-addr)    SERVER_ADDR="${2:-}"; shift 2;;
    --domain)         WS_DOMAIN="${2:-}"; shift 2;;
    --email)          ACME_EMAIL="${2:-}"; shift 2;;
    --cf-token)       CF_API_TOKEN="${2:-}"; shift 2;;
    --ws-path)        WS_PATH="${2:-}"; shift 2;;
    --regenerate)     REGENERATE=true; shift;;
    --image)          SINGBOX_IMAGE="${2:-}"; shift 2;;
    -y|--yes)         ASSUME_YES=true; shift;;
    -h|--help)        usage; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)"
[ -f "$TEMPLATE" ]   || die "missing template: $TEMPLATE"

# --- 1. Docker ---------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker present: $(docker --version)"
  else
    log "Installing Docker (get.docker.com) ..."
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker daemon is not running"
}

# --- 2. Mode + inputs --------------------------------------------------------
choose_mode() {
  [ -n "$MODE" ] && return 0
  if $ASSUME_YES; then MODE="reality"; return 0; fi
  echo
  echo "  Select tunnel mode:"
  echo "    1) Reality (direct)        — recommended; generic A-record to this VPS"
  echo "    2) VLESS + WebSocket + TLS — orange-cloud proxied behind Cloudflare"
  echo
  read -rp "  Choice [1]: " choice
  case "${choice:-1}" in
    1) MODE="reality";;
    2) MODE="ws";;
    *) die "invalid choice";;
  esac
}

prompt() { # prompt VAR "text" "default"
  local __var="$1" __txt="$2" __def="${3:-}" __in=""
  eval "[ -n \"\${$__var:-}\" ] && return 0"
  if $ASSUME_YES; then eval "$__var=\"\$__def\""; return 0; fi
  if [ -n "$__def" ]; then read -rp "  $__txt [$__def]: " __in; else read -rp "  $__txt: " __in; fi
  eval "$__var=\"\${__in:-\$__def}\""
}

detect_public_ip() {
  local ip url
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then echo "$ip"; return 0; fi
  done
  return 1
}

# --- 3. Secrets (idempotent) -------------------------------------------------
gen() { docker run --rm "$SINGBOX_IMAGE" "$@"; }

load_creds() {
  if [ -f "$CRED_FILE" ] && ! $REGENERATE; then
    log "Reusing cached credentials ($CRED_FILE) — pass --regenerate to roll new ones"
    # shellcheck disable=SC1090
    . "$CRED_FILE"
  elif $REGENERATE; then
    log "Regenerating all secrets"
    rm -f "$CRED_FILE"
  fi
}

generate_secrets() {
  log "Pulling sing-box image ($SINGBOX_IMAGE) ..."
  docker pull -q "$SINGBOX_IMAGE" >/dev/null

  : "${UUID:=$(gen generate uuid)}"

  if [ "$MODE" = "reality" ]; then
    if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
      local kp; kp="$(gen generate reality-keypair)"
      REALITY_PRIVATE_KEY="$(echo "$kp" | awk '/PrivateKey/{print $2}')"
      REALITY_PUBLIC_KEY="$(echo  "$kp" | awk '/PublicKey/{print $2}')"
    fi
    : "${REALITY_SHORT_ID:=$(gen generate rand 8 --hex)}"
  else
    : "${WS_PATH:=/$(gen generate rand 8 --hex)}"
  fi
}

save_creds() {
  mkdir -p "$STATE_DIR"
  umask 077
  cat > "$CRED_FILE" <<EOF
# claw-stealth server credentials — generated $(date -u +%FT%TZ)
# KEEP SECRET. Re-run setup-server.sh to reuse; --regenerate to roll.
MODE=$MODE
TUNNEL_PORT=$TUNNEL_PORT
SERVER_ADDR=$SERVER_ADDR
UUID=$UUID
EOF
  if [ "$MODE" = "reality" ]; then
    cat >> "$CRED_FILE" <<EOF
REALITY_TARGET=$REALITY_TARGET
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
EOF
  else
    cat >> "$CRED_FILE" <<EOF
WS_DOMAIN=$WS_DOMAIN
WS_PATH=$WS_PATH
ACME_EMAIL=$ACME_EMAIL
CF_API_TOKEN=$CF_API_TOKEN
EOF
  fi
  chmod 600 "$CRED_FILE"
}

# --- 4. Server config --------------------------------------------------------
write_server_config() {
  mkdir -p "$STATE_DIR" "$DATA_DIR"
  if [ "$MODE" = "reality" ]; then
    sed -e "s|__TUNNEL_PORT__|$TUNNEL_PORT|g" \
        -e "s|__UUID__|$UUID|g" \
        -e "s|__REALITY_HANDSHAKE_SERVER__|$REALITY_TARGET|g" \
        -e "s|__REALITY_PRIVATE_KEY__|$REALITY_PRIVATE_KEY|g" \
        -e "s|__REALITY_SHORT_ID__|$REALITY_SHORT_ID|g" \
        "$TEMPLATE" > "$CONFIG_FILE"
  else
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $TUNNEL_PORT,
      "users": [
        { "name": "claw-stealth", "uuid": "$UUID" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$WS_DOMAIN",
        "acme": {
          "domain": ["$WS_DOMAIN"],
          "data_directory": "/var/lib/sing-box/acme",
          "email": "$ACME_EMAIL",
          "provider": "letsencrypt",
          "dns01_challenge": {
            "provider": "cloudflare",
            "api_token": "$CF_API_TOKEN"
          }
        }
      },
      "transport": {
        "type": "ws",
        "path": "$WS_PATH"
      },
      "multiplex": { "enabled": true, "padding": true }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  fi
  chmod 600 "$CONFIG_FILE"

  log "Validating server config ..."
  docker run --rm -v "$CONFIG_FILE":/c.json:ro "$SINGBOX_IMAGE" check -c /c.json \
    || die "generated server config failed validation"
  ok "Server config valid: $CONFIG_FILE"
}

write_compose() {
  cat > "$COMPOSE_FILE" <<EOF
name: claw-stealth-server
services:
  sing-box:
    image: $SINGBOX_IMAGE
    container_name: claw-stealth-server
    restart: unless-stopped
    network_mode: host
    volumes:
      - $CONFIG_FILE:/etc/sing-box/config.json:ro
      - $DATA_DIR:/var/lib/sing-box
    command: ["-D", "/var/lib/sing-box", "-c", "/etc/sing-box/config.json", "run"]
EOF
}

start_server() {
  log "Starting sing-box server ..."
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate
  sleep 2
  if [ "$(docker inspect -f '{{.State.Running}}' claw-stealth-server 2>/dev/null || echo false)" != "true" ]; then
    docker compose -f "$COMPOSE_FILE" logs --tail 30 || true
    die "sing-box server did not stay running — see logs above"
  fi
  ok "sing-box server is running"
}

# --- 5. Client config + summary ---------------------------------------------
write_client_config() {
  if [ "$MODE" = "reality" ]; then
    cat > "$CLIENT_FILE" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-remote", "server": "1.1.1.1", "server_port": 443, "path": "/dns-query", "detour": "vless-out" },
      { "type": "local", "tag": "dns-local" }
    ],
    "final": "doh-remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "__TUNNEL_SERVER__",
      "server_port": $TUNNEL_PORT,
      "uuid": "$UUID",
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_TARGET",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC_KEY",
          "short_id": "$REALITY_SHORT_ID"
        }
      },
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 4,
        "min_streams": 4,
        "padding": true
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local",
    "final": "vless-out",
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ]
  }
}
EOF
  else
    cat > "$CLIENT_FILE" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-remote", "server": "1.1.1.1", "server_port": 443, "path": "/dns-query", "detour": "vless-out" },
      { "type": "local", "tag": "dns-local" }
    ],
    "final": "doh-remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "__TUNNEL_SERVER__",
      "server_port": $TUNNEL_PORT,
      "uuid": "$UUID",
      "tls": {
        "enabled": true,
        "server_name": "$WS_DOMAIN",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": { "Host": "$WS_DOMAIN" }
      },
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 4,
        "min_streams": 4,
        "padding": true
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local",
    "final": "vless-out",
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ]
  }
}
EOF
  fi
  chmod 600 "$CLIENT_FILE"
}

share_link() {
  if [ "$MODE" = "reality" ]; then
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&headerType=none&fp=chrome&sni=%s&pbk=%s&sid=%s#claw-stealth' \
      "$UUID" "$SERVER_ADDR" "$TUNNEL_PORT" "$REALITY_TARGET" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
  else
    printf 'vless://%s@%s:%s?encryption=none&security=tls&type=ws&host=%s&path=%s&sni=%s&fp=chrome#claw-stealth' \
      "$UUID" "$SERVER_ADDR" "$TUNNEL_PORT" "$WS_DOMAIN" "$WS_PATH" "$WS_DOMAIN"
  fi
}

print_qr() {
  local link="$1"
  if ! command -v qrencode >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$link"
  else
    warn "qrencode unavailable — skipping QR (share link printed above)"
  fi
}

print_summary() {
  local link; link="$(share_link)"
  echo
  printf "${c_grn}=============================================================${c_reset}\n"
  printf "${c_grn}  claw-stealth server is up — mode: %s${c_reset}\n" "$MODE"
  printf "${c_grn}=============================================================${c_reset}\n"
  echo
  echo "1) On your laptop, copy this into  claw-stealth/client/sing-box.client.json :"
  echo "-------------------------------------------------------------"
  cat "$CLIENT_FILE"
  echo "-------------------------------------------------------------"
  echo
  echo "2) In  claw-stealth/.env  set:"
  echo "       TUNNEL_SERVER=$SERVER_ADDR"
  echo "       TUNNEL_PORT=$TUNNEL_PORT"
  echo
  echo "   (server config + client config are also saved on this VPS under"
  echo "    $STATE_DIR/ — scp $CLIENT_FILE to your laptop if you prefer.)"
  echo
  echo "3) VLESS share link (import into a mobile sing-box client):"
  echo "   $link"
  echo
  print_qr "$link"
  echo
  if [ "$MODE" = "reality" ]; then
    echo "DNS: point a generic subdomain (e.g. cdn-edge.<domain>) at $SERVER_ADDR"
    echo "     in Cloudflare with the proxy OFF (grey cloud, DNS-only)."
  else
    echo "Cloudflare: A-record '$WS_DOMAIN' -> this VPS, proxy ON (orange cloud);"
    echo "            set SSL/TLS mode to 'Full (strict)'."
  fi
  echo
  ok "Done. Then on your laptop:  docker compose up -d --build"
}

# --- main --------------------------------------------------------------------
install_docker
load_creds
choose_mode

if [ "$MODE" = "ws" ]; then
  prompt WS_DOMAIN  "Cloudflare-proxied hostname (e.g. cdn-edge.example.com)"
  prompt ACME_EMAIL "Email for Let's Encrypt"
  prompt CF_API_TOKEN "Cloudflare API token (Zone:DNS:Edit)"
  [ -n "$WS_DOMAIN" ]   || die "--domain is required for ws mode"
  [ -n "$ACME_EMAIL" ]  || die "--email is required for ws mode"
  [ -n "$CF_API_TOKEN" ]|| die "--cf-token is required for ws mode"
else
  prompt REALITY_TARGET "Reality handshake target (impersonated site)" "www.microsoft.com"
fi

if [ -z "$SERVER_ADDR" ]; then
  if [ "$MODE" = "ws" ]; then
    SERVER_ADDR="$WS_DOMAIN"
  else
    SERVER_ADDR="$(detect_public_ip || true)"
    [ -n "$SERVER_ADDR" ] || { SERVER_ADDR="YOUR_VPS_IP"; warn "could not auto-detect public IP — edit TUNNEL_SERVER manually"; }
  fi
fi

generate_secrets
save_creds
write_server_config
write_compose
start_server
write_client_config
print_summary
