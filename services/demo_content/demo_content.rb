require "etc"
require "securerandom"

module DemoContent
  SERVICE_DIR        = __dir__
  CONFIG_DIR         = File.join(Dir.home, "hdds/.config/demo")
  LIVE_HOSTNAME_FILE = File.join(CONFIG_DIR, "live_hostname")
  ACCOUNT_FILE       = File.join(Dir.home, "hdds/.config/depot/demo-account.env")
  LIVE_DIR           = File.join(Dir.home, "hdds/demo/live")
  STREAM_DIR         = File.join(LIVE_DIR, "stream")
  LOOP_FILE          = File.join(LIVE_DIR, "loop.mp4")
  SECTIONS_TEMPLATE  = File.join(SERVICE_DIR, "sections.json")
  RESTOCK_SCRIPT     = "/usr/local/lib/depot/restock-demo-account.sh"
  UNITS_DIR          = "/etc/systemd/system"

  LIVE_PORT                 = 8097
  ACCOUNT_NAME              = "guest"
  TYPEABLE_PASSWORD_LENGTH  = 10
  SECONDS_TO_WAIT_FOR_SCAN  = 180

  BLENDER = "https://download.blender.org/demo/movies"
  ARCHIVE = "https://archive.org/download"

  MOVIES = [
    { title: "Big Buck Bunny (2008)", extension: "mp4", zipped: true,
      url: "#{BLENDER}/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip" },
    { title: "Sintel (2010)", extension: "mkv", zipped: false,
      url: "#{BLENDER}/Sintel.2010.1080p.mkv" },
    { title: "Tears of Steel (2012)", extension: "mov", zipped: true,
      url: "#{BLENDER}/ToS/tears_of_steel_1080p.mov.zip" },
    { title: "Night of the Living Dead (1968)", extension: "mp4", zipped: false,
      url: "#{ARCHIVE}/Night.Of.The.Living.Dead_1080p/NightOfTheLivingDead_1080p.mp4" },
    { title: "His Girl Friday (1940)", extension: "mp4", zipped: false,
      url: "#{ARCHIVE}/his_girl_friday/his_girl_friday.mp4" },
  ].freeze

  FILMS_IN_THE_LIVE_LOOP = ["Big Buck Bunny (2008)", "Sintel (2010)", "Tears of Steel (2012)"].freeze

  SERIES_TITLE        = "Sherlock Holmes (1954)"
  SERIES_ARCHIVE_ITEM = "SherlockHolmes1954"
  SERIES_EPISODE_FILE = /\ASherlock Holmes (\d{2}) .*\.mp4\z/

  def self.install_prompt
    return { demo_live_hostname: live_hostname } unless live_hostname.empty?

    {
      demo_live_hostname: prompt(
        preamble: <<~TEXT.chomp,
          Live stream hostname:
            The demo's live section plays its own films in a loop. Add a
            third Public Hostname to the same Cloudflare tunnel:
              Service: Type HTTP, URL http://localhost:#{LIVE_PORT}
            Then enter the full hostname below. No https://.
        TEXT
        question: "Live stream hostname",
      ),
    }
  end

  def self.install(prompts)
    FileUtils.mkdir_p(CONFIG_DIR)
    File.write(LIVE_HOSTNAME_FILE, prompts[:demo_live_hostname].to_s + "\n")
    stock_the_server
  end

  def self.update
    stock_the_server
  end

  def self.summary
    return unless File.file?(ACCOUNT_FILE)
    puts "Demo account:   #{ACCOUNT_NAME} (password in #{ACCOUNT_FILE})"
    puts "Demo live loop: https://#{live_hostname}/live.m3u8" unless live_hostname.empty?
  end

  def self.stock_the_server
    ensure_pacman_installed "ffmpeg", "jq", "sqlite", "unzip", "curl"
    fetch_the_movies
    fetch_the_series
    have_jellyfin_index_everything
    play_the_films_as_a_live_stream
    define_the_live_and_series_sections
    create_the_account
    keep_the_account_in_order
  end

  def self.account_depot_runs_as
    Etc.getpwuid(Process.uid).name
  end

  def self.live_hostname
    File.file?(LIVE_HOSTNAME_FILE) ? File.read(LIVE_HOSTNAME_FILE).strip : ""
  end

  def self.movie_file(movie)
    File.join(Jellyfin::MOVIES_DIR, movie[:title], "#{movie[:title]}.#{movie[:extension]}")
  end

  def self.download(url, destination)
    FileUtils.mkdir_p(File.dirname(destination))
    partial = "#{destination}.partial"
    sh!("curl -fL --retry 5 --retry-delay 10 -C - -sS -o #{shellescape(partial)} #{shellescape(url)}")
    File.rename(partial, destination)
  end

  def self.fetch_the_movies
    MOVIES.each do |movie|
      next if File.file?(movie_file(movie))
      puts "  fetching #{movie[:title]}"
      movie[:zipped] ? download_and_unzip(movie) : download(movie[:url], movie_file(movie))
    end
  end

  def self.download_and_unzip(movie)
    archive   = "#{movie_file(movie)}.zip"
    unpacked  = "#{archive}.unpacked"
    download(movie[:url], archive)
    sh!("unzip -o -q #{shellescape(archive)} -d #{shellescape(unpacked)}")
    File.rename(Dir[File.join(unpacked, "**", "*.#{movie[:extension]}")].first, movie_file(movie))
    FileUtils.rm_rf([archive, unpacked])
  end

  def self.fetch_the_series
    season = File.join(Jellyfin::SHOWS_DIR, SERIES_TITLE, "Season 01")
    series_files_on_the_archive.each do |name|
      episode     = name[SERIES_EPISODE_FILE, 1]
      destination = File.join(season, "#{SERIES_TITLE} - S01E#{episode}.mp4")
      next if File.file?(destination)
      puts "  fetching #{SERIES_TITLE} episode #{episode}"
      download("#{ARCHIVE}/#{SERIES_ARCHIVE_ITEM}/#{URI.encode_www_form_component(name).gsub("+", "%20")}", destination)
    end
  end

  def self.series_files_on_the_archive
    listing, _status = capture("curl -fsSL https://archive.org/metadata/#{SERIES_ARCHIVE_ITEM}")
    JSON.parse(listing).fetch("files").map { |file| file["name"] }.grep(SERIES_EPISODE_FILE)
  end

  def self.jellyfin_headers
    { "X-Emby-Token" => Jellyfin.api_key_for("aviary") }
  end

  def self.titles_jellyfin_lists
    listed = http_get_json("#{Jellyfin::BASE_URL}/Items?Recursive=true&IncludeItemTypes=Movie,Series",
                           headers: jellyfin_headers)
    listed ? listed.fetch("Items").length : 0
  end

  def self.have_jellyfin_index_everything
    everything = MOVIES.length + [SERIES_TITLE].length
    return if titles_jellyfin_lists >= everything

    http(:post, "#{Jellyfin::BASE_URL}/Library/Refresh", headers: jellyfin_headers)
    SECONDS_TO_WAIT_FOR_SCAN.times do
      return if titles_jellyfin_lists >= everything
      sleep 1
    end
    puts "  WARN: Jellyfin hasn't listed every title yet; the hourly account job will catch up"
  end

  def self.play_the_films_as_a_live_stream
    FileUtils.mkdir_p(STREAM_DIR)
    build_the_loop unless File.file?(LOOP_FILE)
    install_root_file(File.join(UNITS_DIR, "demo-live-loop.service"), content: live_loop_unit)
    sudo!("systemctl daemon-reload")
    sudo!("systemctl enable --now demo-live-loop.service")
    cleanup_stale_container("demo-live")
    compose_up!("demo_content", env: {
      "LIVE_PORT"  => LIVE_PORT,
      "STREAM_DIR" => STREAM_DIR,
      "CADDYFILE"  => File.join(SERVICE_DIR, "Caddyfile"),
    })
  end

  def self.build_the_loop
    puts "  encoding the live loop"
    seconds_between_keyframes = 2
    frames_per_second         = 30
    frames_between_keyframes  = seconds_between_keyframes * frames_per_second
    same_frame = "scale=1280:720:force_original_aspect_ratio=decrease," \
                 "pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=#{frames_per_second},format=yuv420p"
    same_sound = "aresample=48000,aformat=channel_layouts=stereo"
    films      = MOVIES.select { |movie| FILMS_IN_THE_LIVE_LOOP.include?(movie[:title]) }
    inputs     = films.map { |film| "-i #{shellescape(movie_file(film))}" }.join(" ")
    normalized = films.each_index.map { |i| "[#{i}:v:0]#{same_frame}[v#{i}];[#{i}:a:0]#{same_sound}[a#{i}]" }.join(";")
    in_order   = films.each_index.map { |i| "[v#{i}][a#{i}]" }.join
    partial    = "#{LOOP_FILE}.partial.mp4"

    sh!("ffmpeg -y -hide_banner -loglevel error #{inputs} " \
        "-filter_complex #{shellescape("#{normalized};#{in_order}concat=n=#{films.length}:v=1:a=1[v][a]")} " \
        "-map '[v]' -map '[a]' -c:v libx264 -preset veryfast -b:v 3500k -maxrate 4000k -bufsize 8000k " \
        "-g #{frames_between_keyframes} -keyint_min #{frames_between_keyframes} -sc_threshold 0 " \
        "-c:a aac -b:a 160k -movflags +faststart #{shellescape(partial)}")
    File.rename(partial, LOOP_FILE)
  end

  def self.live_loop_unit
    <<~UNIT
      [Unit]
      Description=Play the demo films as a continuous live stream

      [Service]
      User=#{account_depot_runs_as}
      ExecStartPre=/usr/bin/find #{STREAM_DIR} -type f -delete
      ExecStart=/usr/bin/ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i #{LOOP_FILE} -c copy -f hls -hls_time 4 -hls_list_size 6 -hls_flags delete_segments+omit_endlist -hls_segment_filename #{STREAM_DIR}/segment-%%05d.ts #{STREAM_DIR}/live.m3u8
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    UNIT
  end

  def self.define_the_live_and_series_sections
    sections_file = File.join(Aviary::AVIARY_DATA_DIR, "sections.json")
    FileUtils.mkdir_p(File.dirname(sections_file))
    File.write(sections_file, File.read(SECTIONS_TEMPLATE).gsub("__LIVE_HOSTNAME__", live_hostname))
  end

  def self.account_id
    accounts = http_get_json("#{Jellyfin::BASE_URL}/Users", headers: jellyfin_headers) || []
    accounts.find { |account| account["Name"] == ACCOUNT_NAME }&.fetch("Id")
  end

  def self.create_the_account
    return if account_id

    password = SecureRandom.alphanumeric(TYPEABLE_PASSWORD_LENGTH).downcase
    write_env_file(ACCOUNT_FILE, "DEMO_USERNAME" => ACCOUNT_NAME, "DEMO_PASSWORD" => password)
    File.chmod(0o600, ACCOUNT_FILE)

    created = JSON.parse(http(:post, "#{Jellyfin::BASE_URL}/Users/New",
                              body: { "Name" => ACCOUNT_NAME, "Password" => password },
                              headers: jellyfin_headers).body)
    http(:post, "#{Jellyfin::BASE_URL}/Users/#{created["Id"]}/Policy", headers: jellyfin_headers,
         body: created["Policy"].merge(
           "IsAdministrator"          => false,
           "IsHidden"                 => true,
           "EnableAllFolders"         => true,
           "EnableContentDeletion"    => false,
           "EnableContentDownloading" => false,
           "EnableRemoteAccess"       => true,
         ))
    http(:post, "#{Jellyfin::BASE_URL}/Users/#{created["Id"]}/Configuration", headers: jellyfin_headers,
         body: created["Configuration"].merge(
           "AudioLanguagePreference" => "eng",
           "PlayDefaultAudioTrack"   => false,
         ))
  end

  def self.keep_the_account_in_order
    sudo!("mkdir -p #{File.dirname(RESTOCK_SCRIPT)}")
    install_root_file(RESTOCK_SCRIPT, from: File.join(SERVICE_DIR, "restock-demo-account.sh"), mode: "0755")
    install_root_file(File.join(UNITS_DIR, "restock-demo-account.service"), content: <<~UNIT)
      [Unit]
      Description=Put the demo account back in order

      [Service]
      Type=oneshot
      User=#{account_depot_runs_as}
      ExecStart=#{RESTOCK_SCRIPT}
    UNIT
    install_root_file(File.join(UNITS_DIR, "restock-demo-account.timer"), content: <<~UNIT)
      [Unit]
      Description=Put the demo account back in order every hour

      [Timer]
      OnCalendar=hourly
      Persistent=true

      [Install]
      WantedBy=timers.target
    UNIT
    sudo!("systemctl daemon-reload")
    sudo!("systemctl enable --now restock-demo-account.timer")
    sudo!("systemctl start restock-demo-account.service")
  end
end
