# radarr — movie automation. Same shape as Sonarr but for movies.
# Watches subscribed movies via Prowlarr, sends accepted releases to
# qBittorrent (category "movies"), moves into ~/hdds/media/movies on
# completion, pings Jellyfin to rescan.

module Radarr
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/radarr")
  CONFIG_XML     = File.join(CONFIG_DIR, "config.xml")
  LIBRARY_DIR    = File.join(Dir.home, "hdds/media/movies")
  LOCAL_PORT     = 7878
  # See sonarr.rb's TAILSCALE_PORT comment for the rationale: must
  # differ from LOCAL_PORT so the on-boot tailscaled bind doesn't
  # block the container's 0.0.0.0:PORT wildcard bind.
  TAILSCALE_PORT = 7879
  BASE_URL       = "http://localhost:7878"

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p([CONFIG_DIR, LIBRARY_DIR,
                       File.join(Dir.home, "hdds/seeding"),
                       File.join(Dir.home, "downloading/usenet")])

    cleanup_stale_container("radarr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("radarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    wait_for_http("#{BASE_URL}/initialize.json", timeout: 30)
    arr_create_admin(BASE_URL, prompts[:admin_username], prompts[:admin_password], "Radarr")

    key = api_key
    return if key.nil?

    arr_opinionate_downloads(BASE_URL, key)
    arr_set_library_directory(BASE_URL, key, "/movies")
    arr_connect_to_qbit(BASE_URL, key,
                        prompts[:admin_username], prompts[:admin_password], "movies")

    jf_key = Jellyfin.api_key_for("sonarr")  # Jellyfin's per-app key, named 'sonarr' but shared
    arr_connect_to_jellyfin(BASE_URL, key, jf_key) if jf_key
  end

  def self.update
    cleanup_stale_container("radarr")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("radarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Radarr:         #{url}" unless url.empty?
  end

  def self.api_key
    arr_read_api_key(CONFIG_XML)
  end
end
