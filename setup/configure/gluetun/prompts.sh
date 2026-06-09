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

  # PrivateKey + Address live in the [Interface] section. Strip CRLF
  # (Proton's downloaded .conf is sometimes CRLF, depending on the
  # browser), then strip the `Key = ` prefix and any whitespace.
  #
  # `[^=]*=` not `.*=` because base64 keys end in `=` padding and a
  # greedy `.*=` eats the whole value.
  WG_CONF_NORMALIZED=$(tr -d '\r' < "$WG_CONF")
  WIREGUARD_PRIVATE_KEY=$(echo "$WG_CONF_NORMALIZED" | grep -iE '^[[:space:]]*PrivateKey' | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
  WIREGUARD_ADDRESSES=$(echo "$WG_CONF_NORMALIZED"   | grep -iE '^[[:space:]]*Address'    | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')

  if [ -z "$WIREGUARD_PRIVATE_KEY" ] || [ -z "$WIREGUARD_ADDRESSES" ]; then
    echo "Could not extract PrivateKey/Address from $WG_CONF" >&2
    echo "--- first 12 lines of the file (PrivateKey value will be masked) ---" >&2
    head -12 "$WG_CONF" | sed -E 's/^([[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*).*/\1<MASKED>/I' >&2
    echo "--- end ---" >&2
    exit 1
  fi
fi

# Strip IPv6 from WIREGUARD_ADDRESSES. ProtonVPN's Address line is
# dual-stack (e.g. "10.2.0.2/32, 2a07:b944::2:2/128"); gluetun's
# default mode doesn't enable IPv6 inside the container, so when it
# sees an IPv6 address it tries to look up an IPv6 default route in
# the netns, finds none (Docker IPv6 is off by default), and crashes
# with `default route not found`. Keep only the IPv4 entry.
#
# Done outside the prompt branch so re-runs with a stale wg.env (one
# written before this sanitize step existed) get fixed up too.
WIREGUARD_ADDRESSES=$(echo "$WIREGUARD_ADDRESSES" | cut -d, -f1 | tr -d '[:space:]')

# Re-persist after sanitize so the wg.env on disk matches the value
# we'll actually pass to gluetun.
umask 077
{
  echo "WIREGUARD_PRIVATE_KEY=$WIREGUARD_PRIVATE_KEY"
  echo "WIREGUARD_ADDRESSES=$WIREGUARD_ADDRESSES"
} > "$WG_ENV"

export WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES
