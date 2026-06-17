#!/usr/bin/env bash
# Top-level setup. Iterates install/ alphabetically — adding a feature
# is `mkdir install/<name> && touch install/<name>/install.sh`; no
# edits here required. Idempotent; re-run any time.
#
# Same dispatcher shape as bootstrap.sh and configure.sh: every step's
# interactive prompts are collected up front in Phase 1, then Phase 2
# runs the actual install work unattended. The point is that the user
# can walk away the moment the prompt phase ends; nothing later in the
# run will block on stdin.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase 1: source every step's prompts.sh up front so all interactive
# inputs happen before any actual install work begins.
for d in "$HERE/install"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  [ -f "$d/prompts.sh" ] && source "$d/prompts.sh"
done

# Phase 2: run each step.
for d in "$HERE/install"/*/; do
  [[ "$(basename "$d")" == _* ]] && continue
  bash "$d/install.sh"
done

# First-time install: caller is still bash (chsh hasn't taken effect
# for this session). Replace bash with zsh so the user lands on the
# orchard prompt without a manual `exec zsh`. Subsequent re-runs are
# already inside zsh — the new config picks up on the next interactive
# session (reconnect SSH, or `exec zsh` manually).
if [ "$(ps -p "$PPID" -o comm=)" != "zsh" ] && command -v zsh >/dev/null 2>&1; then
  exec zsh
fi
