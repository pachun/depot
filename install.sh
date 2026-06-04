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

# Drop into zsh. orchard installs it and runs chsh, but the running
# session predates chsh so it stays bash until next login — unless we
# explicitly replace it. Skipped if the caller is already zsh (so
# re-running from within zsh doesn't pile up nested shells).
if [ "$(ps -p "$PPID" -o comm=)" != "zsh" ] && command -v zsh >/dev/null 2>&1; then
  exec zsh
fi
