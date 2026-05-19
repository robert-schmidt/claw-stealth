# claw-stealth

A portable Docker stack that runs [claw-code](https://github.com/ultraworkers/claw-code)
inside a container whose traffic is tunneled through your own self-hosted
server. The tunnel impersonates ordinary HTTPS, so it keeps working on networks
that block or throttle generic VPN protocols.

## What this is for

- **Public wifi privacy** — coffee shops, hotels, airports, conferences and
  co-working spaces. Whoever runs the access point sees only a TLS connection
  that looks like a visit to a major website, not your AI API traffic.
- **Networks that filter or throttle** — captive portals and ISP-level filters
  routinely block traffic that doesn't look like a recognized web service. The
  tunnel's TLS handshake is indistinguishable from a normal visit to
  `www.microsoft.com` (configurable), so it passes.
- **Dev work from regions with restrictive internet** — keep working against
  Anthropic / OpenAI / Gemini APIs without your requests being visible or
  classified as proxy traffic.

It is, in short, a self-hosted tunnel for one specific job: keeping an AI
coding agent's traffic private and reliable on hostile networks.

## How it works

```
  ┌─────────────── your laptop ───────────────┐          ┌──── your VPS ────┐
  │  claw container          tunnel container  │          │                  │
  │  (claw-code)  ──┐        ┌── sing-box ──────┼─ TLS ───►│  sing-box server │──► internet
  │  network_mode:  └─tun0──►┤   VLESS+Reality  │  :443    │  VLESS+Reality   │
  │  service:tunnel          │   kill switch    │ (looks   │                  │
  │                          │   auto-reconnect │  like    └──────────────────┘
  └────────────────────────────────────────────┘  HTTPS)
```

- The **tunnel** container runs sing-box in TUN mode: it creates `tun0` and
  routes `0.0.0.0/0` through your VPS on `:443`.
- The **claw** container has no network of its own (`network_mode:
  service:tunnel`) — every byte it sends, including DNS, is already inside the
  tunnel and the kill switch.
- On the **server**, sing-box terminates the tunnel and forwards to the open
  internet. The Reality transport makes the TLS handshake look like a normal
  visit to a real website.

Both ends are a single sing-box binary — no extra tools.

## Prerequisites

**Laptop (client):**
- Docker Engine + Docker Compose v2 (`docker compose version`)
- Linux or macOS (TUN mode needs `/dev/net/tun`; works in Docker Desktop)

**Server:**
- A VPS running fresh Ubuntu 22.04+ with root access
- A domain you control on Cloudflare DNS

## Quickstart

### 1. Server

On the VPS:

```bash
git clone <this-repo> claw-stealth && cd claw-stealth/server
sudo ./setup-server.sh
```

The script installs Docker, generates a fresh Reality keypair / UUID / shortID,
writes and validates the sing-box config, starts the server, and prints:

- the exact JSON to drop into `client/sing-box.client.json`
- the `TUNNEL_SERVER` / `TUNNEL_PORT` values for `.env`
- a `vless://` share link and a QR code

Pick a mode when prompted:

| Mode | When to use | DNS record |
|------|-------------|------------|
| **Reality (direct)** | Default. Best stealth, lowest latency. | Generic subdomain (e.g. `cdn-edge.example.com`) A-record to the VPS, Cloudflare proxy **off** (grey cloud). |
| **VLESS + WS + TLS** | When the wifi blocks direct connections to non-CDN IPs. | A-record to the VPS, Cloudflare proxy **on** (orange cloud), SSL/TLS mode "Full (strict)". Auto-renewing Let's Encrypt cert via ACME DNS-01. |

Re-running `setup-server.sh` is safe — it reuses cached secrets. Use
`--regenerate` to roll new ones. See `./setup-server.sh --help` for flags.

### 2. Client

On your laptop, in the `claw-stealth` directory:

```bash
cp .env.example .env
# paste the printed JSON into this file:
$EDITOR client/sing-box.client.json
# set TUNNEL_SERVER (+ API keys) in .env:
$EDITOR .env

docker compose up -d --build
```

Then verify and use it:

```bash
./verify-tunnel.sh                       # egress IP is the VPS, DNS works
./verify-killswitch.sh                   # traffic fails closed when tunnel drops
docker compose exec -it claw claw        # run claw-code inside the tunnel
```

Put your project code in `./workspace` (or point `WORKSPACE_DIR` in `.env` at
it); it is mounted at `/workspace` inside the claw container.

## Configuration

All client-side behavior is set via `.env` (see `.env.example` for the full
list). Every reliability/privacy feature is flag-gated:

| Flag | Default | Effect |
|------|---------|--------|
| `KILL_SWITCH` | `true` | Drop any egress not via `tun0`; traffic fails closed if the tunnel dies. |
| `AUTO_RECONNECT` | `true` | Tear down + rebuild the tunnel on a jittered cycle so it survives flaky cafe wifi. |
| `RECONNECT_MIN_MINUTES` / `RECONNECT_MAX_MINUTES` | `45` / `90` | Bounds of the jittered reconnect interval. |
| `MUX_ENABLED` | `true` | Multiplex + padding — better throughput on lossy wifi, normalized packet sizes. |
| `TIME_WINDOW_ENABLED` | `false` | Restrict tunnel uptime to set hours via cron inside the container. |
| `TIME_WINDOW_START` / `TIME_WINDOW_END` | `09:00` / `23:00` | The allowed window (24h, container `TZ`). |

## Privacy notes

- **Kill switch.** `iptables` in the tunnel container drops every packet that
  is not bound for `tun0` or the encrypted connection to your VPS. If the
  tunnel drops on flaky wifi, AI API calls fail closed — they never silently
  fall back to the open network. IPv6 egress is dropped entirely.
- **DNS leak prevention.** The claw container's resolver points at an address
  the tunnel's TUN device hijacks; sing-box answers it over DNS-over-HTTPS
  (`1.1.1.1/dns-query`) *inside* the encrypted tunnel. The local network never
  sees a DNS query. (Note: sing-box has no loopback DNS listener, so the
  resolver address is a tunnel-routed IP rather than `127.0.0.1`; with the kill
  switch armed, any query that missed the tunnel is dropped rather than
  leaked.)
- **Bootstrap.** The tunnel endpoint is resolved exactly once, before the kill
  switch is armed. In Reality mode `TUNNEL_SERVER` is an IP, so there is *zero*
  bootstrap DNS; in WS mode it is one lookup of a Cloudflare hostname.
- **Reality target.** The handshake impersonates `www.microsoft.com:443` by
  default — configurable with `setup-server.sh --reality-target`.

## Troubleshooting

- `tun0` missing / tunnel unhealthy → check `docker compose logs tunnel`.
  TUN mode needs `cap_add: NET_ADMIN` and `/dev/net/tun` (both already in
  `docker-compose.yml`).
- `verify-tunnel.sh` shows claw's IP equals your laptop's IP → the tunnel is
  not carrying traffic; check the server is up (`docker compose -f
  /etc/claw-stealth/docker-compose.yml ps` on the VPS).
- WS mode handshake fails → confirm Cloudflare SSL/TLS mode is "Full (strict)"
  and the ACME cert issued (`docker logs claw-stealth-server` on the VPS).
- claw-code build → the `claw` container clones `ultraworkers/claw-code`
  (prefers `dev/rust`, falls back to `main`) and builds best-effort. If the
  upstream branch does not compile, the source is still at `/opt/claw-code`
  inside the container.

## License

MIT — see [LICENSE](LICENSE).

This project orchestrates [sing-box](https://github.com/SagerNet/sing-box) and
[claw-code](https://github.com/ultraworkers/claw-code), which carry their own
licenses.
