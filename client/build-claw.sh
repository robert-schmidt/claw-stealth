#!/usr/bin/env bash
# Clone and best-effort build of claw-code, run at claw-image build time.
# Branch order: explicit CLAW_BRANCH, else "auto" = dev/rust then main.
set -u

REPO="${CLAW_REPO:-https://github.com/ultraworkers/claw-code.git}"
BRANCH="${CLAW_BRANCH:-auto}"
DEST="/opt/claw-code"

clone_branch() {
  echo ">> cloning ${REPO} @ ${1}"
  git clone --depth 1 --branch "$1" "$REPO" "$DEST" 2>/dev/null
}

# --- Clone -----------------------------------------------------------------
if [ "$BRANCH" = "auto" ]; then
  if clone_branch "dev/rust"; then
    echo ">> claw-code: using dev/rust"
  elif clone_branch "main"; then
    echo ">> claw-code: dev/rust unavailable — fell back to main"
  else
    echo "ERROR: could not clone claw-code from ${REPO}" >&2
    exit 1
  fi
else
  clone_branch "$BRANCH" || { echo "ERROR: could not clone branch ${BRANCH}" >&2; exit 1; }
  echo ">> claw-code: using ${BRANCH}"
fi

cd "$DEST" || exit 1

# --- Build (best effort — never fails the image) ---------------------------
BUILT_DIR=""
if [ -f rust/Cargo.toml ]; then
  echo ">> building Rust workspace (rust/) ..."
  ( cd rust && cargo build --release ) && BUILT_DIR="rust/target/release" \
    || echo "WARN: cargo build failed — see source at ${DEST}/rust"
elif [ -f Cargo.toml ]; then
  echo ">> building Rust workspace ..."
  cargo build --release && BUILT_DIR="target/release" \
    || echo "WARN: cargo build failed — see source at ${DEST}"
elif [ -f package.json ]; then
  echo ">> installing Node project ..."
  npm install --omit=dev || echo "WARN: npm install failed — see source at ${DEST}"
elif [ -x install.sh ]; then
  echo ">> running install.sh ..."
  ./install.sh || echo "WARN: install.sh failed — see source at ${DEST}"
fi

# --- Expose the binary as /usr/local/bin/claw ------------------------------
if [ -n "$BUILT_DIR" ]; then
  for cand in claw clawd claw-code rusty-claude-cli; do
    if [ -x "${DEST}/${BUILT_DIR}/${cand}" ]; then
      ln -sf "${DEST}/${BUILT_DIR}/${cand}" /usr/local/bin/claw
      echo ">> installed: claw -> ${DEST}/${BUILT_DIR}/${cand}"
      break
    fi
  done
fi

if [ ! -e /usr/local/bin/claw ]; then
  # Wrapper so `claw` is always a valid command — points users at the source.
  cat > /usr/local/bin/claw <<'EOF'
#!/usr/bin/env bash
echo "claw-code was cloned to /opt/claw-code but no prebuilt binary is present."
echo "Build/run it from there — e.g.  cd /opt/claw-code/rust && cargo run --release"
exec bash
EOF
  chmod +x /usr/local/bin/claw
  echo "WARN: no claw-code binary produced — /usr/local/bin/claw will print build hints"
fi
