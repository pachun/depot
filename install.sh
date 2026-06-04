#!/usr/bin/env bash
# Top-level setup. Iterates install/ alphabetically — adding a feature
# is `mkdir install/<name> && touch install/<name>/install.sh`; no
# edits here required. Idempotent; re-run any time.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for d in "$HERE/install"/*/; do
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
