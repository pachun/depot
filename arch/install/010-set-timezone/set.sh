#!/usr/bin/env bash
# Set the system timezone by walking the user through tzselect (numbered
# menus: continent → country → region → confirm). Avoids needing the
# IANA string up front. Idempotent — skips if already set to something
# other than UTC.
set -euo pipefail

current=$(timedatectl show --value -p Timezone 2>/dev/null || echo UTC)

if [[ "$current" != "UTC" && "$current" != "Etc/UTC" ]]; then
    exit 0
fi

echo
echo "Walking through tzselect to pick the system timezone..."
echo

if ! tz=$(tzselect | tail -1); then
    echo "tzselect aborted; leaving as UTC." >&2
    exit 0
fi

if [[ -z "$tz" ]]; then
    echo "No selection; leaving as UTC." >&2
    exit 0
fi

ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
hwclock --systohc
echo "Timezone set to $tz."
