# Sourced by bootstrap.sh's frontload loop and by 030-set-hostname's
# set.sh. Idempotent — skips if INSTALL_HOSTNAME is already set, so the
# second source (from set.sh) is a no-op.
if [ -z "${INSTALL_HOSTNAME:-}" ]; then
  read -rp "hostname: " INSTALL_HOSTNAME </dev/tty
  export INSTALL_HOSTNAME
fi
