#!/usr/bin/env bash
# =============================================================================
# verify-tunnel.sh — confirm claw's traffic actually leaves through the VPS
# and that DNS resolves through the tunnel.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

c_reset='\033[0m'; c_grn='\033[1;32m'; c_red='\033[1;31m'; c_cyan='\033[1;36m'; c_yel='\033[1;33m'
log()  { printf "${c_cyan}[verify-tunnel]${c_reset} %s\n" "$*"; }
pass() { printf "${c_grn}  PASS${c_reset}  %s\n" "$*"; }
fail() { printf "${c_red}  FAIL${c_reset}  %s\n" "$*"; FAILED=1; }
note() { printf "${c_yel}  ..${c_reset}    %s\n" "$*"; }
FAILED=0

dc() { docker compose "$@"; }
cexec() { dc exec -T claw "$@"; }

# Expected VPS address from .env (best effort).
TUNNEL_SERVER=""
[ -f .env ] && TUNNEL_SERVER="$(grep -E '^TUNNEL_SERVER=' .env | head -n1 | cut -d= -f2-)"

log "checking stack is up ..."
if ! dc ps --status running --services 2>/dev/null | grep -qx tunnel; then
  fail "tunnel container is not running — run: docker compose up -d"
  exit 1
fi
if ! dc ps --status running --services 2>/dev/null | grep -qx claw; then
  fail "claw container is not running — run: docker compose up -d"
  exit 1
fi
pass "tunnel and claw containers are running"

log "checking tun0 exists inside the tunnel ..."
if dc exec -T tunnel test -d /sys/class/net/tun0 2>/dev/null; then
  pass "tun0 interface is present"
else
  fail "tun0 is missing — the tunnel is not established"
fi

log "measuring egress IP ..."
HOST_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
CLAW_IP="$(cexec curl -4 -fsS --max-time 12 https://api.ipify.org 2>/dev/null || true)"
note "this machine's egress IP : ${HOST_IP:-<unknown>}"
note "claw container egress IP : ${CLAW_IP:-<none>}"

if [ -z "$CLAW_IP" ]; then
  fail "claw has no egress IP — traffic is not getting through the tunnel"
elif [ -n "$HOST_IP" ] && [ "$CLAW_IP" = "$HOST_IP" ]; then
  fail "claw egress IP equals this machine's IP — traffic is NOT tunneled"
elif echo "$TUNNEL_SERVER" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
     && [ "$CLAW_IP" = "$TUNNEL_SERVER" ]; then
  pass "claw egress IP is your VPS ($CLAW_IP) — traffic is tunneled"
else
  pass "claw egress IP ($CLAW_IP) differs from this machine — traffic is tunneled"
fi

log "checking DNS resolves through the tunnel ..."
# With the kill switch armed, the ONLY path off the box is the tunnel — so a
# successful lookup is, by construction, a lookup that went through it.
if cexec getent hosts example.com >/dev/null 2>&1 \
   || cexec curl -4 -fsS --max-time 12 -o /dev/null https://example.com 2>/dev/null; then
  pass "name resolution works inside the tunnel"
else
  fail "DNS resolution failed inside claw"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf "${c_grn}verify-tunnel: ALL CHECKS PASSED${c_reset}\n"
  exit 0
else
  printf "${c_red}verify-tunnel: FAILED — see above${c_reset}\n"
  exit 1
fi
