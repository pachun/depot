# sabnzbd — Usenet downloader. Fetches NZBs sent by Sonarr/Radarr,
# pulls binaries from Frugal Usenet's servers, decodes the yEnc
# binaries, reassembles, and hands the finished file to the arr for
# import. No UI access from outside; exposed on the tailnet only.
#
# Tailscale serves on 8086 (not 8085) because 8085 is docker-proxy's
# host bind for the container's WebUI. Different host ports = docker
# restart and tailscale serve don't fight over the port.

module Sabnzbd
  CONFIG_DIR     = File.join(Dir.home, "hdds/.config/sabnzbd")
  CONFIG_INI     = File.join(CONFIG_DIR, "sabnzbd.ini")
  USENET_ENV     = File.join(Dir.home, "hdds/.config/depot/usenet.env")
  LOCAL_PORT     = 8085
  TAILSCALE_PORT = 8086
  BASE_URL       = "http://localhost:8085"
  PROMPT_CACHE   = File.join(Dir.home, "hdds/.config/depot/sabnzbd.env")

  def self.install_prompt
    cached = read_env_file(PROMPT_CACHE)
    answers = {}
    answers[:usenet_username] = cached["USENET_USERNAME"].to_s.empty? ?
      prompt(preamble: "Frugal Usenet:",
             question: "Username (newsreader user, not your email)") :
      cached["USENET_USERNAME"]
    answers[:usenet_password] = cached["USENET_PASSWORD"].to_s.empty? ?
      prompt(question: "Password", secret: true, verify: true) :
      cached["USENET_PASSWORD"]
    answers
  end

  def self.install(prompts)
    write_env_file(PROMPT_CACHE,
      "USENET_USERNAME" => prompts[:usenet_username],
      "USENET_PASSWORD" => prompts[:usenet_password],
    )

    FileUtils.mkdir_p([CONFIG_DIR, File.join(Dir.home, "downloading/usenet")])

    # Tailnet FQDN goes into host_whitelist so SABnzbd doesn't reject
    # the reverse-proxied request with "host not in whitelist".
    fqdn = `tailscale status --json 2>/dev/null`.then { |j|
      JSON.parse(j).dig("Self", "DNSName").to_s.chomp(".") rescue ""
    }

    seed_config_ini(fqdn, prompts[:usenet_username], prompts[:usenet_password])
    repair_host_whitelist(fqdn)

    # Tailscale serve at 8085 used to collide with docker-proxy's host
    # bind. Tear down that old mapping so a re-creation cycle works.
    free_tailscale_port(8085)

    # Defensive: a failed docker restart can leave the container in
    # "Up" but with no port bindings.
    ports = `docker ps --filter name=sabnzbd --format '{{.Ports}}'`
    if !ports.empty? && !ports.include?("8085")
      puts "  sabnzbd container's port mapping is missing — recreating"
      sh!("docker rm -f sabnzbd >/dev/null")
    end

    compose_up!("sabnzbd", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)

    sab_key = api_key_from_ini
    if sab_key.nil?
      puts "  WARN: no api_key in sabnzbd.ini — skipping wiring"
      return
    end

    puts "  waiting for SABnzbd API..."
    unless wait_for_http("#{BASE_URL}/api?mode=version&apikey=#{sab_key}&output=json", timeout: 60)
      puts "  WARN: SABnzbd API didn't respond within 60s — skipping arr wiring"
      return
    end

    push_creds_via_api(sab_key, prompts[:usenet_username], prompts[:usenet_password])

    # mode=restart applies config changes in place (sidesteps docker
    # cycle's port-already-bound dance).
    http(:get, "#{BASE_URL}/api?mode=restart&apikey=#{sab_key}&output=json")
    sleep 2
    wait_for_http("#{BASE_URL}/api?mode=version&apikey=#{sab_key}&output=json", timeout: 30)

    register_as_arr_download_client(Sonarr::BASE_URL, "v3", Sonarr.api_key, sab_key, "tv")
    register_as_arr_download_client(Radarr::BASE_URL, "v3", Radarr.api_key, sab_key, "movies")
  end

  def self.update
    cleanup_stale_container("sabnzbd")
    free_tailscale_port(8085)
    compose_up!("sabnzbd", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
    })
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "SABnzbd:        #{url}" unless url.empty?
  end

  # ============================================================
  # INI templating + credential rotation
  # ============================================================

  def self.seed_config_ini(fqdn, username, password)
    return if File.file?(CONFIG_INI)
    sab_key = `openssl rand -hex 16`.strip
    whitelist = "#{fqdn}, #{`hostname`.strip}, localhost, host.docker.internal"
    File.open(CONFIG_INI, "w", 0o600) do |f|
      f.write(<<~INI)
        [misc]
        api_key = #{sab_key}
        nzb_key = #{sab_key}
        host = 0.0.0.0
        port = 8080
        download_dir = /usenet/incomplete
        complete_dir = /usenet
        host_whitelist = #{whitelist}
        api_logging = 0
        inet_exposure = 4

        [categories]
        [[tv]]
        priority = -100
        pp = 3
        name = tv
        dir = /usenet/tv
        [[movies]]
        priority = -100
        pp = 3
        name = movies
        dir = /usenet/movies

        [servers]
        [[frugal-primary]]
        host = news.frugalusenet.com
        port = 563
        connections = 75
        ssl = 1
        username =
        password =
        priority = 0
        enable = 1

        [[frugal-secondary]]
        host = eunews.frugalusenet.com
        port = 563
        connections = 30
        ssl = 1
        username =
        password =
        priority = 1
        enable = 1

        [[frugal-bonus]]
        host = bonus.frugalusenet.com
        port = 563
        connections = 50
        ssl = 1
        username =
        password =
        priority = 2
        enable = 1
      INI
    end
  end

  def self.repair_host_whitelist(fqdn)
    return if fqdn.empty? || !File.file?(CONFIG_INI)
    desired = "#{fqdn}, #{`hostname`.strip}, localhost, host.docker.internal"
    body = File.read(CONFIG_INI)
    return if body =~ /^host_whitelist = #{Regexp.escape(desired)}$/
    body.sub!(/^host_whitelist = .*$/, "host_whitelist = #{desired}")
    File.write(CONFIG_INI, body)
  end

  def self.api_key_from_ini
    return nil unless File.file?(CONFIG_INI)
    File.read(CONFIG_INI).each_line do |line|
      next unless line =~ /\Aapi_key\s*=\s*(\S+)/
      return $1
    end
    nil
  end

  # Push Frugal creds via SABnzbd's API rather than into the INI
  # directly — bash heredocs interpret `$`, backticks, and SABnzbd's
  # INI parser treats `#` as comment start, any of which silently
  # truncates a strong password.
  def self.push_creds_via_api(sab_key, username, password)
    %w[frugal-primary frugal-secondary frugal-bonus].each do |server|
      body = URI.encode_www_form(
        section: "servers",
        keyword: server,
        username: username,
        password: password,
        apikey:   sab_key,
      )
      http(:post, "#{BASE_URL}/api?mode=set_config",
           body: body,
           headers: { "Content-Type" => "application/x-www-form-urlencoded" })
    end
  end

  def self.register_as_arr_download_client(arr_base_url, api_version, arr_key, sab_key, category)
    return if arr_key.nil?
    payload = {
      "name" => "SABnzbd", "enable" => true, "protocol" => "usenet",
      "priority" => 1, "removeCompletedDownloads" => true,
      "removeFailedDownloads" => true,
      "implementation" => "Sabnzbd", "implementationName" => "SABnzbd",
      "configContract" => "SabnzbdSettings",
      "fields" => [
        { "name" => "host", "value" => "host.docker.internal" },
        { "name" => "port", "value" => 8085 },
        { "name" => "apiKey", "value" => sab_key },
        { "name" => "username", "value" => "" },
        { "name" => "password", "value" => "" },
        { "name" => "tvCategory", "value" => category },
        { "name" => "movieCategory", "value" => category },
        { "name" => "recentTvPriority", "value" => -100 },
        { "name" => "olderTvPriority", "value" => -100 },
        { "name" => "recentMoviePriority", "value" => -100 },
        { "name" => "olderMoviePriority", "value" => -100 },
        { "name" => "useSsl", "value" => false },
      ],
      "tags" => [],
    }
    arr_upsert_by_name(arr_base_url, "/api/#{api_version}/downloadclient",
                       arr_key, "SABnzbd", payload)
  end
end
