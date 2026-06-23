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
  # See sonarr.rb's TAILSCALE_PORT comment for the rationale: must
  # differ from LOCAL_PORT so the on-boot tailscaled bind doesn't
  # block the container's 0.0.0.0:PORT wildcard bind.
  TAILSCALE_PORT = 5056
  BASE_URL       = "http://localhost:5055"

  # Jellyseerr's MediaServerType enum (server/constants/server.ts):
  # 1=PLEX, 2=JELLYFIN, 3=EMBY, 4=NOT_CONFIGURED.
  MEDIA_SERVER_JELLYFIN = 2

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p(CONFIG_DIR)
    cleanup_stale_container("jellyseerr")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("jellyseerr", env: {
      "TZ" => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    # /api/v1/settings/public is the authoritative wizard-done signal.
    # Wait for the endpoint to come up first.
    wait_for_http("#{BASE_URL}/api/v1/settings/public", timeout: 30)

    if (http_get_json("#{BASE_URL}/api/v1/settings/public") || {})["initialized"] == true
      puts "  already initialized — skipping wizard"
      return
    end

    puts "Bootstrapping Jellyseerr..."
    bootstrap(prompts[:admin_username], prompts[:admin_password])
  end

  def self.update
    cleanup_stale_container("jellyseerr")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
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
  # Bootstrap (matches current fallenbagel/jellyseerr API surface;
  # rebuilt 2026-06-19 after the old flow broke with NO_ADMIN_USER)
  # ============================================================

  # 5 steps: auth → wire Sonarr → wire Radarr → mark initialized → set locale.
  def self.bootstrap(admin_user, admin_pass)
    cookie_header = create_admin_and_get_session(admin_user, admin_pass)
    return if cookie_header.nil?
    headers = { "Cookie" => cookie_header }

    wire_sonarr(headers) if Sonarr.api_key
    wire_radarr(headers) if Radarr.api_key

    return unless mark_initialized(headers)
    set_locale(headers)

    puts "  wizard complete + Jellyfin/Sonarr/Radarr wired"
  end

  # POST /api/v1/auth/jellyfin both creates the admin and connects
  # Jellyfin in one call. CRITICAL: serverType must be set (2=Jellyfin)
  # — without it, the endpoint throws NO_ADMIN_USER on a fresh
  # container even when the admin is being created. Returns the
  # Cookie header string to use on subsequent authenticated calls, or
  # nil on failure.
  def self.create_admin_and_get_session(admin_user, admin_pass)
    body = {
      "username"   => admin_user,
      "password"   => admin_pass,
      "hostname"   => "host.docker.internal",
      "port"       => 8096,
      "useSsl"     => false,
      "urlBase"    => "",
      "email"      => "",
      "serverType" => MEDIA_SERVER_JELLYFIN,
    }
    resp = http(:post, "#{BASE_URL}/api/v1/auth/jellyfin", body: body)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/auth/jellyfin failed: #{resp&.code} #{resp&.body.to_s[0, 200]}"
      return nil
    end

    # Each Set-Cookie is its own array entry via get_fields. Using
    # resp["Set-Cookie"] would join multiple cookies with ", " and
    # commas appear inside cookie attributes (expires=Mon, 09 Jun ...),
    # so splitting on comma would mangle the session cookie.
    cookies = (resp.get_fields("Set-Cookie") || []).map { |c| c.split(";").first.strip }
    if cookies.empty?
      puts "  WARN: jellyseerr auth response had no Set-Cookie — can't authenticate the rest"
      return nil
    end
    cookies.join("; ")
  end

  def self.wire_sonarr(headers)
    existing = http_get_json("#{BASE_URL}/api/v1/settings/sonarr", headers: headers) || []
    return if existing.any? { |s| s["name"] == "Sonarr" }

    body = {
      "name"                => "Sonarr",
      "hostname"            => "host.docker.internal",
      "port"                => 8989,
      "apiKey"              => Sonarr.api_key,
      "useSsl"              => false,
      "baseUrl"             => "",
      "activeProfileId"     => 4,
      "activeProfileName"   => "HD-1080p",
      "activeDirectory"     => "/shows",
      "tags"                => [],
      "is4k"                => false,
      "isDefault"           => true,
      "syncEnabled"         => true,
      "preventSearch"       => false,
      "tagRequests"         => false,
      "overrideRule"        => [],
      "seriesType"          => "standard",
      "animeSeriesType"     => "anime",
      "enableSeasonFolders" => true,
      "monitorNewItems"     => "all",
    }
    resp = http(:post, "#{BASE_URL}/api/v1/settings/sonarr", body: body, headers: headers)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/settings/sonarr failed: #{resp&.code} #{resp&.body.to_s[0, 200]}"
    end
  end

  def self.wire_radarr(headers)
    existing = http_get_json("#{BASE_URL}/api/v1/settings/radarr", headers: headers) || []
    return if existing.any? { |s| s["name"] == "Radarr" }

    body = {
      "name"                => "Radarr",
      "hostname"            => "host.docker.internal",
      "port"                => 7878,
      "apiKey"              => Radarr.api_key,
      "useSsl"              => false,
      "baseUrl"             => "",
      "activeProfileId"     => 4,
      "activeProfileName"   => "HD-1080p",
      "activeDirectory"     => "/movies",
      "tags"                => [],
      "is4k"                => false,
      "isDefault"           => true,
      "syncEnabled"         => true,
      "preventSearch"       => false,
      "tagRequests"         => false,
      "overrideRule"        => [],
      "minimumAvailability" => "released",
    }
    resp = http(:post, "#{BASE_URL}/api/v1/settings/radarr", body: body, headers: headers)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/settings/radarr failed: #{resp&.code} #{resp&.body.to_s[0, 200]}"
    end
  end

  # The "wizard complete" trigger. Was POST /settings/main {initialized:
  # true} in older releases; current Jellyseerr uses a dedicated
  # /settings/initialize endpoint (no body) and reserves /settings/main
  # for locale + other public-facing knobs.
  def self.mark_initialized(headers)
    resp = http(:post, "#{BASE_URL}/api/v1/settings/initialize", headers: headers)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      puts "  WARN: jellyseerr /api/v1/settings/initialize failed: #{resp&.code} #{resp&.body.to_s[0, 200]}"
      return false
    end
    true
  end

  def self.set_locale(headers)
    http(:post, "#{BASE_URL}/api/v1/settings/main",
         body: { "locale" => "en" }, headers: headers)
  end

  # ============================================================
  # Cross-service harvest
  # ============================================================

  # Aviary reads JELLYSEERR_API_KEY from this value.
  def self.api_key
    return nil unless File.file?(SETTINGS_JSON) && File.size(SETTINGS_JSON) > 0
    JSON.parse(File.read(SETTINGS_JSON)).dig("main", "apiKey")
  rescue
    nil
  end
end
