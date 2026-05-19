#!/usr/bin/env bash
# =============================================================================
# claw-stealth tunnel container entrypoint.
#
# Responsibilities, in order:
#   1. Resolve the tunnel endpoint ONCE, before any firewall is armed, so the
#      only DNS that ever touches the local network is this single bootstrap
#      lookup (and in Reality mode, where the endpoint is an IP, not even that).
#   2. Render the runtime sing-box config (pin server IP, gate multiplex).
#   3. Arm the kill switch: nothing may leave except via tun0 or to the
#      endpoint itself. If the tunnel drops, traffic fails closed.
#   4. Supervise sing-box: jittered auto-reconnect + optional cron time window.
#
# Every feature is flag-gated via environment variables (see .env.example).
# =============================================================================
set -u

# --- Configuration (env with defaults) --------------------------------------
TUNNEL_SERVER="${TUNNEL_SERVER:-}"
TUNNEL_PORT="${TUNNEL_PORT:-443}"
KILL_SWITCH="${KILL_SWITCH:-true}"
AUTO_RECONNECT="${AUTO_RECONNECT:-true}"
RECONNECT_MIN_MINUTES="${RECONNECT_MIN_MINUTES:-45}"
RECONNECT_MAX_MINUTES="${RECONNECT_MAX_MINUTES:-90}"
MUX_ENABLED="${MUX_ENABLED:-true}"
TIME_WINDOW_ENABLED="${TIME_WINDOW_ENABLED:-false}"
TIME_WINDOW_START="${TIME_WINDOW_START:-09:00}"
TIME_WINDOW_END="${TIME_WINDOW_END:-23:00}"

CLIENT_CONFIG="/etc/sing-box/config.json"
RUN_DIR="/run/claw-stealth"
RUNTIME_CONFIG="${RUN_DIR}/sing-box.json"
WINDOW_FLAG="${RUN_DIR}/window.open"

ENDPOINT_IPS=""
ENDPOINT_PRIMARY=""
SB_PID=""

log() { echo "[claw-stealth $(date -u +%H:%M:%S)] $*"; }
fatal() { log "FATAL: $*"; exit 1; }

# --- Helpers -----------------------------------------------------------------
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

ensure_tun() {
  if [ ! -c /dev/net/tun ]; then
    log "creating /dev/net/tun"
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
  fi
}

# Resolve the endpoint before the kill switch exists. Reality mode passes an
# IP (no lookup at all); WS mode passes a Cloudflare hostname (one lookup).
resolve_endpoint() {
  [ -n "$TUNNEL_SERVER" ] || fatal "TUNNEL_SERVER is not set — copy .env.example to .env"
  if is_ipv4 "$TUNNEL_SERVER"; then
    ENDPOINT_IPS="$TUNNEL_SERVER"
    log "endpoint is a literal IP — zero bootstrap DNS"
  else
    log "resolving endpoint ${TUNNEL_SERVER} (one-time bootstrap lookup)"
    ENDPOINT_IPS="$(dig +short A "$TUNNEL_SERVER" 2>/dev/null \
                    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')"
  fi
  [ -n "$ENDPOINT_IPS" ] || fatal "could not resolve TUNNEL_SERVER=${TUNNEL_SERVER}"
  ENDPOINT_PRIMARY="$(echo "$ENDPOINT_IPS" | head -n1)"
  log "endpoint IP(s): $(echo $ENDPOINT_IPS | tr '\n' ' ')"
}

# Pin the resolved IP into the config and honour the MUX_ENABLED flag.
render_config() {
  [ -f "$CLIENT_CONFIG" ] || fatal "missing $CLIENT_CONFIG — generate it with server/setup-server.sh"
  mkdir -p "$RUN_DIR"
  if ! jq --arg srv "$ENDPOINT_PRIMARY" \
        '(.outbounds[] | select(.tag=="vless-out").server) = $srv' \
        "$CLIENT_CONFIG" > "${RUNTIME_CONFIG}.tmp"; then
    fatal "client config is not valid JSON: $CLIENT_CONFIG"
  fi
  if [ "$MUX_ENABLED" = "true" ]; then
    mv "${RUNTIME_CONFIG}.tmp" "$RUNTIME_CONFIG"
    log "multiplex + padding: enabled"
  else
    jq 'del(.outbounds[] | select(.tag=="vless-out").multiplex)' \
       "${RUNTIME_CONFIG}.tmp" > "$RUNTIME_CONFIG"
    rm -f "${RUNTIME_CONFIG}.tmp"
    log "multiplex + padding: disabled"
  fi
  sing-box check -c "$RUNTIME_CONFIG" || fatal "rendered sing-box config failed validation"
}

# --- Kill switch -------------------------------------------------------------
# Drop every packet that does not leave through tun0, except the encrypted
# connection to the tunnel endpoint itself. If the tunnel dies, API calls
# fail closed instead of silently falling back to the open wifi.
arm_killswitch() {
  if [ "$KILL_SWITCH" != "true" ]; then
    log "kill switch: DISABLED (KILL_SWITCH != true)"
    return 0
  fi
  iptables -P OUTPUT ACCEPT
  iptables -F OUTPUT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -o tun0 -j ACCEPT
  for ip in $ENDPOINT_IPS; do
    iptables -A OUTPUT -d "$ip" -p tcp --dport "$TUNNEL_PORT" -j ACCEPT
  done
  iptables -A OUTPUT -j LOG --log-prefix "claw-stealth-drop " --log-level 4 2>/dev/null || true
  iptables -P OUTPUT DROP

  # No tunnel here carries IPv6 — drop all of it so it cannot leak around v4.
  ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true

  log "kill switch: ARMED — egress allowed only via tun0 or to ${ENDPOINT_PRIMARY}:${TUNNEL_PORT}"
}

# --- Time window (cron-driven) ----------------------------------------------
# A cron job inside this container toggles a flag file at the window edges;
# the supervisor brings the tunnel up/down to match.
window_open() {
  [ "$TIME_WINDOW_ENABLED" != "true" ] && return 0
  [ -f "$WINDOW_FLAG" ] && return 0
  return 1
}

seed_window_flag() {
  local sh sm eh em now start end
  sh="${TIME_WINDOW_START%%:*}"; sm="${TIME_WINDOW_START##*:}"
  eh="${TIME_WINDOW_END%%:*}";   em="${TIME_WINDOW_END##*:}"
  now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  start=$(( 10#$sh * 60 + 10#$sm ))
  end=$(( 10#$eh * 60 + 10#$em ))
  local inside=1
  if [ "$start" -le "$end" ]; then
    { [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]; } && inside=0
  else
    { [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]; } && inside=0
  fi
  if [ "$inside" -eq 0 ]; then touch "$WINDOW_FLAG"; else rm -f "$WINDOW_FLAG"; fi
}

setup_cron() {
  [ "$TIME_WINDOW_ENABLED" = "true" ] || return 0
  local sh sm eh em
  sh="${TIME_WINDOW_START%%:*}"; sm="${TIME_WINDOW_START##*:}"
  eh="${TIME_WINDOW_END%%:*}";   em="${TIME_WINDOW_END##*:}"
  mkdir -p /etc/crontabs
  cat > /etc/crontabs/root <<EOF
# claw-stealth tunnel time window — generated by entrypoint.sh
${sm} ${sh} * * * touch ${WINDOW_FLAG}
${em} ${eh} * * * rm -f ${WINDOW_FLAG}
EOF
  seed_window_flag
  crond -b -c /etc/crontabs -L /dev/stderr 2>/dev/null \
    || crond -b -c /etc/crontabs 2>/dev/null \
    || log "WARN: crond failed to start — time window will not be enforced"
  log "time window: ENABLED ${TIME_WINDOW_START}-${TIME_WINDOW_END} (cron-managed)"
}

# --- sing-box supervision ----------------------------------------------------
jitter_seconds() {
  local lo=$(( RECONNECT_MIN_MINUTES * 60 ))
  local hi=$(( RECONNECT_MAX_MINUTES * 60 ))
  [ "$hi" -le "$lo" ] && { echo "$lo"; return; }
  echo $(( lo + RANDOM % (hi - lo + 1) ))
}

start_singbox() {
  sing-box run -c "$RUNTIME_CONFIG" &
  SB_PID=$!
}

stop_singbox() {
  [ -n "$SB_PID" ] || return 0
  kill "$SB_PID" 2>/dev/null || true
  wait "$SB_PID" 2>/dev/null || true
  SB_PID=""
}

shutdown() {
  log "received stop signal — shutting down tunnel"
  stop_singbox
  exit 0
}
trap shutdown TERM INT

supervise() {
  while true; do
    if ! window_open; then
      [ -n "$SB_PID" ] && { log "outside time window — tunnel down"; stop_singbox; }
      sleep 30
      continue
    fi

    start_singbox
    log "tunnel up (sing-box pid ${SB_PID})"

    local nap
    if [ "$AUTO_RECONNECT" = "true" ]; then
      nap="$(jitter_seconds)"
      log "auto-reconnect scheduled in $(( nap / 60 )) min"
    else
      nap=86400
    fi

    local waited=0
    while [ "$waited" -lt "$nap" ]; do
      sleep 10
      waited=$(( waited + 10 ))
      if ! kill -0 "$SB_PID" 2>/dev/null; then
        log "sing-box exited on its own — will restart"
        SB_PID=""
        break
      fi
      window_open || { log "time window closed — bringing tunnel down"; break; }
    done

    [ "$AUTO_RECONNECT" = "true" ] && [ -n "$SB_PID" ] && log "cycling tunnel (jittered reconnect)"
    stop_singbox
    sleep 5
  done
}

# --- Main --------------------------------------------------------------------
log "claw-stealth tunnel starting ($(sing-box version | head -n1))"
mkdir -p "$RUN_DIR"
ensure_tun
resolve_endpoint
render_config
arm_killswitch
setup_cron
supervise
