# prowlarr — indexer aggregator. Talks to every torrent/usenet indexer
# (NZBGeek, IPTorrents, etc.) on Sonarr's/Radarr's behalf, normalizing
# their wildly-different APIs. The arrs query Prowlarr; Prowlarr fans
# out to indexers. Configuration is push: register indexers here, plus
# register Sonarr/Radarr as Applications, and Prowlarr syncs the
# indexer list into each arr automatically.

module Prowlarr
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/prowlarr")
  CONFIG_XML     = File.join(CONFIG_DIR, "config.xml")
  LOCAL_PORT     = 9696
  TAILSCALE_PORT = 9696
  BASE_URL       = "http://localhost:9696"

  NZBGEEK_DEFAULT_URL = "https://api.nzbgeek.info"
  TV_USENET_CATS      = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080].freeze
  MOVIE_USENET_CATS   = [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060].freeze
  ALL_CATS            = (TV_USENET_CATS + MOVIE_USENET_CATS).freeze
  PROMPT_CACHE        = File.join(Dir.home, "hdds/.config/depot/prowlarr.env")

  def self.install_prompt
    cached = read_env_file(PROMPT_CACHE)
    answers = {}
    answers[:nzbgeek_api_key] = cached["NZBGEEK_API_KEY"].to_s.empty? ?
      prompt(preamble: "NZBGeek:",
             question: "API key (from nzbgeek.info → account → API)",
             secret:   true) :
      cached["NZBGEEK_API_KEY"]
    answers[:ipt_cookie] = cached["IPT_COOKIE"].to_s.empty? ?
      prompt(preamble: <<~TEXT.chomp,
               IPTorrents:
                 1. Open https://iptorrents.com and log in
                 2. F12 → Network tab → reload the page
                 3. Click the first request (the page itself)
                 4. Headers → Request Headers → copy "Cookie:" value below
                 5. Then "User-Agent:" at the next prompt
             TEXT
             question: "Cookie") :
      cached["IPT_COOKIE"]
    answers[:ipt_useragent] = cached["IPT_USERAGENT"].to_s.empty? ?
      prompt(question: "User-Agent") :
      cached["IPT_USERAGENT"]
    answers
  end

  def self.install(prompts)
    write_env_file(PROMPT_CACHE,
      "NZBGEEK_API_KEY" => prompts[:nzbgeek_api_key],
      "IPT_COOKIE"      => prompts[:ipt_cookie],
      "IPT_USERAGENT"   => prompts[:ipt_useragent],
    )

    FileUtils.mkdir_p(CONFIG_DIR)
    cleanup_stale_container("prowlarr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("prowlarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    wait_for_http("#{BASE_URL}/initialize.json", timeout: 30)
    arr_create_admin(BASE_URL, prompts[:admin_username], prompts[:admin_password], "Prowlarr")

    key = api_key
    return if key.nil?
    arr_wait_for_api(BASE_URL, "v1", key)

    register_newznab(key, "NZBGeek", NZBGEEK_DEFAULT_URL, prompts[:nzbgeek_api_key])
    register_iptorrents(key, prompts[:ipt_cookie], prompts[:ipt_useragent])

    sonarr_key = Sonarr.api_key
    register_application(key, "Sonarr", "http://host.docker.internal:8989", sonarr_key, TV_USENET_CATS) if sonarr_key
    radarr_key = Radarr.api_key
    register_application(key, "Radarr", "http://host.docker.internal:7878", radarr_key, MOVIE_USENET_CATS) if radarr_key
  end

  def self.update
    cleanup_stale_container("prowlarr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("prowlarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Prowlarr:       #{url}" unless url.empty?
  end

  def self.api_key
    arr_read_api_key(CONFIG_XML)
  end

  # ============================================================
  # Indexer + application registration
  # ============================================================

  def self.register_newznab(api_key, name, url, indexer_key)
    payload = {
      "name" => name, "enable" => true, "redirect" => true,
      "supportsRss" => true, "supportsSearch" => true, "supportsRedirect" => true,
      "priority" => 10, "downloadClientId" => 0,
      "appProfileId" => default_app_profile_id(api_key),
      "implementation" => "Newznab", "implementationName" => "Newznab",
      "configContract" => "NewznabSettings",
      "protocol" => "usenet", "privacy" => "private",
      "fields" => [
        { "name" => "baseUrl", "value" => url },
        { "name" => "apiPath", "value" => "/api" },
        { "name" => "apiKey", "value" => indexer_key },
        { "name" => "categories", "value" => ALL_CATS },
      ],
      "tags" => [],
    }
    arr_upsert_by_name(BASE_URL, "/api/v1/indexer", api_key, name, payload)
  end

  def self.register_iptorrents(api_key, cookie, user_agent)
    payload = {
      "name" => "IPTorrents", "enable" => true, "redirect" => false,
      "supportsRss" => true, "supportsSearch" => true, "supportsRedirect" => false,
      "priority" => 25, "downloadClientId" => 0,
      "appProfileId" => default_app_profile_id(api_key),
      "implementation" => "IPTorrents", "implementationName" => "IPTorrents",
      "configContract" => "IPTorrentsSettings",
      "protocol" => "torrent", "privacy" => "private",
      "fields" => [
        { "name" => "baseUrl", "value" => "https://iptorrents.com/" },
        { "name" => "cookie", "value" => cookie },
        { "name" => "userAgent", "value" => user_agent },
        { "name" => "categories", "value" => ALL_CATS },
      ],
      "tags" => [],
    }
    arr_upsert_by_name(BASE_URL, "/api/v1/indexer", api_key, "IPTorrents", payload)
  end

  def self.register_application(api_key, impl, arr_url, arr_api_key, sync_categories)
    payload = {
      "name" => impl, "syncLevel" => "fullSync",
      "implementation" => impl, "implementationName" => impl,
      "configContract" => "#{impl}Settings",
      "fields" => [
        { "name" => "prowlarrUrl", "value" => "http://host.docker.internal:9696" },
        { "name" => "baseUrl", "value" => arr_url },
        { "name" => "apiKey", "value" => arr_api_key },
        { "name" => "syncCategories", "value" => sync_categories },
      ],
      "tags" => [],
    }
    arr_upsert_by_name(BASE_URL, "/api/v1/applications", api_key, impl, payload)
  end

  def self.default_app_profile_id(api_key)
    profiles = http_get_json("#{BASE_URL}/api/v1/appprofile",
                             headers: { "X-Api-Key" => api_key }) || []
    profiles.min_by { |p| p["id"] }&.dig("id") || 1
  end
end
