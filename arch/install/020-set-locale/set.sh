#!/usr/bin/env bash
# Generate the en_US.UTF-8 locale and set it as the default. Idempotent:
# sed only matches still-commented lines.
set -euo pipefail

sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
