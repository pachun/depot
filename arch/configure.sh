#!/usr/bin/env bash
# Arch userland configure. Iterates configure/ alphabetically — adding
# a feature is `mkdir configure/<name> && touch configure/<name>/configure.sh`;
# no edits here required. Idempotent; re-run any time.
#
# Same dispatcher shape as arch/install.sh and services/configure.sh:
# every step's interactive prompts are collected up front in Phase 1,
# then Phase 2 runs the actual configure work unattended. The user can
# walk away the moment the prompt phase ends; nothing later in the run
# will block on stdin.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase 1: source every step's prompts.sh up front so all interactive
# inputs happen before any actual configure work begins.
for d in "$HERE/configure"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  [ -f "$d/prompts.sh" ] && source "$d/prompts.sh"
done

# Phase 2: run each step.
for d in "$HERE/configure"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  bash "$d/configure.sh"
done

# First-time install: caller is still bash (chsh hasn't taken effect
# for this session). Replace bash with zsh so the user lands on the
# orchard prompt without a manual `exec zsh`. Subsequent re-runs are
# already inside zsh — the new config picks up on the next interactive
# session (reconnect SSH, or `exec zsh` manually).
if [ "$(ps -p "$PPID" -o comm=)" != "zsh" ] && command -v zsh >/dev/null 2>&1; then
  exec zsh
fi
