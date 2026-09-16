# bazarr — subtitle backfill for Sonarr and Radarr. Syncs their
# libraries, works out which videos have no usable English subtitle
# (none embedded, or only bitmap PGS/VobSub tracks that the players
# can't render as text), downloads an English .srt next to the video,
# and tells Jellyfin to refresh the item so the new track shows up
# without a rescan.
#
# First-run install: bring container up, connect Sonarr + Radarr +
# Jellyfin, create the single English language profile and make it
# the default for every series and movie, enable the account-free
# providers (plus OpenSubtitles.com when credentials were given), then
# kick off the first sync and a search for everything that's missing.
# Update: docker-compose up -d and re-assert the same settings.
#
# Bazarr searches for missing subtitles on its own schedule (every 6
# hours) and re-checks on every Sonarr/Radarr import, so after install
# nothing else has to poke it.

module Bazarr
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/bazarr")
  CONFIG_YAML    = File.join(CONFIG_DIR, "config/config.yaml")
  LOCAL_PORT     = 6767
  # See Sonarr::TAILSCALE_PORT for why this differs from LOCAL_PORT.
  TAILSCALE_PORT = 6768
  BASE_URL       = "http://localhost:6767"

  # Providers that need no account. OpenSubtitles.com is the best
  # English source but needs a (free) login, so it's added only when
  # the install prompt got credentials.
  ACCOUNT_FREE_PROVIDERS = %w[gestdown tvsubtitles yifysubtitles].freeze
  OPENSUBTITLES_PROVIDER = "opensubtitlescom"

  ENGLISH_PROFILE_ID = 1

  ALASS_BINARY = File.join(CONFIG_DIR, "alass")
  ALASS_URL    = "https://github.com/kaegi/alass/releases/download/v2.0.0/alass-linux64"

  # Bazarr scores a candidate subtitle by how many release attributes
  # it shares with the video (series, season, episode, source, release
  # group, codecs...). Its default floor of 90% rejects nearly every
  # subtitle whose release group or source differs from the video's,
  # which is exactly the case for a Blu-ray rip that needs a text
  # track ripped from the WEB release. Series/episode/year matching
  # alone scores in the mid 80s, so 80 admits those while still
  # refusing subtitles for the wrong episode.
  MINIMUM_SERIES_SCORE = 80
  MINIMUM_MOVIE_SCORE  = 65

  def self.install_prompt
    puts
    puts <<~TEXT
      OpenSubtitles.com login (optional):
        Bazarr fetches missing English subtitles from a few free
        sources. Adding a free OpenSubtitles.com account roughly
        doubles the hit rate. Leave blank to skip.
    TEXT
    username = prompt(question: "OpenSubtitles.com username")
    return {} if username.strip.empty?

    password = prompt(question: "OpenSubtitles.com password", secret: true)
    { opensubtitles_username: username.strip, opensubtitles_password: password }
  end

  def self.install(prompts)
    FileUtils.mkdir_p(CONFIG_DIR)
    bring_up
    configure(prompts)
  end

  def self.update
    bring_up
    configure({})
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Bazarr:         #{url}" unless url.empty?
  end

  def self.api_key
    return nil unless File.file?(CONFIG_YAML)
    File.read(CONFIG_YAML)[/^auth:\n(?:  .*\n)*?  apikey: (\S+)/, 1]
  end

  def self.bring_up
    fetch_alass
    cleanup_stale_container("bazarr")
    free_tailscale_port(LOCAL_PORT, TAILSCALE_PORT)
    compose_up!("bazarr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.fetch_alass
    return if File.executable?(ALASS_BINARY)
    FileUtils.mkdir_p(CONFIG_DIR)
    sh!("curl -sfL -o #{ALASS_BINARY} #{ALASS_URL}")
    File.chmod(0o755, ALASS_BINARY)
  end

  # Idempotent. Every setting is re-asserted so a plain
  # `depot update bazarr` ships config fixes to existing installs.
  # OpenSubtitles credentials survive updates because they're read
  # back out of Bazarr's own config when the prompts don't carry them.
  def self.configure(prompts)
    return unless wait_for_api

    save_settings(connection_settings + subtitle_policy_settings +
                  provider_settings(prompts) + jellyfin_settings)
    save_settings(language_profile_settings) unless english_profile_exists?

    sync_libraries_and_search_for_missing_subtitles
  end

  # Saving profiles makes Bazarr re-evaluate every episode and movie
  # against them, which takes longer than an HTTP call should, so the
  # profile is only written when it isn't there yet.
  def self.english_profile_exists?
    profiles = http_get_json("#{BASE_URL}/api/system/languages/profiles",
                             headers: { "X-API-KEY" => api_key }) || []
    profiles.any? do |profile|
      profile["profileId"] == ENGLISH_PROFILE_ID &&
        (profile["items"] || []).map { |item| item["language"] } == ["en"]
    end
  end

  def self.wait_for_api
    60.times do
      key = api_key
      resp = key && http(:get, "#{BASE_URL}/api/system/status", headers: { "X-API-KEY" => key })
      return true if resp && resp.code.to_i.between?(200, 299)
      sleep 1
    end
    puts "  WARN: Bazarr didn't come up in 60s"
    false
  end

  def self.connection_settings
    [
      ["settings-general-use_sonarr", "true"],
      ["settings-sonarr-ip", "host.docker.internal"],
      ["settings-sonarr-port", Sonarr::LOCAL_PORT.to_s],
      ["settings-sonarr-base_url", "/"],
      ["settings-sonarr-ssl", "false"],
      ["settings-sonarr-apikey", Sonarr.api_key.to_s],
      ["settings-general-use_radarr", "true"],
      ["settings-radarr-ip", "host.docker.internal"],
      ["settings-radarr-port", Radarr::LOCAL_PORT.to_s],
      ["settings-radarr-base_url", "/"],
      ["settings-radarr-ssl", "false"],
      ["settings-radarr-apikey", Radarr.api_key.to_s],
      ["settings-analytics-enabled", "false"],
    ]
  end

  # An embedded English text track satisfies the profile; embedded
  # bitmap tracks (PGS on Blu-ray sources, VobSub on DVD) don't, since
  # Jellyfin can't stream those as text and the players drop them.
  def self.subtitle_policy_settings
    [
      ["settings-general-use_embedded_subs", "true"],
      ["settings-general-ignore_pgs_subs", "true"],
      ["settings-general-ignore_vobsub_subs", "true"],
      ["settings-general-ignore_ass_subs", "false"],
      ["settings-general-serie_default_enabled", "true"],
      ["settings-general-serie_default_profile", ENGLISH_PROFILE_ID.to_s],
      ["settings-general-movie_default_enabled", "true"],
      ["settings-general-movie_default_profile", ENGLISH_PROFILE_ID.to_s],
      ["settings-general-upgrade_subs", "true"],
      ["settings-general-minimum_score", MINIMUM_SERIES_SCORE.to_s],
      ["settings-general-minimum_score_movie", MINIMUM_MOVIE_SCORE.to_s],
    ] + subtitle_sync_settings
  end

  # A subtitle ripped from one cut of a title (WEB) lands seconds off
  # on another (Blu-ray), and the two cuts usually differ in more than
  # one place, so the drift changes through the episode. After every
  # download, alass re-times the file against the video's audio and
  # splits it wherever the cuts diverge. Bazarr's built-in sync
  # (ffsubsync) can only apply one shift and stretch, so it stays off.
  def self.subtitle_sync_settings
    [
      ["settings-subsync-use_subsync", "false"],
      ["settings-general-use_postprocessing", "true"],
      ["settings-general-use_postprocessing_threshold", "false"],
      ["settings-general-use_postprocessing_threshold_movie", "false"],
      ["settings-general-postprocessing_cmd", ALASS_POSTPROCESSING_COMMAND],
    ]
  end

  # Runs inside the container after each download; Bazarr substitutes
  # the video and subtitle paths. alass writes a fresh file (it wants
  # the output to end in .srt like the input), which replaces the
  # original only when alignment succeeded.
  ALASS_POSTPROCESSING_COMMAND =
    %q(alass "{{episode}}" "{{subtitles}}" "{{subtitles}}.alass.srt" && mv "{{subtitles}}.alass.srt" "{{subtitles}}")

  def self.provider_settings(prompts)
    username = prompts[:opensubtitles_username] || saved_opensubtitles_username
    password = prompts[:opensubtitles_password]
    providers = ACCOUNT_FREE_PROVIDERS.dup
    settings = []

    if username && !username.empty?
      providers << OPENSUBTITLES_PROVIDER
      settings << ["settings-opensubtitlescom-username", username]
      settings << ["settings-opensubtitlescom-password", password] if password
      settings << ["settings-opensubtitlescom-use_hash", "true"]
    end

    settings + providers.map { |p| ["settings-general-enabled_providers", p] }
  end

  def self.saved_opensubtitles_username
    return nil unless File.file?(CONFIG_YAML)
    File.read(CONFIG_YAML)[/^opensubtitlescom:\n(?:  .*\n)*?  username: '?([^'\n]*)'?/, 1].to_s
  end

  # Bazarr refreshes the Jellyfin item right after writing a subtitle,
  # so the new track is selectable on the next play. Bazarr and
  # Jellyfin mount the same library at different container paths
  # (/shows vs /media/shows); Bazarr maps between them itself.
  def self.jellyfin_settings
    jf_key = jellyfin_api_key
    return [] if jf_key.nil?

    libraries = http_get_json("#{Jellyfin::BASE_URL}/Library/VirtualFolders",
                              headers: { "X-Emby-Token" => jf_key }) || []
    shows  = libraries.find { |l| l["Name"] == "Shows" }
    movies = libraries.find { |l| l["Name"] == "Movies" }

    [
      ["settings-general-use_jellyfin", "true"],
      ["settings-jellyfin-url", "http://host.docker.internal:8096"],
      ["settings-jellyfin-apikey", jf_key],
      ["settings-jellyfin-refresh_method", "immediate"],
      ["settings-jellyfin-update_series_library", (!shows.nil?).to_s],
      ["settings-jellyfin-update_movie_library", (!movies.nil?).to_s],
      (shows  && ["settings-jellyfin-series_library", shows["Name"]]),
      (shows  && ["settings-jellyfin-series_library_ids", shows["ItemId"]]),
      (movies && ["settings-jellyfin-movie_library", movies["Name"]]),
      (movies && ["settings-jellyfin-movie_library_ids", movies["ItemId"]]),
    ].compact
  end

  # Jellyfin API keys are all admin-scoped, so Sonarr's key can mint a
  # dedicated one for Bazarr; that keeps each app's access revocable
  # on its own.
  def self.jellyfin_api_key
    existing = Jellyfin.api_key_for("bazarr")
    return existing if existing

    sonarr_key = Jellyfin.api_key_for("sonarr")
    return nil if sonarr_key.nil?

    Jellyfin.upsert_api_key(sonarr_key, "bazarr")
    Jellyfin.api_key_for("bazarr")
  end

  # One profile: plain English, no hearing-impaired or forced-only
  # tracks required.
  def self.language_profile_settings
    profile = {
      "profileId" => ENGLISH_PROFILE_ID,
      "name" => "English",
      "items" => [{ "id" => 1, "language" => "en", "audio_exclude" => "False",
                    "audio_only_include" => "False", "hi" => "False", "forced" => "False" }],
      "cutoff" => nil,
      "mustContain" => [],
      "mustNotContain" => [],
      "originalFormat" => false,
      "tag" => nil,
    }
    [
      ["languages-enabled", "en"],
      ["languages-profiles", JSON.generate([profile])],
    ]
  end

  # Bazarr answers slowly while a subtitle search is running, so a
  # dropped or timed-out save gets one retry before it's reported.
  def self.save_settings(pairs, attempts_left: 2)
    resp = http(:post, "#{BASE_URL}/api/system/settings",
                body: URI.encode_www_form(pairs),
                headers: { "X-API-KEY" => api_key,
                           "Content-Type" => "application/x-www-form-urlencoded" })
    return if resp && resp.code.to_i.between?(200, 299)
    return save_settings(pairs, attempts_left: attempts_left - 1) if resp.nil? && attempts_left > 1

    outcome = resp ? "HTTP #{resp.code} — #{resp.body.to_s[0, 200]}" : "no response"
    puts "  WARN: Bazarr settings save failed: #{outcome}"
  end

  # Series and movies sync from the arrs on Bazarr's own hourly timer;
  # kicking them now means the first missing-subtitle search runs
  # against the full library instead of an empty one.
  def self.sync_libraries_and_search_for_missing_subtitles
    run_task("update_series")
    run_task("update_movies")
    run_task("wanted_search_missing_subtitles_series")
    run_task("wanted_search_missing_subtitles_movies")
  end

  def self.run_task(task_id)
    http(:post, "#{BASE_URL}/api/system/tasks?taskid=#{task_id}",
         body: "", headers: { "X-API-KEY" => api_key })
  end
end
