#!/usr/bin/env bash
# Grant sudo to anyone in the `wheel` group. Drop-in under sudoers.d so
# we never touch the main /etc/sudoers. Validated with visudo -cf
# before being trusted.
#
# SETENV tag matters: Arch's default sudoers has `Defaults env_reset`,
# which silently strips env vars passed via `sudo VAR=val cmd`. Without
# SETENV, every services/configure/*/configure.sh call that does
# `sudo PUID=... TZ=... DEPOT_USER_HOME=... docker-compose up -d` loses
# those vars — docker-compose then substitutes empty / wrong values
# into bind mount paths and container env (TZ falls back to UTC,
# gluetun's WIREGUARD_PRIVATE_KEY arrives empty, bind mounts vanish).
# SETENV explicitly allows wheel users to override sudo's env reset on
# the command line, which fixes all of those silently. Single-user NAS
# where wheel members already have full sudo anyway — no real
# privilege expansion.
#
# NB: this does NOT cover HOME. Sudo has hardcoded special handling
# for HOME (set to target-user's home regardless of SETENV / command-
# line VAR=val / --preserve-env=HOME — only `sudo -E` preserves it,
# which is overkill). depot side-steps the issue by using
# `DEPOT_USER_HOME` for compose-substitution instead of `HOME`.
set -euo pipefail

echo '%wheel ALL=(ALL:ALL) SETENV: ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel
