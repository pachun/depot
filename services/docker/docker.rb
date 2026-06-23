# docker — install Docker, enable the daemon, and put this user in
# the docker group so the per-service compose-ups (which use sudo
# anyway for SETENV env passthrough) work and bare `docker` commands
# work after a re-login.

module Docker
  ZFS_WAIT_DROPIN_DIR  = "/etc/systemd/system/docker.service.d"
  ZFS_WAIT_DROPIN_FILE = "#{ZFS_WAIT_DROPIN_DIR}/wait-for-zfs.conf"
  ZFS_WAIT_DROPIN_BODY = <<~CONF
    [Unit]
    After=zfs-mount.service zfs-import-cache.service
    Requires=zfs-mount.service
  CONF

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    ensure_pacman_installed("docker", "docker-compose")
    sudo!("systemctl enable --now docker.service")
    ensure_waits_for_zfs
    if `id -nG #{ENV["USER"]}`.split.include?("docker")
      return
    end
    sudo!("usermod -aG docker #{ENV["USER"]}")
  end

  def self.update
    # Daemon. Nothing meaningful to update at script time — pacman -Syu
    # at the OS level is the real update path.
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
  #
  # Idempotent: re-runs no-op when the dropin is already in place.
  def self.ensure_waits_for_zfs
    current = `sudo cat #{ZFS_WAIT_DROPIN_FILE} 2>/dev/null`
    return if current == ZFS_WAIT_DROPIN_BODY

    sudo!("mkdir -p #{ZFS_WAIT_DROPIN_DIR}")
    tmp = "/tmp/wait-for-zfs.conf.#{Process.pid}"
    File.write(tmp, ZFS_WAIT_DROPIN_BODY)
    sudo!("install -m 0644 #{tmp} #{ZFS_WAIT_DROPIN_FILE}")
    File.delete(tmp)
    sudo!("systemctl daemon-reload")
  end
end
