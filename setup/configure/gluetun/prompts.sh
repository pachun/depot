# Gluetun's prompts — collect the ProtonVPN WireGuard config qBittorrent's
# tunnel will use. Sourced from configure.sh's Phase 1 so the prompt
# fires before anything is brought up.
#
# Persisted to ~/library/.config/gluetun/wg.env so re-runs of
# configure.sh skip the prompt once the creds are saved.
#
# How to get the .conf:
#   1. Sign in at https://account.protonvpn.com/downloads
#   2. WireGuard configuration:
#        - tick "NAT-PMP (Port Forwarding)" (required for inbound peers)
#        - pick a P2P-capable server
#        - Create + Download → you get a .conf file
#   3. scp it onto this box, e.g.
#        scp ~/Downloads/proton.conf nick@framework-depot:/tmp/
WG_ENV="$HOME/library/.config/gluetun/wg.env"
mkdir -p "$(dirname "$WG_ENV")"

if [ -f "$WG_ENV" ]; then
  # shellcheck disable=SC1090
  source "$WG_ENV"
fi

if [ -z "${WIREGUARD_PRIVATE_KEY:-}" ] || [ -z "${WIREGUARD_ADDRESSES:-}" ]; then
  read -rp "Path to ProtonVPN WireGuard .conf: " WG_CONF </dev/tty

  if [ ! -f "$WG_CONF" ]; then
    echo "No file at $WG_CONF" >&2
    exit 1
  fi

  # PrivateKey + Address live in the [Interface] section. Strip the
  # `Key = ` prefix and any whitespace.
  WIREGUARD_PRIVATE_KEY=$(grep -E '^PrivateKey' "$WG_CONF" | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
  WIREGUARD_ADDRESSES=$(grep -E '^Address'    "$WG_CONF" | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')

  if [ -z "$WIREGUARD_PRIVATE_KEY" ] || [ -z "$WIREGUARD_ADDRESSES" ]; then
    echo "Could not extract PrivateKey/Address from $WG_CONF" >&2
    exit 1
  fi

  umask 077
  {
    echo "WIREGUARD_PRIVATE_KEY=$WIREGUARD_PRIVATE_KEY"
    echo "WIREGUARD_ADDRESSES=$WIREGUARD_ADDRESSES"
  } > "$WG_ENV"
fi

export WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES
