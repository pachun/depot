#!/usr/bin/env bash
# Aviary — the unified media app frontend (Phoenix web UI). Lives in
# its own repo at github.com/pachun/aviary so it can iterate without
# tangling with the NAS-setup history here; this feature is the
# integration seam that clones (or syncs) that source and builds the
# docker image so framework-depot always runs the latest pushed main.
#
# Idempotent: fetch + reset --hard is a no-op when already current,
# and docker-compose's layer cache means rebuilds skip unchanged
# layers. fetch + reset rather than pull because this clone is a
# deploy artifact, not a dev tree — a local divergence (which
# shouldn't happen) must never block the deploy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

SRC=~/library/apps/aviary
mkdir -p "$(dirname "$SRC")"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/pachun/aviary.git "$SRC"
else
  git -C "$SRC" fetch origin main
  git -C "$SRC" reset --hard origin/main
fi

# Phoenix release needs a SECRET_KEY_BASE to sign cookies/sessions.
# Generate once, persist, reuse — without persistence, every rebuild
# would invalidate active sessions.
SECRET_DIR=~/library/.config/aviary
SECRET_FILE="$SECRET_DIR/secret_key_base"
mkdir -p "$SECRET_DIR"
if [ ! -f "$SECRET_FILE" ]; then
  openssl rand -base64 48 | tr -d '\n' > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
SECRET_KEY_BASE=$(cat "$SECRET_FILE")

sudo ufw allow 4000/tcp

# --build forces a rebuild check on every run; layer cache makes the
# unchanged case fast (Docker resolves the COPY layer against the
# fetched source and finds everything cached).
sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  SRC="$SRC" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  PHX_HOST="$HOSTNAME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d --build
