# cloudflare — Cloudflare Tunnel for serving aviary at a custom
# domain (e.g. media.example.com) without port-forwarding the NAS.
# Optional service: tailscale-only households can skip it.
#
# Use case: family members who don't live in this house and
# therefore can't reach the tailnet need a public URL to access
# the household library. Cloudflare Tunnel gives that public URL
# without exposing the NAS directly to the internet.
#
# Walk-through for the user's part (the bits depot CAN'T do)
# lives in install_prompt's preamble — see that for the exact
# Cloudflare dashboard steps. The short version:
#   1. one.dash.cloudflare.com → Networks → Tunnels → Create
#   2. Copy the `--token <long-string>` value from the install
#      command Cloudflare shows you. Paste it into depot's prompt.
#   3. Configure a Public Hostname route in the same tunnel UI:
#      your domain → HTTP localhost:4000. Cloudflare creates the
#      DNS record automatically.
#
# What depot DOES do:
#   - Pulls + runs the cloudflared docker image with TUNNEL_TOKEN
#     in env.
#   - Persists the token + public hostname so re-running install
#     is a no-op question-wise.
#   - Hands the public hostname to aviary so PHX_HOST + URL
#     generation point at the custom domain instead of the tailnet
#     URL.
#
# Tailnet access still works alongside this; tailnet-internal
# users keep accessing aviary via the .ts.net URL if they want.

module Cloudflare
  CONFIG_DIR             = File.join(Dir.home, "hdds/.config/cloudflared")
  TOKEN_FILE             = File.join(CONFIG_DIR, "token")
  HOSTNAME_FILE          = File.join(CONFIG_DIR, "hostname")
  JELLYFIN_HOSTNAME_FILE = File.join(CONFIG_DIR, "jellyfin_hostname")

  def self.install_prompt
    # Per-value caching: each prompt is asked only if its
    # corresponding cache file is missing/empty. This lets us add new
    # prompts (like the Jellyfin hostname) and have them fire on the
    # next `depot install` even when the older prompts are already
    # cached. The previous all-or-nothing `return if cached?` skipped
    # the whole block whenever the token existed, hiding any new
    # follow-up question.
    cached = cached_prompts

    token =
      if !cached[:cloudflare_tunnel_token].empty?
        cached[:cloudflare_tunnel_token]
      else
        prompt(
          preamble: <<~TEXT.chomp,
            Cloudflare Tunnel token (optional):
              Enables public HTTPS access to aviary at a domain you own
              (e.g. https://media.example.com). Primarily for family
              members who aren't on this tailnet — they need a public URL.
              Tailnet-only households can leave this blank.

              Prerequisite: a domain whose DNS Cloudflare manages.
              Free Cloudflare account is enough; if your registrar
              isn't Cloudflare, move the nameservers there first or
              this won't work.

              To get the token:
                1. Sign in at https://one.dash.cloudflare.com
                2. Networks → Overview → Manage tunnels
                3. Create a new cloudflared tunnel
                4. Name it (e.g. "aviary"), Save
                5. On the install page that follows, copy the long
                   string after `--token ` from either shell command —
                   that's the value to paste below.
                6. Click Next → Route Traffic, configure:
                     Subdomain: blank (apex) or "watch" / etc.
                     Domain:    pick your domain from the dropdown
                     Service:   Type HTTP, URL http://localhost:4000
                   Complete setup. DNS is created automatically.

              Leave blank to skip (tailscale-only mode).
          TEXT
          question: "Tunnel token",
        )
      end

    hostname =
      if token.empty?
        ""
      elsif !cached[:cloudflare_public_hostname].empty?
        cached[:cloudflare_public_hostname]
      else
        prompt(
          preamble: <<~TEXT.chomp,
            Public hostname:
              No https://, no trailing slash.
          TEXT
          question: "Public hostname",
        )
      end

    jellyfin_hostname =
      if token.empty? || hostname.empty?
        ""
      elsif !cached[:cloudflare_jellyfin_hostname].empty?
        cached[:cloudflare_jellyfin_hostname]
      else
        prompt(
          preamble: <<~TEXT.chomp,
            Jellyfin public hostname (optional):
              Lets family streams reach Jellyfin from outside the
              tailnet. Add a SECOND Public Hostname to the same
              tunnel in Cloudflare:
                Subdomain: watch (or media / stream / etc.)
                Domain:    same as above
                Service:   Type HTTP, URL http://localhost:8096
              Then enter the resulting full hostname below.
              Leave blank to keep streaming tailnet-only.
          TEXT
          question: "Jellyfin hostname",
        )
      end

    # NOTE: do NOT mkdir CONFIG_DIR or persist files here. CONFIG_DIR
    # is under ~/hdds, which doesn't exist yet — storage's install
    # hasn't created the ZFS pool mountpoint. Writing here creates
    # ~/hdds as a regular directory and storage's `zpool create`
    # fails with "mountpoint exists and is not empty." Persistence
    # happens in install() instead, after storage has run.
    #
    # Trade-off accepted: if depot install aborts before cloudflare's
    # install runs (e.g., a storage or jellyfin failure), the token
    # entered this run is lost and the user re-pastes on retry.

    {
      cloudflare_tunnel_token:      token,
      cloudflare_public_hostname:   hostname,
      cloudflare_jellyfin_hostname: jellyfin_hostname,
    }
  end

  def self.install(prompts)
    token             = prompts[:cloudflare_tunnel_token].to_s
    hostname          = prompts[:cloudflare_public_hostname].to_s
    jellyfin_hostname = prompts[:cloudflare_jellyfin_hostname].to_s

    if token.empty?
      puts "  skipped: no tunnel token (tailscale-only mode)"
      return
    end

    FileUtils.mkdir_p(CONFIG_DIR)
    File.write(TOKEN_FILE, token + "\n", perm: 0o600)
    File.write(HOSTNAME_FILE, hostname + "\n", perm: 0o600) unless hostname.empty?
    File.write(JELLYFIN_HOSTNAME_FILE, jellyfin_hostname + "\n", perm: 0o600) unless jellyfin_hostname.empty?

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
    read_optional_file(HOSTNAME_FILE)
  end

  # Cloudflare-routed Jellyfin hostname — read by Aviary.bring_up so
  # JELLYFIN_PUBLIC_URL points at the publicly-accessible custom
  # domain. Family members not on the tailnet load HLS chunks from
  # there. Falls back to the tailnet URL when not configured.
  def self.jellyfin_public_hostname
    read_optional_file(JELLYFIN_HOSTNAME_FILE)
  end

  def self.read_optional_file(path)
    return nil unless File.file?(path)
    v = File.read(path).strip
    v.empty? ? nil : v
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
    token             = File.file?(TOKEN_FILE) ? File.read(TOKEN_FILE).strip : ""
    hostname          = File.file?(HOSTNAME_FILE) ? File.read(HOSTNAME_FILE).strip : ""
    jellyfin_hostname = File.file?(JELLYFIN_HOSTNAME_FILE) ? File.read(JELLYFIN_HOSTNAME_FILE).strip : ""
    {
      cloudflare_tunnel_token:      token,
      cloudflare_public_hostname:   hostname,
      cloudflare_jellyfin_hostname: jellyfin_hostname,
    }
  end
end
