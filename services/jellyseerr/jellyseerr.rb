# jellyseerr — TMDB-style discovery and request UI. Browse trending
# movies/shows, click "Request", Jellyseerr hands it to the right arr
# (Sonarr for shows, Radarr for movies), the arr finds and downloads
# it, Jellyfin scans it in. Uses Jellyfin's user accounts so login is
# unified.
#
# First-run bootstrap: adopt the Jellyfin admin user, wire Sonarr and
# Radarr as media backends. Update: just docker-compose up -d.

module Jellyseerr
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/jellyseerr")
  SETTINGS_JSON  = File.join(CONFIG_DIR, "settings.json")
  LOCAL_PORT     = 5055
  TAILSCALE_PORT = 5055
  BASE_URL       = "http://localhost:5055"

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p(CONFIG_DIR)
    cleanup_stale_container("jellyseerr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("jellyseerr", env: {
      "TZ" => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    wait_for_http("#{BASE_URL}/api/v1/status", timeout: 30)

    status = http_get_json("#{BASE_URL}/api/v1/status") || {}
    if status["initialized"] == true
      puts "  already initialized — skipping wizard"
      return
    end

    puts "Bootstrapping Jellyseerr..."
    bootstrap(prompts[:admin_username], prompts[:admin_password])
  end

  def self.update
    cleanup_stale_container("jellyseerr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("jellyseerr", env: {
      "TZ" => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Jellyseerr:     #{url}" unless url.empty?
  end

  # ============================================================
  # Bootstrap
  # ============================================================

  # /api/v1/auth/jellyfin both creates the Jellyseerr admin and wires
  # the Jellyfin connection in one call. Cookie returned is needed
  # for the subsequent settings POSTs.
  def self.bootstrap(admin_user, admin_pass)
    body = { "hostname" => "host.docker.internal", "port" => 8096,
             "useSsl" => false, "username" => admin_user,
             "password" => admin_pass, "urlBase" => "" }
    resp = http(:post, "#{BASE_URL}/api/v1/auth/jellyfin", body: body)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/auth/jellyfin failed: #{resp&.code} #{resp&.body.to_s[0, 200]}"
      return
    end

    # Build the Cookie header from every Set-Cookie line. Using
    # get_fields() rather than [] because [] joins multi-line
    # Set-Cookie with ", " — and cookies contain commas in date
    # attributes (expires=Mon, 09 Jun 2025 ...), so splitting on
    # comma mangles the session cookie. Each Set-Cookie is its own
    # array entry; we just want the name=value part before the first
    # semicolon.
    cookies = (resp.get_fields("Set-Cookie") || []).map { |c| c.split(";").first.strip }
    if cookies.empty?
      puts "  WARN: jellyseerr auth response had no Set-Cookie — bootstrap can't authenticate the rest"
      return
    end
    cookie_header = cookies.join("; ")
    headers = { "Cookie" => cookie_header }

    main_resp = http(:post, "#{BASE_URL}/api/v1/settings/main",
                     body: { "initialized" => true }, headers: headers)
    if main_resp.nil? || !main_resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/settings/main failed: #{main_resp&.code} #{main_resp&.body.to_s[0, 200]}"
      return
    end

    if (sonarr_key = Sonarr.api_key)
      http(:post, "#{BASE_URL}/api/v1/settings/sonarr", headers: headers, body: {
        "name" => "Sonarr", "hostname" => "host.docker.internal", "port" => 8989,
        "useSsl" => false, "apiKey" => sonarr_key,
        "activeProfileId" => 4, "activeProfileName" => "HD-1080p",
        "rootFolder" => "/shows", "isDefault" => true,
        "externalUrl" => "", "syncEnabled" => true, "preventSearch" => false,
      })
    end

    if (radarr_key = Radarr.api_key)
      http(:post, "#{BASE_URL}/api/v1/settings/radarr", headers: headers, body: {
        "name" => "Radarr", "hostname" => "host.docker.internal", "port" => 7878,
        "useSsl" => false, "apiKey" => radarr_key,
        "activeProfileId" => 4, "activeProfileName" => "HD-1080p",
        "rootFolder" => "/movies", "isDefault" => true,
        "externalUrl" => "", "minimumAvailability" => "released",
        "syncEnabled" => true, "preventSearch" => false,
      })
    end

    puts "  wizard complete + Jellyfin/Sonarr/Radarr wired"
  end

  # Returns the Jellyseerr API key for cross-service harvest (Aviary
  # reads it from settings.json).
  def self.api_key
    return nil unless File.file?(SETTINGS_JSON) && File.size(SETTINGS_JSON) > 0
    JSON.parse(File.read(SETTINGS_JSON)).dig("main", "apiKey")
  rescue
    nil
  end
end
