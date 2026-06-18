#!/usr/bin/env bash
# Run after SSH-ing in from your main machine. Sets up the services
# this NAS exists to provide (tailscale, jellyfin, samba, etc.).
# Separated from arch/configure.sh because anything here that needs a
# browser (tailscale's auth URL, future OAuth flows) is much nicer to
# handle from an SSH session than from the local TTY where the URL has
# to be typed by hand into a phone.
#
# Same dispatcher shape as arch/install.sh and arch/configure.sh —
# iterates configure/*/ in alphabetical order; adding a feature is
# `mkdir configure/<name>` + drop in a configure.sh and optional
# prompts.sh / summary.sh.
#
# Directories whose basename starts with `_` are NOT iterated — those
# are library code (currently _shared/, which holds cross-service
# helpers that individual feature folders source by path). Same
# convention you'd reach for in Python (`_private`) or Ruby (leading
# underscore): bare names are features, underscored names are
# infrastructure.
# Idempotent.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-run scratch dir for the in-run service guard. Each service's
# configure.sh touches a sentinel here on its first invocation, and
# subsequent invocations within the SAME dispatcher run early-exit on
# seeing the sentinel. Without this, an explicit dependency chain like
# `aviary → jellyfin → tailscale` plus the dispatcher iterating
# jellyfin and tailscale itself, plus jellyseerr → sonarr → jellyfin →
# … would re-run heavy bootstrap blocks (wizards, container starts,
# tailscale serve) many times per install — slow, noisy, and looks
# like an infinite loop to the user reading the terminal output. Reset
# every fresh dispatcher invocation so retries naturally redo
# everything.
export DEPOT_RUN_DIR=$(mktemp -d -t depot-run-XXXXXXXX)
trap 'rm -rf "$DEPOT_RUN_DIR"' EXIT

# Phase 1: source every feature's prompts.sh upfront so all interactive
# inputs happen before any actual configure work begins.
for d in "$HERE/configure"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  [ -f "$d/prompts.sh" ] && source "$d/prompts.sh"
done

# Clear any tailscale-serve bindings left over from previous runs.
# Tailscaled binds tailnet-IP:PORT (e.g. 100.81.180.23:8080) for each
# active serve mapping, and those binds persist across container
# removals. A re-run that recreates a container with the matching
# port (e.g. gluetun publishing 8080 for qBittorrent's WebUI) then
# fails at `docker-compose up` with "address already in use" — docker
# wants 0.0.0.0:8080 and Linux refuses because the tailnet-IP listener
# already owns it. Each service re-establishes its own serve binding
# via expose-https.sh after its container is up, so wiping all serve
# state here is safe. On a fresh install where tailscale isn't auth'd
# yet, `serve reset` is a silent no-op via the `|| true`.
sudo tailscale serve reset >/dev/null 2>&1 || true

# Remove any containers from previous failed runs that aren't currently
# running. docker-compose's `up -d` will start an existing container in
# whatever state it's in — and a container that was Created/Restarting
# from an earlier abort (e.g. port conflict at first bind) has a
# half-initialized netns that doesn't recover by being started: gluetun
# in particular fails at "default route not found" because the bridge
# was never fully wired up. Cleaning up here forces docker-compose to
# create fresh on the next run.
for _d in "$HERE/configure"/*/; do
  _service=$(basename "$_d")
  [[ "$_service" == _* ]] && continue
  if docker inspect "$_service" >/dev/null 2>&1; then
    _state=$(docker inspect "$_service" --format '{{.State.Status}}' 2>/dev/null)
    if [ "$_state" != "running" ]; then
      docker rm -f "$_service" >/dev/null 2>&1 || true
    fi
  fi
done
unset _d _service _state

# Phase 2: run each feature.
for d in "$HERE/configure"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  bash "$d/configure.sh"
done

# Phase 3: every feature's summary.sh prints its service URL(s). Run
# last so all addresses land together at the bottom of the output
# rather than scattered through Phase 2's chatter. See README's final
# step for the first-run web-UI steps each URL needs.
echo
for d in "$HERE/configure"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  [ -f "$d/summary.sh" ] && bash "$d/summary.sh"
done
echo
