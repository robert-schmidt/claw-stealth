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
  Anthropic / OpenAI APIs without your requests being visible or classified as
  proxy traffic.

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

- A laptop with **Docker Engine + Docker Compose v2** (`docker compose
  version`). Linux or macOS — TUN mode needs `/dev/net/tun`, which works in
  Docker Desktop.
- A cheap Linux **VPS** (set up in Step 1 below).
- For WS mode only: a **domain on Cloudflare** (Step 2).

---

## Step 1 — Create a server (VPS)

You need a small Linux server. Any provider works — DigitalOcean, Hetzner,
Vultr, Linode, etc.

1. Create an account with a VPS provider.
2. Create a server (a "droplet" / "instance" / "VM"):
   - **OS:** Ubuntu 22.04 LTS or newer.
   - **Size:** the cheapest tier is plenty — 1 shared vCPU and 1 GB RAM. The
     tunnel is lightweight; pay for bandwidth, not cores.
   - **Region:** pick one with good connectivity for your use; closer to you is
     lower latency.
   - Add your **SSH public key** when prompted.
3. Note the server's **public IPv4 address**.
4. SSH in: `ssh root@<VPS_IP>`

For **Reality mode** (the default, recommended) that is all you need — no
domain required, the client connects straight to the IP.

## Step 2 — Point a domain at the server (WS mode only)

Skip this for Reality mode. WS mode tunnels through Cloudflare's CDN, so it
needs a Cloudflare-proxied hostname:

1. Have a domain name. If you don't, register one (Cloudflare Registrar,
   Namecheap, etc.).
2. Add the domain to Cloudflare (the free plan is fine): Cloudflare dashboard →
   **Add a site** → enter your domain → follow the prompts → at your registrar,
   change the domain's **nameservers** to the two Cloudflare gives you. Wait
   until the domain shows **Active**.
3. **DNS → Records → Add record:**
   - Type `A`, Name `cdn-edge` (any generic-looking subdomain — this becomes
     `cdn-edge.yourdomain.com`), IPv4 address = your VPS IP.
   - **Proxy status: Proxied** (orange cloud).
4. **SSL/TLS → Overview:** set the encryption mode to **Full (strict)**.
5. Create an API token so the server can auto-renew its TLS certificate:
   **My Profile → API Tokens → Create Token →** use the **"Edit zone DNS"**
   template → scope it to your zone → **Create** → copy the token (shown once).

> For Reality mode you can *optionally* add an `A` record too, if you'd rather
> use a hostname than a bare IP — but set **Proxy status: DNS only** (grey
> cloud) and you don't need an API token.

## Step 3 — Run the server setup

On the VPS:

```bash
git clone https://github.com/robert-schmidt/claw-stealth.git
cd claw-stealth/server
sudo ./setup-server.sh
```

It installs Docker, generates a fresh Reality keypair / UUID / shortID, writes
and validates the sing-box config, starts the server, and prints everything you
need for the client. Pick a mode when prompted:

| Mode | When to use | Needs |
|------|-------------|-------|
| **Reality (direct)** | Default. Best stealth, lowest latency. | Just the VPS. |
| **VLESS + WS + TLS** | When the wifi blocks direct connections to non-CDN IPs. | A Cloudflare domain + API token (Step 2). |

Re-running `setup-server.sh` is safe — it reuses cached secrets. Use
`--regenerate` to roll new ones, or `--help` for non-interactive flags.

## Step 4 — Configure the client

On your laptop:

```bash
git clone https://github.com/robert-schmidt/claw-stealth.git
cd claw-stealth
cp .env.example .env
```

1. Paste the JSON that `setup-server.sh` printed into
   `client/sing-box.client.json`.
2. In `.env`, set `TUNNEL_SERVER` to the value the script printed (your VPS IP
   for Reality mode, or `cdn-edge.yourdomain.com` for WS mode).
3. Add your AI provider keys to `.env` — see the next section.

## Step 5 — Add your AI provider keys

claw-code talks to AI providers directly; it needs an API key. The keys go in
`.env` and are passed into the claw container as environment variables. Fill in
**only the provider you use**.

**Anthropic (Claude) — the default.** Get a key at
[console.anthropic.com](https://console.anthropic.com) → **API Keys**.

```ini
ANTHROPIC_API_KEY=sk-ant-...
```

> ⚠️ claw-code accepts two Anthropic credential slots and they are **not**
> interchangeable. A normal `sk-ant-...` key goes in `ANTHROPIC_API_KEY`. An
> OAuth / proxy **bearer token** goes in `ANTHROPIC_AUTH_TOKEN`. Putting an
> `sk-ant-` key in the bearer slot is the #1 cause of `401` errors.

**OpenAI / OpenRouter / other OpenAI-compatible gateways.** Set the key and,
for anything other than OpenAI itself, the base URL:

```ini
OPENAI_API_KEY=sk-or-v1-...
OPENAI_BASE_URL=https://openrouter.ai/api/v1
```

**Google Gemini.** claw-code reaches Gemini through Google's
OpenAI-compatible endpoint — put the Gemini key in `OPENAI_API_KEY` and set
`OPENAI_BASE_URL` to that endpoint (`GEMINI_API_KEY` is also passed through for
tools that read it).

`XAI_API_KEY` (grok) and `DASHSCOPE_API_KEY` (qwen) are supported too — see
`.env.example`. After the stack is up, sanity-check your credentials with:

```bash
docker compose exec claw claw doctor
```

## Step 6 — Start it and verify

```bash
docker compose up -d --build      # builds both images, starts the stack
./verify-tunnel.sh                # egress IP is the VPS, DNS works
./verify-killswitch.sh            # traffic fails closed when the tunnel drops
```

Put your project code in `./workspace` (or point `WORKSPACE_DIR` in `.env` at a
project elsewhere); it is mounted at `/workspace` inside the claw container.

## Using claw-code — choosing a model

claw-code runs **inside the claw container**. Open a shell or run a one-shot
prompt with `docker compose exec`:

```bash
# interactive
docker compose exec -it claw claw

# one-shot prompt
docker compose exec claw claw prompt "explain src/main.rs"
```

**The model is chosen per run with `--model`.** claw-code ships these aliases:

| Alias | Model |
|-------|-------|
| `opus`   | `claude-opus-4-6` |
| `sonnet` | `claude-sonnet-4-6` |
| `haiku`  | `claude-haiku-4-5-...` |

```bash
docker compose exec claw claw --model sonnet prompt "review this diff"
```

You can also pass a full model name, or a **provider-prefixed** name to route to
a non-Anthropic backend — `--model openai/gpt-4.1-mini`, `--model grok`,
`--model qwen-plus`. Define your own shortcuts in a `.claw.json` at the root of
your project (`/workspace`):

```json
{ "aliases": { "quick": "haiku", "deep": "opus" } }
```

Permission level is set with `--permission-mode` (`read-only`,
`workspace-write`, `danger-full-access`). See claw-code's own
[USAGE.md](https://github.com/ultraworkers/claw-code/blob/main/USAGE.md) for the
full command reference.

## Configuration

All tunnel behavior is set via `.env` (see `.env.example` for the full list).
Every reliability/privacy feature is flag-gated:

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
  sees a DNS query. (sing-box has no loopback DNS listener, so the resolver
  address is a tunnel-routed IP rather than `127.0.0.1`; with the kill switch
  armed, any query that missed the tunnel is dropped, not leaked.)
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
  not carrying traffic; on the VPS check `docker compose -f
  /etc/claw-stealth/docker-compose.yml ps`.
- `401` from the AI provider → see the Anthropic credential warning in Step 5;
  run `docker compose exec claw claw doctor`.
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
