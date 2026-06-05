# Sourced by bootstrap.sh's frontload loop and by 040-create-user's
# create.sh. Idempotent — skips already-collected inputs, so the second
# source (from create.sh) is a no-op. The mismatched-password retry
# loop lives here so nothing else has to know about it.
if [ -z "${INSTALL_USERNAME:-}" ]; then
  read -rp "username: " INSTALL_USERNAME </dev/tty
  export INSTALL_USERNAME
fi

if [ -z "${INSTALL_USER_PASSWORD:-}" ]; then
  while :; do
    read -srp "password: " INSTALL_USER_PASSWORD </dev/tty
    echo
    read -srp "confirm password: " _CONFIRM </dev/tty
    echo
    if [ "$INSTALL_USER_PASSWORD" = "$_CONFIRM" ]; then
      break
    fi
    echo "Passwords don't match. Try again."
  done
  unset _CONFIRM
  export INSTALL_USER_PASSWORD
fi
