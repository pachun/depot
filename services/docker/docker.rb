# docker — install Docker, enable the daemon, and put this user in
# the docker group so the per-service compose-ups (which use sudo
# anyway for SETENV env passthrough) work and bare `docker` commands
# work after a re-login.

module Docker
  DROPIN_DIR           = "/etc/systemd/system/docker.service.d"
  ZFS_WAIT_DROPIN_FILE = "#{DROPIN_DIR}/wait-for-zfs.conf"
  ZFS_WAIT_DROPIN_BODY = <<~CONF
    [Unit]
    After=zfs-mount.service zfs-import-cache.service
    Requires=zfs-mount.service
  CONF
  DNS_WAIT_SCRIPT      = "/usr/local/lib/depot/wait-for-dns.sh"
  DNS_WAIT_DROPIN_FILE = "#{DROPIN_DIR}/wait-for-dns.conf"
  DNS_WAIT_DROPIN_BODY = <<~CONF
    [Unit]
    After=NetworkManager.service tailscaled.service

    [Service]
    ExecStartPre=#{DNS_WAIT_SCRIPT}
  CONF

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    ensure_pacman_installed("docker", "docker-compose")
    sudo!("systemctl enable --now docker.service")
    ensure_waits_for_zfs
    ensure_waits_for_dns
    if `id -nG #{ENV["USER"]}`.split.include?("docker")
      return
    end
    sudo!("usermod -aG docker #{ENV["USER"]}")
  end

  def self.update
    # The daemon itself updates with pacman -Syu at the OS level; the
    # only script-time work is keeping the boot-ordering dropins current.
    ensure_waits_for_zfs
    ensure_waits_for_dns
  end

  def self.summary
  end

  # systemd dropin: tell docker.service to wait for the ZFS mount
  # before starting. Without this, on boot docker and zfs-mount.service
  # race — if docker wins, it starts containers against unmounted
  # bind paths under ~/hdds/, docker auto-creates empty squatter
  # directories, and ZFS can no longer mount onto the now-non-empty
  # path. Containers come up with empty configs (Jellyfin has no
  # users, sabnzbd has no creds, etc.) and login breaks.
  #
  # `After=` orders without hard-failing if ZFS isn't installed.
  # `Requires=` is what makes docker actually wait — without it,
  # `After=` only sequences IF the unit is also being started, which
  # systemd skips during normal boot when nothing else pulls in
  # zfs-mount.service.
  def self.ensure_waits_for_zfs
    ensure_dropin(ZFS_WAIT_DROPIN_FILE, ZFS_WAIT_DROPIN_BODY)
  end

  # systemd dropin: hold docker.service until /etc/resolv.conf names a
  # resolver. Docker copies that file into each container exactly once,
  # at container start, and host-networked containers (jellyfin,
  # cloudflared) have no per-container `dns:` override to fall back on.
  # After a whole-office power cut the NAS reaches network-online.target
  # before the router has answered DHCP and before tailscaled has
  # rewritten resolv.conf, so on 2026-11-04 every container started
  # with no upstream resolver and could not look up a single name.
  # The wait gives up after a minute so a missing router never keeps
  # Docker down entirely.
  def self.ensure_waits_for_dns
    sudo!("mkdir -p #{File.dirname(DNS_WAIT_SCRIPT)}")
    install_root_file(DNS_WAIT_SCRIPT,
      from: File.join(__dir__, "wait-for-dns.sh"), mode: "0755")
    ensure_dropin(DNS_WAIT_DROPIN_FILE, DNS_WAIT_DROPIN_BODY)
  end

  # Idempotent: re-runs no-op when the dropin is already in place.
  def self.ensure_dropin(file, body)
    current = `sudo cat #{file} 2>/dev/null`
    return if current == body

    sudo!("mkdir -p #{DROPIN_DIR}")
    install_root_file(file, content: body)
    sudo!("systemctl daemon-reload")
  end
end
