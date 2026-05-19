#!/usr/bin/env bash
# Entrypoint for the claw container.
#
# This container runs in the tunnel's network namespace. Point DNS at an
# address that the tunnel's tun device hijacks: sing-box answers it over
# DoH *inside* the encrypted tunnel, so the local/wifi network never sees a
# query. The kill switch drops anything that somehow misses the tunnel, so
# DNS fails closed rather than leaking.
set -u

RESOLV="/etc/resolv.conf"
if printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\noptions ndots:0\n' > "$RESOLV" 2>/dev/null; then
  :
else
  echo "[claw] WARN: could not rewrite ${RESOLV} (read-only?) — DNS may use defaults" >&2
fi

# Friendly notice if the API keys were never filled in.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "[claw] note: no ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY set in .env" >&2
fi

exec "$@"
