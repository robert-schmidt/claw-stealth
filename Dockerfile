# claw-stealth claw container.
#
# A Debian bookworm dev box (Rust + Python + Node + PHP + Composer) that
# clones and builds ultraworkers/claw-code. It runs with
# network_mode: "service:tunnel", so every byte it sends — including DNS —
# is already inside the tunnel's network namespace and kill switch.
FROM debian:bookworm-slim

ARG CLAW_REPO=https://github.com/ultraworkers/claw-code.git
ARG CLAW_BRANCH=auto

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin

# --- Base toolchain --------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg \
      build-essential pkg-config libssl-dev \
      python3 python3-pip python3-venv \
      php-cli php-mbstring php-xml php-curl \
      jq unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# --- Node.js (LTS) ---------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && node --version && npm --version

# --- Composer --------------------------------------------------------------
RUN curl -fsSL https://getcomposer.org/installer | php -- \
      --install-dir=/usr/local/bin --filename=composer \
 && composer --version

# --- Rust toolchain --------------------------------------------------------
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
 && rustc --version && cargo --version

# --- claw-code -------------------------------------------------------------
# Clone (prefer dev/rust, fall back to main) and best-effort build. A build
# failure does not fail the image: the source stays at /opt/claw-code.
COPY client/build-claw.sh /usr/local/bin/build-claw.sh
RUN chmod +x /usr/local/bin/build-claw.sh \
 && CLAW_REPO="$CLAW_REPO" CLAW_BRANCH="$CLAW_BRANCH" /usr/local/bin/build-claw.sh

COPY client/claw-entrypoint.sh /usr/local/bin/claw-entrypoint.sh
RUN chmod +x /usr/local/bin/claw-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/claw-entrypoint.sh"]
CMD ["claw"]
