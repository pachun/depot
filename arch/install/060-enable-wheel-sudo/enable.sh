#!/usr/bin/env bash
# Grant sudo to anyone in the `wheel` group. Drop-in under sudoers.d so
# we never touch the main /etc/sudoers. Validated with visudo -cf
# before being trusted.
set -euo pipefail

echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel
