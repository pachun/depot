# jellyfin — media server. Direct-streams h264/aac to a browser when
# possible; transcodes everything else via Intel QuickSync (hardware
# accelerated, not CPU). Library scan watches ~/hdds/media/movies and
# ~/hdds/media/shows. Aviary, Sonarr, and Jellyseerr all talk to it.
#
# First-run install:
#   - bring container up
#   - run the startup wizard via the /Startup/* REST endpoints (admin
#     user creation, en-US defaults)
#   - create Movies + Shows virtual folders pointing at the bind-mount
#   - create the "aviary" and "sonarr" API keys (other services harvest
#     these from /Auth/Keys later in this run)
#   - install Intro Skipper (audio-fingerprint intro detection plugin)
#   - enable Intel QSV hardware-accelerated transcoding
#
# Update: just docker-compose up -d (LSIO image's :latest tag).
#
# Tailscale serves at 8443 → localhost:8096 because Jellyfin uses
# network_mode: host and binds [::]:8096 (IPv6 wildcard). Tailscale's
# tailnet-IPv6:8096 bind conflicts with that wildcard. Moving the
# tailscale serve to 8443 sidesteps the conflict.

module Jellyfin
  CONFIG_DIR        = File.join(Dir.home, "hdds/.config/jellyfin")
  MOVIES_DIR        = File.join(Dir.home, "hdds/media/movies")
  SHOWS_DIR         = File.join(Dir.home, "hdds/media/shows")
  LOCAL_PORT        = 8096
  TAILSCALE_PORT    = 8443
  INTRO_VERSION     = "1.10.11.21"
  BASE_URL          = "http://localhost:8096"
  WIZARD_API_HEADER = "X-Emby-Authorization"
  WIZARD_API_VALUE  = %q(MediaBrowser Client="depot", Device="depot-install", DeviceId="depot-install", Version="1.0")
  # Admin creds are shared across every service (qBit, Sonarr, Radarr,
  # Prowlarr, Jellyseerr, Aviary), so they live under depot/ rather
  # than jellyfin/.
  PROMPT_CACHE      = File.join(Dir.home, "hdds/.config/depot/admin.env")

  # ============================================================
  # Module surface
  # ============================================================

  def self.install_prompt
    cached = read_env_file(PROMPT_CACHE)
    answers = {}
    answers[:admin_username] = cached["ADMIN_USERNAME"].to_s.empty? ?
      prompt(preamble: "Media Server:", question: "Admin username") :
      cached["ADMIN_USERNAME"]
    answers[:admin_password] = cached["ADMIN_PASSWORD"].to_s.empty? ?
      prompt(question: "Admin password", secret: true, verify: true) :
      cached["ADMIN_PASSWORD"]
    answers
  end

  def self.install(prompts)
    write_env_file(PROMPT_CACHE,
      "ADMIN_USERNAME" => prompts[:admin_username],
      "ADMIN_PASSWORD" => prompts[:admin_password],
    )

    FileUtils.mkdir_p([CONFIG_DIR, MOVIES_DIR, SHOWS_DIR])
    cleanup_stale_container("jellyfin")
    free_tailscale_port(TAILSCALE_PORT)

    compose_up!("jellyfin", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })

    return unless wait_for_jellyfin_api

    if needs_bootstrap?
      puts "  running first-run wizard"
      run_startup_wizard(prompts[:admin_username], prompts[:admin_password])
      sleep 3
      wait_for_jellyfin_api
    else
      puts "  wizard already complete — skipping"
    end

    token = login(prompts[:admin_username], prompts[:admin_password])
    if token
      puts "  upserting Movies library"
      upsert_library(token, "Movies", "movies", "/media/movies")
      puts "  upserting Shows library"
      upsert_library(token, "Shows", "tvshows", "/media/shows")
      puts "  upserting aviary + sonarr API keys"
      upsert_api_key(token, "aviary")
      upsert_api_key(token, "sonarr")
    else
      puts "  WARN: admin login failed — bootstrap steps after this skipped"
    end

    install_intro_skipper_plugin
    enable_qsv_transcoding
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.update
    cleanup_stale_container("jellyfin")
    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("jellyfin", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Jellyfin:       #{url}" unless url.empty?
  end

  # ============================================================
  # API key harvest (used by Sonarr / Aviary / etc.)
  # ============================================================

  # Returns the API key stored in Jellyfin's sqlite DB for the given
  # app_name. nil if not found.
  def self.api_key_for(app_name)
    db = sqlite_db_path
    return nil if db.nil?
    out = `sqlite3 #{db} "SELECT AccessToken FROM ApiKeys WHERE Name = '#{app_name}' LIMIT 1;" 2>/dev/null`.strip
    out.empty? ? nil : out
  end

  def self.sqlite_db_path
    %w[
      hdds/.config/jellyfin/data/data/jellyfin.db
      hdds/.config/jellyfin/data/jellyfin.db
    ].each do |rel|
      path = File.join(Dir.home, rel)
      return path if File.file?(path) && File.size(path) > 0
    end
    nil
  end

  # ============================================================
  # Wait + bootstrap detection
  # ============================================================

  # Wait until Jellyfin is genuinely ready for the wizard. Three
  # signals; we declare ready when the HTTP endpoint responds AND any
  # one of several known "I'm ready" log lines appears:
  #
  #   - "Startup complete"     — Jellyfin's own readiness line (older versions)
  #   - "Application started"  — .NET generic-host startup line (stable across .NET versions)
  #   - "Now listening on"     — Kestrel's bind-confirmation line
  #
  # We OR these instead of pinning to one because the wording has
  # historically changed between Jellyfin releases (10.11 introduced
  # new EF migrations and reshuffled startup logging), and pinning to
  # one missing pattern means waiting forever for a line that never
  # appears.
  #
  # Container-death short-circuit: if the container is no longer
  # running, bail immediately instead of waiting out the timeout.
  #
  # Backstop is 10 minutes — generous because the alternative is
  # spurious failures on slow disks during first-run migrations. If
  # you actually hit it, that's a real problem to investigate via
  # `sudo docker logs jellyfin --tail 100`, not a bigger number.
  READINESS_LOG_LINES = [
    "Startup complete",
    "Application started",
    "Now listening on",
  ].freeze

  def self.wait_for_jellyfin_api
    600.times do
      state = `sudo docker inspect jellyfin --format '{{.State.Status}}' 2>/dev/null`.strip
      if state != "running"
        puts "  WARN: jellyfin container is #{state.inspect} — bailing wait"
        return false
      end

      resp = http(:get, "#{BASE_URL}/System/Info/Public")
      http_ok = resp && resp.code.to_i.between?(200, 299)

      logs = `sudo docker logs jellyfin 2>&1`
      log_ok = READINESS_LOG_LINES.any? { |line| logs.include?(line) }

      return true if http_ok && log_ok
      sleep 1
    end
    puts "  WARN: Jellyfin not ready after 10 minutes — `sudo docker logs jellyfin --tail 100`"
    false
  end

  def self.needs_bootstrap?
    info = http_get_json("#{BASE_URL}/System/Info/Public")
    return true if info.nil?
    info["StartupWizardCompleted"] != true
  end

  # ============================================================
  # Wizard
  # ============================================================

  # POST to a wizard endpoint and assert 2xx. Wizard endpoints
  # silently 4xx on schema mismatch and while migrations settle —
  # without this assertion the script would march from a failed
  # /Startup/User to a "successful" /Startup/Complete leaving a
  # wizard-done Jellyfin with no admin.
  def self.wizard_post(label, path, body = nil)
    resp = http(:post, "#{BASE_URL}#{path}", body: body)
    if resp.nil? || !resp.code.to_i.between?(200, 299)
      raise "wizard step '#{label}' returned HTTP #{resp&.code.inspect}: #{resp&.body.to_s[0, 400]}"
    end
  end

  # The critical ordering: POST /Startup/User is an UPDATE of the first
  # user, not a create. Jellyfin's UserManager lazily creates a
  # placeholder user "abc" the first time something queries the users
  # list — GET /Startup/FirstUser triggers that. Without the GET first,
  # POST /Startup/User 404s because there's no first user to update.
  def self.run_startup_wizard(username, password)
    wizard_post("Startup/Configuration", "/Startup/Configuration",
                { "UICulture" => "en-US", "MetadataCountryCode" => "US",
                  "PreferredMetadataLanguage" => "en" })

    resp = http(:get, "#{BASE_URL}/Startup/FirstUser")
    raise "GET /Startup/FirstUser failed" if resp.nil? || !resp.code.to_i.between?(200, 299)

    wizard_post("Startup/User", "/Startup/User",
                { "Name" => username, "Password" => password })

    # Verify the placeholder was actually renamed before flipping the
    # "wizard complete" flag.
    after = http_get_json("#{BASE_URL}/Startup/FirstUser")
    if after.nil? || after["Name"] != username
      raise "POST /Startup/User returned 2xx but /Startup/FirstUser still reports #{after&.dig("Name").inspect} — expected #{username.inspect}"
    end

    wizard_post("Startup/RemoteAccess", "/Startup/RemoteAccess",
                { "EnableRemoteAccess" => true, "EnableAutomaticPortMapping" => false })
    wizard_post("Startup/Complete", "/Startup/Complete")
  end

  # ============================================================
  # Admin login + library + key helpers
  # ============================================================

  def self.login(username, password)
    resp = http(:post, "#{BASE_URL}/Users/AuthenticateByName",
                body: { "Username" => username, "Pw" => password },
                headers: { WIZARD_API_HEADER => WIZARD_API_VALUE })
    return nil if resp.nil? || !resp.code.to_i.between?(200, 299)
    JSON.parse(resp.body).fetch("AccessToken", nil) rescue nil
  end

  def self.upsert_library(token, name, collection_type, path)
    existing = http_get_json("#{BASE_URL}/Library/VirtualFolders",
                             headers: { "X-Emby-Token" => token }) || []
    return if existing.any? { |f| f["Name"] == name }

    options = {
      "EnableRealtimeMonitor"               => true,
      "EnablePhotos"                        => false,
      "EnableChapterImageExtraction"        => false,
      "ExtractChapterImagesDuringLibraryScan" => false,
      "EnableTrickplayImageExtraction"      => false,
      "EnableInternetProviders"             => true,
      "SaveLocalMetadata"                   => true,
      "EnableEmbeddedTitles"                => false,
      "EnableEmbeddedEpisodeInfos"          => false,
      "AutomaticRefreshIntervalDays"        => 30,
      "PreferredMetadataLanguage"           => "en",
      "MetadataCountryCode"                 => "US",
      "SeasonZeroDisplayName"               => "Specials",
      "PathInfos"                           => [{ "Path" => path }],
    }
    body = { "LibraryOptions" => options, "PathInfos" => [{ "Path" => path }] }
    url  = "#{BASE_URL}/Library/VirtualFolders?name=#{URI.encode_www_form_component(name)}" \
           "&collectionType=#{collection_type}&refreshLibrary=true"
    http(:post, url, body: body, headers: { "X-Emby-Token" => token })
  end

  def self.upsert_api_key(token, app_name)
    keys = http_get_json("#{BASE_URL}/Auth/Keys", headers: { "X-Emby-Token" => token }) || {}
    items = keys["Items"] || []
    return if items.any? { |k| k["AppName"] == app_name }
    http(:post, "#{BASE_URL}/Auth/Keys?app=#{URI.encode_www_form_component(app_name)}",
         headers: { "X-Emby-Token" => token })
  end

  # ============================================================
  # Intro Skipper plugin
  # ============================================================

  # Auto-detects intros, credits, recaps, previews via audio
  # fingerprinting. Aviary uses this for "Skip Intro" pills. Version
  # pinned to the matching Jellyfin 10.11 build.
  def self.install_intro_skipper_plugin
    dir = File.join(CONFIG_DIR, "data/plugins/Intro Skipper_#{INTRO_VERSION}")
    return if File.file?(File.join(dir, "IntroSkipper.dll"))

    puts "  installing Jellyfin Intro Skipper plugin v#{INTRO_VERSION}"
    tmpzip = "/tmp/intro-skipper-#{Process.pid}.zip"
    url    = "https://github.com/intro-skipper/intro-skipper/releases/download/10.11/" \
             "v#{INTRO_VERSION}/intro-skipper-v#{INTRO_VERSION}.zip"
    sh!("curl -sfL #{url} -o #{tmpzip}")
    FileUtils.mkdir_p(dir)
    sh!("unzip -q -o #{tmpzip} -d '#{dir}'")
    File.delete(tmpzip)
    sh!("sudo docker restart jellyfin >/dev/null")
  end

  # ============================================================
  # Intel QSV hardware-accelerated transcoding
  # ============================================================

  # Without this every transcode runs on CPU and 1080p eats every
  # core. Configured via the System/Configuration/encoding REST API.
  # Skips gracefully if the aviary API key isn't in the DB yet
  # (fresh wizard hasn't been done).
  def self.enable_qsv_transcoding
    puts "  configuring Jellyfin hardware acceleration (QSV)..."
    key = api_key_for("aviary")
    if key.nil?
      puts "    skipped: no 'aviary' API key in Jellyfin yet"
      return
    end

    headers = { "X-Emby-Token" => key }
    current = http_get_json("#{BASE_URL}/System/Configuration/encoding", headers: headers)
    if current.nil?
      puts "    skipped: encoding config endpoint returned non-JSON"
      return
    end

    patched = current.merge(
      "HardwareAccelerationType"      => "qsv",
      "EnableHardwareEncoding"        => true,
      "HardwareDecodingCodecs"        => %w[h264 hevc mpeg2video vc1 vp8 vp9],
      "EnableDecodingColorDepth10Hevc" => true,
      "EnableDecodingColorDepth10Vp9"  => true,
      "AllowHevcEncoding"             => true,
    )
    http(:post, "#{BASE_URL}/System/Configuration/encoding", body: patched, headers: headers)
    puts "    enabled QSV + 10-bit HEVC decode"
  end
end
