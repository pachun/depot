#!/bin/sh
set -eu

resolver_file=/etc/resolv.conf
patience_seconds=60

has_a_resolver() {
  grep -q '^nameserver' "$resolver_file" 2>/dev/null
}

waited=0
until has_a_resolver; do
  if [ "$waited" -ge "$patience_seconds" ]; then
    echo "No resolver listed in $resolver_file after ${patience_seconds}s; starting Docker anyway" >&2
    exit 0
  fi
  sleep 1
  waited=$((waited + 1))
done
