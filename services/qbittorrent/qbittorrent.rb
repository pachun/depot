# qbittorrent — torrent client sharing gluetun's network namespace.
# Has no port mapping of its own; gluetun publishes 8080 (WebUI) +
# 6881 (peer port) on its behalf. Reachable on the tailnet via
# tailscale serve at 8080 → localhost:8080 (gluetun's netns is shared
# with the host's localhost from a tailscale perspective).
#
# First-run bootstrap: scrape the LSIO image's temp password from logs,
# log in, rotate to depot's admin creds, create tv + movies categories,
# add docker bridge + localhost to auth-bypass.
#
# qBittorrent persists its full state to qBittorrent.conf on shutdown,
# so on later runs the file already exists with user-accumulated
# settings and the pre-seed is a no-op.

module QBittorrent
  CONFIG_DIR        = File.join(Dir.home, "hdds/.config/qbittorrent")
  CONFIG_FILE       = File.join(CONFIG_DIR, "qBittorrent/config/qBittorrent.conf")
  SEEDING_DIR       = File.join(Dir.home, "hdds/seeding")
  DOWNLOADING_DIR   = File.join(Dir.home, "downloading/torrents")
  LOCAL_PORT        = 8080
  # See sonarr.rb's TAILSCALE_PORT comment for the rationale: must
  # differ from LOCAL_PORT so the on-boot tailscaled bind doesn't
  # block the bind on the same port. qBittorrent's bind is owned by
  # gluetun (qbit shares gluetun's netns) so the port published by
  # gluetun's docker-compose is what tailscale must NOT match.
  TAILSCALE_PORT    = 8081
  BASE_URL          = "http://localhost:8080"

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p([CONFIG_DIR, SEEDING_DIR, DOWNLOADING_DIR, File.dirname(CONFIG_FILE)])

    # Pre-seed qBittorrent.conf on a fresh install so the LSIO image's
    # first start has "Bypass authentication for clients on localhost"
    # enabled — required for gluetun's qbit-port-sync.sh hook to push
    # the NAT-PMP forwarded port without credentials.
    unless File.file?(CONFIG_FILE)
      File.write(CONFIG_FILE, <<~CONF)
        [Preferences]
        WebUI\\LocalHostAuth=false
      CONF
    end

    cleanup_stale_container("qbittorrent")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("qbittorrent", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    return unless wait_for_http("#{BASE_URL}/api/v2/app/version", timeout: 30)
    bootstrap(prompts[:admin_username], prompts[:admin_password])
  end

  def self.update
    cleanup_stale_container("qbittorrent")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("qbittorrent", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    if url.empty?
      puts "qBittorrent:    (tailscale not authenticated)"
      return
    end

    # Scrape the LSIO image's temp password from logs on first run.
    # Lines roll out of the buffer over time; on a re-run it's
    # usually gone.
    temp_pass = `sudo docker logs qbittorrent 2>&1`.lines
      .find { |l| l =~ /temporary password is provided for this session: (\S+)/ }
      &.match(/temporary password is provided for this session: (\S+)/) &.[](1)
    if temp_pass
      puts "qBittorrent:    #{url} (admin/#{temp_pass})"
    else
      puts "qBittorrent:    #{url}"
    end
  end

  # ============================================================
  # Bootstrap
  # ============================================================

  def self.bootstrap(admin_user, admin_pass)
    puts "Bootstrapping qBittorrent..."

    # The first-session temp password — buried in docker logs.
    # On a re-run of an already-bootstrapped qBit, the log line is
    # gone, so fall back to the LSIO-image default "adminadmin"
    # which also won't work — but the rotated admin creds will, and
    # we try those first.
    temp_pass = `sudo docker logs qbittorrent 2>&1`.lines
      .find { |l| l =~ /temporary password is provided for this session: (\S+)/ }
      &.match(/temporary password is provided for this session: (\S+)/) &.[](1) || "adminadmin"

    # Try rotated admin creds first (we've been here before);
    # fall back to (admin, temp_pass) on fresh installs. qBit
    # returns 204 No Content on successful login, not 200.
    cookie = login_and_get_cookie(admin_user, admin_pass) ||
             login_and_get_cookie("admin", temp_pass)
    if cookie.nil?
      puts "  WARN: couldn't log into qBittorrent"
      return
    end

    prefs = {
      "web_ui_username"                      => admin_user,
      "web_ui_password"                      => admin_pass,
      "bypass_local_auth"                    => true,
      "bypass_auth_subnet_whitelist_enabled" => true,
      "bypass_auth_subnet_whitelist"         => "172.16.0.0/12,127.0.0.0/8",
      "temp_path_enabled"                    => true,
      "temp_path"                            => "/torrents",
      "save_path"                            => "/seeding",
    }
    http(:post, "#{BASE_URL}/api/v2/app/setPreferences",
         body: "json=#{URI.encode_www_form_component(JSON.generate(prefs))}",
         headers: { "Cookie" => cookie, "Content-Type" => "application/x-www-form-urlencoded" })

    create_category(cookie, "tv", "/seeding/tv")
    create_category(cookie, "movies", "/seeding/movies")
    puts "  admin creds + categories applied"
  end

  def self.login_and_get_cookie(user, pass)
    body = URI.encode_www_form(username: user, password: pass)
    resp = http(:post, "#{BASE_URL}/api/v2/auth/login",
                body: body,
                headers: { "Content-Type" => "application/x-www-form-urlencoded" })
    return nil unless resp && resp.code.to_i.between?(200, 299)
    # Newer qBit (5.x) uses `QBT_SID_<port>` as the cookie name (so
    # multiple qBit instances on the same host on different ports
    # don't collide). Older qBit used bare `SID`. Match both shapes
    # — if either matches, return the matching `name=value` so callers
    # can use it as a Cookie header verbatim.
    set_cookie = resp["Set-Cookie"] || ""
    case set_cookie
    when /(QBT_SID_\d+)=([^;]+)/, /(SID)=([^;]+)/
      "#{$1}=#{$2}"
    else
      nil
    end
  end

  def self.create_category(cookie, name, save_path)
    body = URI.encode_www_form(category: name, savePath: save_path)
    http(:post, "#{BASE_URL}/api/v2/torrents/createCategory",
         body: body,
         headers: { "Cookie" => cookie, "Content-Type" => "application/x-www-form-urlencoded" })
  end
end
