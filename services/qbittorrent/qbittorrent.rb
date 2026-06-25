# qbittorrent — torrent client sharing gluetun's network namespace.
# Has no port mapping of its own; gluetun publishes 8080 (WebUI) +
# 6881 (peer port) on its behalf. Reachable on the tailnet via
# tailscale serve at 8080 → localhost:8080 (gluetun's netns is shared
# with the host's localhost from a tailscale perspective).
#
# First-run bootstrap: scrape the LSIO image's temp password from logs,
# log in, rotate to depot's admin creds, create tv + movies categories.
#
# qBittorrent only flushes its in-memory config to qBittorrent.conf on a
# clean shutdown, so settings applied solely through the WebUI API are
# lost if the box is power-cut before a flush — which silently breaks the
# Radarr/Sonarr download-client link (docker bridge) and gluetun's
# port-sync (localhost) until the next reinstall. seed_webui_auth writes
# the auth-critical WebUI keys — localhost + docker-subnet auth bypass,
# admin user, and PBKDF2 password hash — straight into the conf before
# the container starts, so they survive a power cut and are reproducible
# from the file alone.

require "openssl"

module QBittorrent
  CONFIG_DIR        = File.join(Dir.home, "hdds/.config/qbittorrent")
  CONFIG_FILE       = File.join(CONFIG_DIR, "qBittorrent/qBittorrent.conf")
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

    # Stop any running container first so qBittorrent can't overwrite the
    # conf we're about to seed with its own in-memory state on exit.
    cleanup_stale_container("qbittorrent")

    # Seed the auth-critical WebUI keys straight into qBittorrent.conf
    # (see the file header). Runs every install — not just fresh ones —
    # so a conf reset by a power cut gets re-hardened, and the bootstrap
    # below never has to rely on the temp password still being in the
    # log buffer.
    seed_webui_auth(prompts[:admin_username], prompts[:admin_password])

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

  # ============================================================
  # Durable WebUI auth seeding
  # ============================================================

  # Merge the auth-critical WebUI keys into qBittorrent.conf so they
  # survive an ungraceful shutdown. LocalHostAuth=false lets gluetun's
  # localhost port-sync through; the docker-bridge subnet whitelist lets
  # Radarr/Sonarr (host.docker.internal) through; the PBKDF2 hash pins
  # the admin password so WebUI login over tailscale is stable. bootstrap
  # re-applies the same values via the API as a belt-and-suspenders pass.
  def self.seed_webui_auth(admin_user, admin_pass)
    merge_preferences(CONFIG_FILE,
      "WebUI\\LocalHostAuth"              => "false",
      "WebUI\\AuthSubnetWhitelistEnabled" => "true",
      "WebUI\\AuthSubnetWhitelist"        => "172.16.0.0/12, 127.0.0.0/8",
      "WebUI\\Username"                   => admin_user,
      "WebUI\\Password_PBKDF2"            => %Q("#{pbkdf2_password(admin_pass)}"))
    puts "  seeded WebUI auth into #{CONFIG_FILE}"
  end

  # qBittorrent stores the WebUI password as PBKDF2-HMAC-SHA512 over a
  # 16-byte salt, 100_000 iterations, 64-byte derived key, serialized as
  # @ByteArray(base64(salt):base64(key)) — the exact shape qBittorrent
  # writes itself, so it reads back without a rehash.
  def self.pbkdf2_password(plain)
    salt = OpenSSL::Random.random_bytes(16)
    key  = OpenSSL::KDF.pbkdf2_hmac(plain, salt: salt, iterations: 100_000,
                                    length: 64, hash: "SHA512")
    "@ByteArray(#{[salt].pack("m0")}:#{[key].pack("m0")})"
  end

  # Upsert key=value pairs into the [Preferences] section of a QSettings
  # ini file, preserving every other section and key. Creates the file
  # and/or the section when missing, and lands new keys flush against the
  # existing ones rather than past a trailing blank line.
  def self.merge_preferences(path, pairs)
    lines = File.file?(path) ? File.read(path).split("\n") : []

    section = lines.index("[Preferences]")
    if section.nil?
      lines << "" unless lines.empty? || lines.last.to_s.empty?
      lines << "[Preferences]"
      section = lines.length - 1
    end

    after = lines[(section + 1)..].index { |l| l.start_with?("[") }
    section_end = after ? section + 1 + after : lines.length
    section_end -= 1 while section_end > section + 1 && lines[section_end - 1].to_s.empty?

    pairs.each do |key, value|
      at = (section + 1...section_end).find { |i| lines[i].start_with?("#{key}=") }
      if at
        lines[at] = "#{key}=#{value}"
      else
        lines.insert(section_end, "#{key}=#{value}")
        section_end += 1
      end
    end

    File.write(path, lines.join("\n") + "\n")
  end
end
