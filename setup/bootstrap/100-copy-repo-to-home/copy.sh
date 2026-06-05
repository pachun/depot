#!/usr/bin/env bash
# Copy the depot repo (currently bind-mounted at /depot-installer from
# the live ISO) into the new user's ~/code/depot. After bootstrap.sh
# unmounts the bind, the repo at /depot-installer disappears, so we
# need a real copy somewhere persistent.
#
# Copy rather than move because /depot-installer is a bind mount —
# moving doesn't make sense across that boundary.
set -euo pipefail

DEST_DIR="/home/$INSTALL_USERNAME/code"
DEST="$DEST_DIR/depot"

mkdir -p "$DEST_DIR"

if [ ! -d "$DEST" ]; then
  cp -r /depot-installer "$DEST"
fi

chown -R "$INSTALL_USERNAME:$INSTALL_USERNAME" "$DEST_DIR"
