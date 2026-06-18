# autologin — auto-login the install user on tty1 so an unattended
# reboot (UPS event, power blip, kernel update) brings the box all the
# way back up without needing a keyboard. NAS lives somewhere without
# peripherals; security boundary is the LAN + tailscale, not the local
# TTY prompt. Service-level recovery already handled by every
# docker-compose's `restart: unless-stopped` + docker.service. All this
# adds is the missing "skip the TTY login" link.
#
# Override is a systemd drop-in so a pacman update of systemd doesn't
# blow it away. Idempotent.

module Autologin
  OVERRIDE_DIR  = "/etc/systemd/system/getty@tty1.service.d"
  OVERRIDE_FILE = "#{OVERRIDE_DIR}/autologin.conf"

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    desired = <<~CONF
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin #{ENV["USER"]} --noclear %I $TERM
    CONF
    current = `sudo cat #{OVERRIDE_FILE} 2>/dev/null`
    return if current == desired

    sudo!("mkdir -p #{OVERRIDE_DIR}")
    tmp = "/tmp/autologin.conf.#{Process.pid}"
    File.write(tmp, desired)
    sudo!("install -m 0644 #{tmp} #{OVERRIDE_FILE}")
    File.delete(tmp)
    sudo!("systemctl daemon-reload")
  end

  def self.update
  end

  def self.summary
  end
end
