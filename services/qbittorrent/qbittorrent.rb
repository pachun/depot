# qbittorrent — torrent client sharing gluetun's network namespace.
# Has no port mapping of its own; gluetun publishes 8080 (WebUI) +
# 6881 (peer port) on its behalf. Reachable on the tailnet via
# tailscale serve at 8080 → localhost:8080 (gluetun's netns is shared
# with the host's localhost from a tailscale perspective).
#
# First-run bootstrap: scrape the LSIO image's temp password from logs,
# log in, rotate to depot's admin creds, create tv + movies categories.
#
# qBittorrent only flushes its in-memory config to disk on a clean
# shutdown, so anything applied solely through the WebUI API is lost if
# the box is power-cut before a flush. Two things break when that
# happens, both silently: the Radarr/Sonarr download-client link (docker
# bridge) with gluetun's port-sync (localhost), and the save paths — the
# image's own default is /downloads, which nothing mounts, so every
# torrent dies at 0% on a permission error.
#
# So the seeds write straight into the config files before the container
# starts, on every install and every update: seed_webui_access for the
# IPv4 bind and the two auth bypasses, seed_storage_paths for the SSD
# incomplete + HDD seeding tiers, seed_categories for where each arr's
# grabs land. All reproducible from the files alone. seed_webui_auth adds
# the admin user and PBKDF2 password hash for the human WebUI login.

require "json"
require "openssl"

module QBittorrent
  CONFIG_DIR        = File.join(Dir.home, "hdds/.config/qbittorrent")
  CONFIG_FILE       = File.join(CONFIG_DIR, "qBittorrent/qBittorrent.conf")
  CATEGORIES_FILE   = File.join(CONFIG_DIR, "qBittorrent/categories.json")
  SEEDING_DIR       = File.join(Dir.home, "hdds/seeding")
  DOWNLOADING_DIR   = File.join(Dir.home, "downloading/torrents")
  # The same two directories as qBittorrent sees them. The compose file
  # mounts each host path at its own last segment, so these are just the
  # basenames — kept as constants because the conf we seed names them.
  SEEDING_MOUNT     = "/seeding"
  INCOMPLETE_MOUNT  = "/torrents"
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

    stop_without_flush

    # Seed the auth-critical WebUI keys straight into qBittorrent.conf
    # (see the file header). Runs every install — not just fresh ones —
    # so a conf reset by a power cut gets re-hardened, and the bootstrap
    # below never has to rely on the temp password still being in the
    # log buffer.
    seed_webui_auth(prompts[:admin_username], prompts[:admin_password])
    seed_storage_paths
    seed_categories

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
    stop_without_flush
    seed_webui_access
    seed_storage_paths
    seed_categories
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

  # cleanup_stale_container deliberately leaves a *running* container
  # alone. qBittorrent needs the opposite: it rewrites qBittorrent.conf
  # from memory whenever it exits cleanly, so any key seeded into that
  # file while it's up is clobbered the moment compose recreates the
  # container. `docker rm -f` is a SIGKILL — it denies qBittorrent that
  # last write, and the file we seeded is the file it reads on the way
  # back up.
  def self.stop_without_flush
    _, status = capture("sudo docker inspect qbittorrent --format '{{.State.Status}}'")
    return unless status.success?

    sh_quiet!("sudo docker rm -f qbittorrent")
  end

  # The two auth bypasses Radarr, Sonarr and gluetun depend on, plus the
  # IPv4-only bind that makes them work at all.
  #
  # Address must not be "*": that binds dual-stack, so an IPv4 caller
  # arrives as the mapped form ::ffff:172.18.0.1 and matches neither the
  # loopback test nor an IPv4 CIDR in the whitelist. Both bypasses then
  # go quietly inert and every caller is asked for a password it doesn't
  # carry. Binding 0.0.0.0 keeps callers in plain IPv4.
  #
  # Password-free by design, so `update` can re-assert it without the
  # install prompts. Runs before the container starts — qBittorrent
  # rewrites this file from memory on shutdown.
  def self.seed_webui_access
    merge_section(CONFIG_FILE, "Preferences",
      "WebUI\\Address"                    => "0.0.0.0",
      "WebUI\\LocalHostAuth"              => "false",
      "WebUI\\AuthSubnetWhitelistEnabled" => "true",
      "WebUI\\AuthSubnetWhitelist"        => "172.16.0.0/12, 127.0.0.0/8")
    puts "  seeded WebUI access into #{CONFIG_FILE}"
  end

  # Where qBittorrent puts bytes, matching the two tiers the compose file
  # mounts: incomplete torrents on the SSD, completed ones on the HDD pool
  # they keep seeding from. Without these the image's own default wins —
  # /downloads, which nothing mounts, so every torrent dies at 0% with a
  # file_open permission error against the container's read-only root.
  #
  # qBittorrent 5 reads Session\* under [BitTorrent]; the Downloads\* pair
  # under [Preferences] is the pre-4.2 spelling it migrates from. Write
  # both, so neither a migration nor a rollback reintroduces /downloads.
  def self.seed_storage_paths
    merge_section(CONFIG_FILE, "BitTorrent",
      "Session\\DefaultSavePath" => SEEDING_MOUNT,
      "Session\\TempPathEnabled" => "true",
      "Session\\TempPath"        => INCOMPLETE_MOUNT)
    merge_section(CONFIG_FILE, "Preferences",
      "Downloads\\SavePath" => SEEDING_MOUNT,
      "Downloads\\TempPath" => INCOMPLETE_MOUNT)
    puts "  seeded storage paths into #{CONFIG_FILE}"
  end

  # Radarr and Sonarr tag every grab with a category; qBittorrent decides
  # where that category lands. bootstrap creates them over the API, which
  # only reaches disk on a clean exit — so write them here too, merged so
  # a category added by hand in the WebUI survives.
  def self.seed_categories
    existing = File.file?(CATEGORIES_FILE) ? JSON.parse(File.read(CATEGORIES_FILE)) : {}

    seeded = {
      "movies" => { "save_path" => "#{SEEDING_MOUNT}/movies" },
      "tv"     => { "save_path" => "#{SEEDING_MOUNT}/tv" },
    }

    merged = existing.merge(seeded) { |_, old, new| old.merge(new) }
    File.write(CATEGORIES_FILE, JSON.pretty_generate(merged) + "\n")
    puts "  seeded categories into #{CATEGORIES_FILE}"
  end

  # The admin credentials on top of the access keys. Only the human WebUI
  # login over tailscale needs these; the *arrs ride the subnet bypass.
  # The PBKDF2 hash pins the password so it survives an ungraceful
  # shutdown. bootstrap re-applies the same values via the API as a
  # belt-and-suspenders pass.
  def self.seed_webui_auth(admin_user, admin_pass)
    seed_webui_access
    merge_section(CONFIG_FILE, "Preferences",
      "WebUI\\Username"        => admin_user,
      "WebUI\\Password_PBKDF2" => %Q("#{pbkdf2_password(admin_pass)}"))
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

  # Upsert key=value pairs into one section of a QSettings ini file,
  # preserving every other section and key. Creates the file and/or the
  # section when missing, and lands new keys flush against the existing
  # ones rather than past a trailing blank line.
  def self.merge_section(path, section_name, pairs)
    lines = File.file?(path) ? File.read(path).split("\n") : []
    header = "[#{section_name}]"

    section = lines.index(header)
    if section.nil?
      lines << "" unless lines.empty? || lines.last.to_s.empty?
      lines << header
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
