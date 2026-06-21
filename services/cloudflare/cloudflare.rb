# cloudflare — Cloudflare Tunnel for serving aviary at a custom
# domain (e.g. pachulski.tv) without port-forwarding the NAS.
#
# Setup, the parts depot CAN'T do:
#   1. Go to Cloudflare Zero Trust → Networks → Tunnels → Create
#      a tunnel. Connector type = Cloudflared. Name = aviary.
#   2. Save. Cloudflare shows you a long `--token <...>` string in
#      the install command. Copy that token; depot's prompt asks
#      for it.
#   3. On the "Public Hostname" page, add a route:
#         Domain:    pachulski.tv
#         Subdomain: (blank for apex; or "watch" / etc.)
#         Service:   HTTP, localhost:4000
#      Save. Cloudflare auto-creates the DNS for the domain.
#
# What depot DOES do:
#   - Pulls + runs the cloudflared docker image with TUNNEL_TOKEN
#     in env.
#   - Persists the token + public hostname so re-running install
#     is a no-op question-wise.
#   - Hands the public hostname to aviary so PHX_HOST + URL
#     generation point at pachulski.tv instead of the tailnet URL.
#
# Tailscale Funnel still works alongside this; tailnet-internal
# users keep accessing aviary via the .ts.net URL if they want.

module Cloudflare
  CONFIG_DIR    = File.join(Dir.home, "hdds/.config/cloudflared")
  TOKEN_FILE    = File.join(CONFIG_DIR, "token")
  HOSTNAME_FILE = File.join(CONFIG_DIR, "hostname")

  def self.install_prompt
    return cached_prompts if cached?

    token = prompt(
      preamble: <<~TEXT.chomp,
        Cloudflare Tunnel token:
          1. Cloudflare → Zero Trust → Networks → Tunnels
          2. Create a tunnel (connector type: Cloudflared, name: aviary)
          3. Copy the `--token ...` value shown in the install command
          4. Configure a Public Hostname: your domain → HTTP localhost:4000
          Leave blank to skip Cloudflare Tunnel entirely (tailscale-only).
      TEXT
      question: "Tunnel token",
      secret:   true,
    )

    hostname =
      if token.empty?
        ""
      else
        prompt(question: "Domain Name")
      end

    # Persist immediately, not in install(). Otherwise an unrelated
    # later-service failure (storage's pacman-key, gluetun's wg.conf,
    # whatever) leaves these prompts unsaved and the next retry asks
    # again — even though the user already entered them correctly.
    unless token.empty?
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(TOKEN_FILE, token + "\n", perm: 0o600)
      File.write(HOSTNAME_FILE, hostname + "\n", perm: 0o600) unless hostname.empty?
    end

    { cloudflare_tunnel_token: token, cloudflare_public_hostname: hostname }
  end

  def self.install(prompts)
    token    = prompts[:cloudflare_tunnel_token].to_s
    hostname = prompts[:cloudflare_public_hostname].to_s

    if token.empty?
      puts "  skipped: no tunnel token (tailscale-only mode)"
      return
    end

    FileUtils.mkdir_p(CONFIG_DIR)
    File.write(TOKEN_FILE, token + "\n", perm: 0o600)
    File.write(HOSTNAME_FILE, hostname + "\n", perm: 0o600) unless hostname.empty?

    bring_up(token)
  end

  def self.update
    return unless File.file?(TOKEN_FILE)
    token = File.read(TOKEN_FILE).strip
    return if token.empty?
    bring_up(token)
  end

  def self.summary
    return unless File.file?(HOSTNAME_FILE)
    hostname = File.read(HOSTNAME_FILE).strip
    return if hostname.empty?

    status = system("sudo docker ps --format '{{.Names}}' | grep -q '^cloudflared$'",
                    out: File::NULL, err: File::NULL) ? "up" : "DOWN"

    puts "Cloudflare:     https://#{hostname} (tunnel #{status})"
  end

  # ============================================================
  # Public hostname accessor — read by Aviary.bring_up so its
  # PHX_HOST / URL generation points at the custom domain when one
  # is configured, falling back to the tailscale URL otherwise.
  # ============================================================
  def self.public_hostname
    return nil unless File.file?(HOSTNAME_FILE)
    h = File.read(HOSTNAME_FILE).strip
    h.empty? ? nil : h
  end

  # ============================================================
  # Internals
  # ============================================================

  def self.bring_up(token)
    compose_up!("cloudflare", env: { "TUNNEL_TOKEN" => token })
  end

  def self.cached?
    File.file?(TOKEN_FILE) && !File.read(TOKEN_FILE).strip.empty?
  end

  def self.cached_prompts
    token    = File.file?(TOKEN_FILE) ? File.read(TOKEN_FILE).strip : ""
    hostname = File.file?(HOSTNAME_FILE) ? File.read(HOSTNAME_FILE).strip : ""
    { cloudflare_tunnel_token: token, cloudflare_public_hostname: hostname }
  end
end
