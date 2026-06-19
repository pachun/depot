# docker — install Docker, enable the daemon, and put this user in
# the docker group so the per-service compose-ups (which use sudo
# anyway for SETENV env passthrough) work and bare `docker` commands
# work after a re-login.

module Docker
  def self.install_prompt
    {}
  end

  def self.install(prompts)
    ensure_pacman_installed("docker", "docker-compose")
    sudo!("systemctl enable --now docker.service")
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
end
