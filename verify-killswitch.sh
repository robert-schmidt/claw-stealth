#!/usr/bin/env bash
# =============================================================================
# verify-killswitch.sh — prove that when the tunnel is down, claw has ZERO
# connectivity (so API calls fail closed instead of leaking onto open wifi).
#
# Stops the tunnel, checks claw cannot reach the internet by any route — DNS
# name *or* raw IP — then restarts the tunnel and confirms recovery.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

c_reset='\033[0m'; c_grn='\033[1;32m'; c_red='\033[1;31m'; c_cyan='\033[1;36m'; c_yel='\033[1;33m'
log()  { printf "${c_cyan}[verify-killswitch]${c_reset} %s\n" "$*"; }
pass() { printf "${c_grn}  PASS${c_reset}  %s\n" "$*"; }
fail() { printf "${c_red}  FAIL${c_reset}  %s\n" "$*"; FAILED=1; }
note() { printf "${c_yel}  ..${c_reset}    %s\n" "$*"; }
FAILED=0

dc() { docker compose "$@"; }
# Connectivity probe inside claw. Returns 0 if claw reached the internet.
claw_online() {
  dc exec -T claw curl -4 -fsS --max-time 8 -o /dev/null "$1" 2>/dev/null
}

restore() {
  log "restoring tunnel ..."
  dc up -d >/dev/null 2>&1 || dc start tunnel >/dev/null 2>&1 || true
}
trap restore EXIT

# --- baseline ---------------------------------------------------------------
log "baseline: confirming claw is online with the tunnel up ..."
if ! dc ps --status running --services 2>/dev/null | grep -qx tunnel; then
  fail "tunnel is not running — start the stack first: docker compose up -d"
  exit 1
fi
if claw_online https://api.ipify.org; then
  pass "claw can reach the internet while the tunnel is up"
else
  fail "claw is offline even before the test — fix the tunnel first"
  exit 1
fi

# --- kill the tunnel --------------------------------------------------------
log "stopping the tunnel ..."
dc stop tunnel >/dev/null 2>&1
sleep 3

log "probing claw with the tunnel DOWN (expecting total failure) ..."

# Probe 1: a normal HTTPS request by hostname.
if claw_online https://api.ipify.org; then
  fail "claw reached the internet by hostname — KILL SWITCH LEAK"
else
  pass "HTTPS-by-hostname blocked"
fi

# Probe 2: raw IP, bypassing DNS entirely — catches any non-DNS leak.
if claw_online https://1.1.1.1; then
  fail "claw reached a raw IP — KILL SWITCH LEAK"
else
  pass "HTTPS-to-raw-IP blocked"
fi

# Probe 3: plain DNS lookup must not resolve either.
if dc exec -T claw getent hosts example.com >/dev/null 2>&1; then
  fail "DNS still resolves with the tunnel down — KILL SWITCH LEAK"
else
  pass "DNS resolution blocked"
fi

# --- restore + confirm ------------------------------------------------------
restore
trap - EXIT
log "waiting for the tunnel to come back ..."
ok=0
for _ in $(seq 1 20); do
  if claw_online https://api.ipify.org; then ok=1; break; fi
  sleep 3
done
if [ "$ok" -eq 1 ]; then
  pass "connectivity restored after the tunnel came back up"
else
  fail "claw did not recover — check: docker compose logs tunnel"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf "${c_grn}verify-killswitch: ALL CHECKS PASSED — traffic fails closed${c_reset}\n"
  exit 0
else
  printf "${c_red}verify-killswitch: FAILED — see above${c_reset}\n"
  exit 1
fi
