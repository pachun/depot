#!/usr/bin/env bash
# Enable sshd so the new system accepts SSH on first boot — the whole
# point of the headless NAS is to be reachable. openssh was already
# pacstrap'd by bootstrap.sh.
set -euo pipefail

systemctl enable sshd.service
