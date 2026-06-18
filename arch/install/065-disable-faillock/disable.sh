#!/usr/bin/env bash
# Disable PAM's faillock-based sudo lockout. Arch defaults to locking
# the account after 3 failed sudo password attempts within 15 minutes,
# with a 10-minute lockout window that EXTENDS every time you retry
# during the lockout (the "wrong password" message during lockout
# tricks muscle memory into immediate re-attempts that pile on more
# lockout time). On a single-user NAS behind LAN + tailscale + SSH key
# auth, brute-force protection at the sudo layer doesn't meaningfully
# reduce risk — but it absolutely will brick the install if you mistype
# a few sudo passwords in a row.
#
# `deny = 0` is the documented "never lock" setting (see man
# faillock.conf). Cleaner than removing pam_faillock from
# /etc/pam.d/system-auth entirely because the module stays loaded but
# never decides to lock — no PAM stack surgery, just one config line.
#
# Idempotent: strips any existing `deny =` setting first so reruns
# produce the same file rather than appending duplicates.
set -euo pipefail

CONF=/etc/security/faillock.conf

# faillock.conf ships with Arch's pam package; if it's missing, that's
# a pretty unusual state — bail loud rather than silently creating it.
if [ ! -f "$CONF" ]; then
  echo "Expected $CONF to exist (shipped by pam). Aborting." >&2
  exit 1
fi

sed -i '/^[[:space:]]*deny[[:space:]]*=/d' "$CONF"
echo 'deny = 0' >> "$CONF"
