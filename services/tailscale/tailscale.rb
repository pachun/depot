# tailscale — install the tailscale daemon and authenticate this box
# into the tailnet. Auth key collected via install_prompt; once a box
# is authenticated, subsequent installs see `tailscale status` working
# and skip the `tailscale up`.

module Tailscale
  TAILSCALE_ENV = File.join(Dir.home, "hdds/.config/depot/tailscale.env")

  def self.install_prompt
    if File.exist?(TAILSCALE_ENV)
      cached = read_env_file(TAILSCALE_ENV)["TAILSCALE_AUTH_KEY"].to_s
      return { tailscale_auth_key: cached } unless cached.empty?
    end
    if system("sudo tailscale status", out: File::NULL, err: File::NULL)
      return { tailscale_auth_key: "" }
    end

    key = prompt(
      preamble: <<~TEXT.chomp,
        Tailscale auth key:
          1. Open https://login.tailscale.com/admin/settings/keys
          2. Click "Generate auth key"
          3. Name the key
          4. Click "Generate Key"
          5. Copy the key and paste below
      TEXT
      question: "Auth key",
      secret:   true,
    )
    { tailscale_auth_key: key }
  end

  def self.install(prompts)
    ensure_pacman_installed("tailscale")
    sudo!("systemctl enable --now tailscaled.service")
    write_env_file(TAILSCALE_ENV, "TAILSCALE_AUTH_KEY" => prompts[:tailscale_auth_key])

    if system("sudo tailscale status", out: File::NULL, err: File::NULL)
      return
    end

    key = prompts[:tailscale_auth_key]
    if key.to_s.empty?
      sudo!("tailscale up")
    else
      sudo!("tailscale up --auth-key=#{shellescape(key)}")
    end
  end

  def self.update
  end

  def self.summary
    fqdn_line = `tailscale status --json 2>/dev/null`
    return if fqdn_line.empty?
    fqdn = JSON.parse(fqdn_line).dig("Self", "DNSName").to_s.chomp(".") rescue ""
    puts "Tailnet:        ssh #{ENV["USER"]}@#{fqdn}" unless fqdn.empty?
  end
end
