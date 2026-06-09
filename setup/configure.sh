#!/usr/bin/env bash
# Run after SSH-ing in from your main machine. Sets up the services
# this NAS exists to provide (tailscale, jellyfin, samba, etc.).
# Separated from install.sh because anything here that needs a browser
# (tailscale's auth URL, future OAuth flows) is much nicer to handle
# from an SSH session than from the local TTY where the URL has to be
# typed by hand into a phone.
#
# Same dispatcher shape as install.sh — iterates configure/*/ in
# alphabetical order; adding a feature is `mkdir configure/<name>` +
# drop in a configure.sh and optional prompts.sh. Idempotent.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase 1: source every feature's prompts.sh upfront so all interactive
# inputs happen before any actual configure work begins.
for d in "$HERE/configure"/*/; do
  [ -f "$d/prompts.sh" ] && source "$d/prompts.sh"
done

# Phase 2: run each feature.
for d in "$HERE/configure"/*/; do
  bash "$d/configure.sh"
done
