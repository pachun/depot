#!/usr/bin/env bash
# Enable NetworkManager so the new system has networking on first boot.
# DHCP handles the wired connection without further config; wifi (for
# the Framework test bed) goes through nmtui after boot.
set -euo pipefail

systemctl enable NetworkManager.service
