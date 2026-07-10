# sonarr — TV automation. Watches new releases of subscribed shows
# via Prowlarr's indexer aggregation, sends accepted releases to
# qBittorrent (tagged with category "tv"), waits for download to
# finish, moves into ~/hdds/media/shows with renamed/organized filename,
# then pings Jellyfin to rescan.
#
# First-run install: bring container up, create admin user, set root
# folder to /tv, apply the opinionated release-policy custom formats
# (no HEVC/x265, no 2160p, no cam-rips, no banned groups), wire
# qBittorrent as download client, wire Jellyfin as notification
# target. Update: just docker-compose up -d.

module Sonarr
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/sonarr")
  CONFIG_XML     = File.join(CONFIG_DIR, "config.xml")
  LIBRARY_DIR    = File.join(Dir.home, "hdds/media/shows")
  LOCAL_PORT     = 8989
  # Tailscale Serve listens on this port and forwards to LOCAL_PORT.
  # Must differ from LOCAL_PORT — tailscaled restores its serve config
  # on boot and binds tailscale_ip:PORT; if the container also tries
  # to bind 0.0.0.0:PORT for the same number, Linux refuses the
  # wildcard bind ("address already in use") and the container fails
  # to start. Convention: LOCAL_PORT + 1 (same pattern as sabnzbd).
  TAILSCALE_PORT = 8990
  BASE_URL       = "http://localhost:8989"

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p([CONFIG_DIR, LIBRARY_DIR,
                       File.join(Dir.home, "hdds/seeding"),
                       File.join(Dir.home, "downloading/usenet")])

    cleanup_stale_container("sonarr")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("sonarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    wait_for_http("#{BASE_URL}/initialize.json", timeout: 30)
    arr_create_admin(BASE_URL, prompts[:admin_username], prompts[:admin_password], "Sonarr")

    key = api_key
    return if key.nil?

    arr_opinionate_downloads(BASE_URL, key)
    arr_set_library_directory(BASE_URL, key, "/shows")
    arr_connect_to_qbit(BASE_URL, key, "tv")

    jf_key = Jellyfin.api_key_for("sonarr")
    arr_connect_to_jellyfin(BASE_URL, key, jf_key) if jf_key
  end

  def self.update
    cleanup_stale_container("sonarr")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("sonarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    # See Radarr.update: a missing torrent client is invisible to Sonarr's
    # own health checks as long as its usenet client is enabled.
    return unless wait_for_http("#{BASE_URL}/initialize.json", timeout: 30)

    key = api_key
    return if key.nil?

    arr_connect_to_qbit(BASE_URL, key, "tv")
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Sonarr:         #{url}" unless url.empty?
  end

  def self.api_key
    arr_read_api_key(CONFIG_XML)
  end
end
