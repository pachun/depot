# gluetun — ProtonVPN WireGuard client. qBittorrent shares gluetun's
# network namespace, so every byte qBit sends or receives goes through
# ProtonVPN; nothing else (Jellyfin, Sonarr/Radarr API calls, pacman,
# Tailscale) pays VPN overhead.
#
# NAT-PMP port forwarding (you ticked it on the ProtonVPN config page)
# gives qBittorrent full inbound peer capacity. Gluetun renews the
# forwarded port every ~60s and the qbit-port-sync.sh helper (installed
# below into the gluetun bind-mount; called by gluetun via
# VPN_PORT_FORWARDING_UP_COMMAND) pushes the new port into
# qBittorrent's listening-port setting.

module Gluetun
  CONFIG_DIR = File.join(Dir.home, "hdds/.config/gluetun")

  # POSIX sh (runs inside gluetun's BusyBox alpine container, NOT on
  # the host — no bashisms, no GNU-only flags). Auth: qBit's LSIO
  # image ships with "Bypass authentication for clients on localhost"
  # on, and qBit shares gluetun's netns so our requests look like
  # 127.0.0.1 to it — no creds needed.
  PORT_SYNC_SH = <<~SH
    #!/bin/sh
    set -eu

    PORT="$1"
    [ -z "$PORT" ] && exit 0

    # qBittorrent may still be initializing the WebUI when this fires
    # on the first tunnel-up + port-allocation race. Wait up to 60s.
    tries=30
    while [ "$tries" -gt 0 ]; do
      wget -q --spider http://localhost:8080/api/v2/app/version 2>/dev/null && break
      sleep 2
      tries=$((tries - 1))
    done

    wget -qO- \\
      --post-data="json={\\"listen_port\\":$PORT}" \\
      http://localhost:8080/api/v2/app/setPreferences >/dev/null
  SH

  def self.install_prompt
    cached = read_env_file(File.join(CONFIG_DIR, "wg.env"))
    if !cached["WIREGUARD_PRIVATE_KEY"].to_s.empty? && !cached["WIREGUARD_ADDRESSES"].to_s.empty?
      return { wireguard_config: {
        private_key: cached["WIREGUARD_PRIVATE_KEY"],
        addresses:   cached["WIREGUARD_ADDRESSES"],
      } }
    end
    conf = prompt(
      question:   "Path to ProtonVPN WireGuard .conf",
      parse:      :wireguard_conf,
      completion: :filename,
    )
    { wireguard_config: conf }
  end

  def self.install(prompts)
    FileUtils.mkdir_p(CONFIG_DIR)

    # sudo install because gluetun runs as root inside the container,
    # so any file it created in the bind-mount comes back root-owned
    # on the host; without sudo a re-install from the daily-driver
    # user can't overwrite it.
    tmp = "/tmp/qbit-port-sync.sh.#{Process.pid}"
    File.write(tmp, PORT_SYNC_SH)
    sudo!("install -m 0755 #{tmp} #{CONFIG_DIR}/qbit-port-sync.sh")
    File.delete(tmp)

    # Persist wg.env so re-runs without the .conf path still work.
    write_env_file(File.join(CONFIG_DIR, "wg.env"),
      "WIREGUARD_PRIVATE_KEY" => prompts[:wireguard_config][:private_key],
      "WIREGUARD_ADDRESSES"   => prompts[:wireguard_config][:addresses],
    )

    cleanup_stale_container("gluetun")

    # 8080 (qBit WebUI) + 6881 (BitTorrent peer port) are published
    # from gluetun. qBittorrent shares the netns and has no port
    # mapping of its own.
    free_tailscale_port(8080)

    compose_up!("gluetun", env: {
      "TZ"                    => `timedatectl show -p Timezone --value`.strip,
      "WIREGUARD_PRIVATE_KEY" => prompts[:wireguard_config][:private_key],
      "WIREGUARD_ADDRESSES"   => prompts[:wireguard_config][:addresses],
    })
  end

  def self.update
    wg = read_env_file(File.join(CONFIG_DIR, "wg.env"))
    free_tailscale_port(8080)
    compose_up!("gluetun", env: {
      "TZ"                    => `timedatectl show -p Timezone --value`.strip,
      "WIREGUARD_PRIVATE_KEY" => wg["WIREGUARD_PRIVATE_KEY"].to_s,
      "WIREGUARD_ADDRESSES"   => wg["WIREGUARD_ADDRESSES"].to_s,
    })
  end

  def self.summary
    port_file = File.join(CONFIG_DIR, "forwarded_port")
    if File.exist?(port_file) && !File.read(port_file).strip.empty?
      puts "Gluetun:        VPN up — qBit peer port: #{File.read(port_file).strip}"
    else
      puts "Gluetun:        VPN starting — check `docker logs gluetun`"
    end
  end
end
