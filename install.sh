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
