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
#
# Sharing the namespace has one trap: a gluetun restart leaves
# qBittorrent stranded in the old namespace, unreachable but "healthy".
# A systemd timer runs restart-qbittorrent-after-gluetun.sh every
# minute to restart qBittorrent whenever gluetun has started after it.

module Gluetun
  CONFIG_DIR = File.join(Dir.home, "hdds/.config/gluetun")
  QBIT_RESTART_UNIT   = "restart-qbittorrent-after-gluetun"
  QBIT_RESTART_SCRIPT = "/usr/local/lib/depot/#{QBIT_RESTART_UNIT}.sh"
  SYSTEMD_UNIT_DIR    = "/etc/systemd/system"

  QBIT_RESTART_SERVICE = <<~UNIT
    [Unit]
    Description=Restart qBittorrent when gluetun has restarted
    After=docker.service
    Requires=docker.service

    [Service]
    Type=oneshot
    ExecStart=#{QBIT_RESTART_SCRIPT}
  UNIT

  QBIT_RESTART_TIMER = <<~UNIT
    [Unit]
    Description=Check every minute whether qBittorrent must rejoin gluetun's namespace

    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=1min

    [Install]
    WantedBy=timers.target
  UNIT

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

    pk = prompt(
      preamble: <<~TEXT.chomp,
        ProtonVPN WireGuard:
          Open your downloaded .conf — or grab one at
          https://account.protonvpn.com/downloads if you haven't
          already. Two values from the [Interface] section go here:
          paste the value after "PrivateKey = " first, then the
          value after "Address = " on the next prompt.
      TEXT
      question: "PrivateKey",
    )

    addr = prompt(question: "Address")

    # IPv4 only — gluetun's default mode doesn't enable IPv6 inside
    # the container, and a dual-stack Address line crashes it.
    # ProtonVPN .conf files often have "10.x.x.x/32, fe80::.../64";
    # take the first comma-separated segment.
    addr = addr.split(",").first.strip

    { wireguard_config: { private_key: pk, addresses: addr } }
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
    keep_qbittorrent_in_gluetuns_namespace
  end

  def self.update
    wg = read_env_file(File.join(CONFIG_DIR, "wg.env"))
    free_tailscale_port(8080)
    compose_up!("gluetun", env: {
      "TZ"                    => `timedatectl show -p Timezone --value`.strip,
      "WIREGUARD_PRIVATE_KEY" => wg["WIREGUARD_PRIVATE_KEY"].to_s,
      "WIREGUARD_ADDRESSES"   => wg["WIREGUARD_ADDRESSES"].to_s,
    })
    keep_qbittorrent_in_gluetuns_namespace
  end

  def self.keep_qbittorrent_in_gluetuns_namespace
    sudo!("mkdir -p #{File.dirname(QBIT_RESTART_SCRIPT)}")
    install_root_file(QBIT_RESTART_SCRIPT,
      from: File.join(__dir__, "restart-qbittorrent-after-gluetun.sh"), mode: "0755")
    install_root_file("#{SYSTEMD_UNIT_DIR}/#{QBIT_RESTART_UNIT}.service", content: QBIT_RESTART_SERVICE)
    install_root_file("#{SYSTEMD_UNIT_DIR}/#{QBIT_RESTART_UNIT}.timer", content: QBIT_RESTART_TIMER)
    sudo!("systemctl daemon-reload")
    sudo!("systemctl enable --now #{QBIT_RESTART_UNIT}.timer")
    sudo!("systemctl start #{QBIT_RESTART_UNIT}.service")
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
