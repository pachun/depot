#!/bin/sh
# Auto-sync the NAT-PMP forwarded port into qBittorrent's listening
# port setting. Called by gluetun's VPN_PORT_FORWARDING_UP_COMMAND
# whenever a port is allocated or rotates, so qBittorrent stays in
# sync with whatever ProtonVPN gives us this session — no manual paste
# into the WebUI required.
#
# Auth: qBittorrent's linuxserver image ships with "Bypass authentication
# for clients on localhost" enabled by default. Since qBittorrent shares
# gluetun's network namespace, our requests look like 127.0.0.1 to it —
# so we don't need credentials. If you ever turn that bypass off, this
# script will silently fail and you'll need to wire in username/password
# (qBittorrent /api/v2/auth/login → session cookie → setPreferences).
#
# Runs inside the gluetun container (alpine + BusyBox), so stick to
# POSIX sh / BusyBox utilities — no bashisms, no GNU-only flags.
set -eu

PORT="$1"
[ -z "$PORT" ] && exit 0

# qBittorrent may still be initializing the WebUI when this fires on
# the first tunnel-up + port-allocation race. Wait up to 60s for it.
tries=30
while [ "$tries" -gt 0 ]; do
  wget -q --spider http://localhost:8080/api/v2/app/version 2>/dev/null && break
  sleep 2
  tries=$((tries - 1))
done

wget -qO- \
  --post-data="json={\"listen_port\":$PORT}" \
  http://localhost:8080/api/v2/app/setPreferences >/dev/null
