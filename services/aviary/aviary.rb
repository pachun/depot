# aviary — Phoenix LiveView frontend that ties Jellyfin/Jellyseerr/
# Sonarr/Radarr together. Browse your library, mark watch progress,
# request new titles, see download status. The user-visible URL of
# depot: aviary lives at https://<hostname>.<tailnet>.ts.net/
# (HTTPS on 443, no port suffix).
#
# Build artifact: a Phoenix mix release inside a docker image,
# rebuilt from main on every install/update. SECRET_KEY_BASE and
# the Sonarr webhook secret are generated once and persisted; the
# other env vars (API keys for the upstream services) are harvested
# at runtime from each upstream's on-disk state. Aviary's data
# (sqlite db tracking watch progress + requests) lives under
# ~/hdds/.config/aviary/data.

module Aviary
  REPO_URL                = "https://github.com/pachun/aviary.git"
  # Pure git checkout — pre-build sources only. Lives alongside
  # ~/code/depot and ~/code/orchard rather than under ~/hdds, where the
  # data (db) and secrets persist. Re-cloning on OS reimage is cheap.
  SOURCE_DIR              = File.join(Dir.home, "code/aviary")
  SECRET_DIR              = File.join(Dir.home, "hdds/.config/aviary")
  AVIARY_ENV              = File.join(SECRET_DIR, ".env")
  SECRET_KEY_BASE_FILE    = File.join(SECRET_DIR, "secret_key_base")
  WEBHOOK_SECRET_FILE     = File.join(SECRET_DIR, "sonarr_webhook_secret")
  AVIARY_DATA_DIR         = File.join(SECRET_DIR, "data")
  LOCAL_PORT              = 4000
  TAILSCALE_PORT          = 443

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    FileUtils.mkdir_p([File.dirname(SOURCE_DIR), SECRET_DIR, AVIARY_DATA_DIR])
    clone_or_pull
    generate_secrets

    jellyfin_api_key = Jellyfin.api_key_for("aviary")
    if jellyfin_api_key.nil?
      puts "  skipped: no 'aviary' API key in Jellyfin yet (was Jellyfin wizard run?)"
      return
    end

    bring_up(jellyfin_api_key)
    register_sonarr_webhook
  end

  def self.update
    clone_or_pull

    jellyfin_api_key = Jellyfin.api_key_for("aviary")
    if jellyfin_api_key.nil?
      puts "  skipped: no 'aviary' API key in Jellyfin"
      return
    end
    bring_up(jellyfin_api_key)
  end

  def self.summary
    url = tailscale_url(TAILSCALE_PORT)
    puts "Aviary:         #{url}" unless url.empty?
  end

  # ============================================================
  # Source clone / pull
  # ============================================================

  def self.clone_or_pull
    FileUtils.mkdir_p(File.dirname(SOURCE_DIR))
    if Dir.exist?(File.join(SOURCE_DIR, ".git"))
      sh!("git -C #{SOURCE_DIR} fetch origin main")
      sh!("git -C #{SOURCE_DIR} reset --hard origin/main")
    else
      sh!("git clone #{REPO_URL} #{SOURCE_DIR}")
    end
  end

  # ============================================================
  # Secrets
  # ============================================================

  def self.generate_secrets
    unless File.file?(SECRET_KEY_BASE_FILE)
      key = `openssl rand -base64 48`.strip
      File.write(SECRET_KEY_BASE_FILE, key, perm: 0o600)
    end
    unless File.file?(WEBHOOK_SECRET_FILE)
      File.write(WEBHOOK_SECRET_FILE, `openssl rand -hex 32`.strip + "\n", perm: 0o600)
    end
  end

  # ============================================================
  # Bring up
  # ============================================================

  def self.bring_up(jellyfin_api_key)
    secret_key_base       = File.read(SECRET_KEY_BASE_FILE).strip
    sonarr_webhook_secret = File.read(WEBHOOK_SECRET_FILE).strip
    jellyseerr_api_key    = Jellyseerr.api_key.to_s
    sonarr_api_key        = Sonarr.api_key.to_s
    radarr_api_key        = Radarr.api_key.to_s

    # Re-write .env from scratch every run (no stale-cache leak —
    # earlier versions cached and once cached, a wiped Jellyfin
    # would still see the old api key here).
    File.open(AVIARY_ENV, "w", 0o600) do |f|
      f.puts "JELLYFIN_API_KEY=#{jellyfin_api_key}"
      f.puts "JELLYSEERR_API_KEY=#{jellyseerr_api_key}"
      f.puts "SONARR_API_KEY=#{sonarr_api_key}"
      f.puts "RADARR_API_KEY=#{radarr_api_key}"
    end

    tailscale_host = `tailscale status --json 2>/dev/null`.then { |j|
      JSON.parse(j).dig("Self", "DNSName").to_s.chomp(".") rescue ""
    }
    tailscale_host = Socket.gethostname if tailscale_host.empty?

    # PHX_HOST controls aviary's URL generation (redirects, link
    # rendering). If Cloudflare Tunnel is configured with a public
    # hostname, use that as the canonical URL — family members visit
    # https://<your-domain> via Cloudflare. Tailscale URL still works
    # for tailnet-internal access; the check_origin list (set below)
    # accepts both.
    phx_host = Cloudflare.public_hostname || tailscale_host

    # Jellyfin's public URL stays on the tailscale URL — Jellyfin
    # isn't fronted by Cloudflare, only aviary is. The video
    # player hits Jellyfin directly via Tailscale Serve at :8443.
    jellyfin_public_url = "https://#{tailscale_host}:#{Jellyfin::TAILSCALE_PORT}"

    free_tailscale_port(TAILSCALE_PORT)
    compose_up!("aviary", build: true, env: {
      "TZ"                    => `timedatectl show -p Timezone --value`.strip,
      "SRC"                   => SOURCE_DIR,
      "SECRET_KEY_BASE"       => secret_key_base,
      "PHX_HOST"              => phx_host,
      # Comma-separated list of additional hostnames that LiveView's
      # check_origin should allow for WebSocket upgrades. PHX_HOST
      # is implicitly allowed; this is for the OTHER URL someone
      # might hit aviary at (tailscale URL if PHX_HOST is the
      # custom domain, or vice versa).
      "CHECK_ORIGINS"         => [phx_host, tailscale_host].uniq.join(","),
      "JELLYFIN_URL"          => "http://host.docker.internal:8096",
      "JELLYFIN_PUBLIC_URL"   => jellyfin_public_url,
      "JELLYFIN_API_KEY"      => jellyfin_api_key,
      "JELLYSEERR_URL"        => "http://host.docker.internal:5055",
      "JELLYSEERR_API_KEY"    => jellyseerr_api_key,
      "SONARR_URL"            => "http://host.docker.internal:8989",
      "SONARR_API_KEY"        => sonarr_api_key,
      "SONARR_WEBHOOK_SECRET" => sonarr_webhook_secret,
      "RADARR_URL"            => "http://host.docker.internal:7878",
      "RADARR_API_KEY"        => radarr_api_key,
      "AVIARY_DATA_DIR"       => AVIARY_DATA_DIR,
      "HOST_UID"              => Process.uid,
      "HOST_GID"              => Process.gid,
      # Usable tank capacity in bytes (post-RAIDZ1 parity, post-ZFS
      # overhead). `zfs list -H -p -o avail,used` returns AVAIL + USED
      # in bytes, no formatting. Their sum is what the pool can
      # actually hold; zpool list would show RAW (sum of all disk
      # sizes) which over-counts by one disk's worth of parity.
      # Aviary's Settings page Storage panel uses this to scale the
      # stacked bar to a real "% of tank used."
      "TANK_BYTES"            => Storage.usable_tank_bytes.to_s,
      # Hours between last-subscriber-removal and auto-delete of the
      # on-disk media (only when downloaded via Usenet — torrents are
      # left alone to preserve seeding). Bump this for a wider undo
      # window, lower it if disk pressure is tight.
      "DELETION_GRACE_PERIOD_HOURS" => "24",
    })

    # Wait for Phoenix to actually accept connections before migrating.
    # `docker-compose up -d` returns when the container starts, not when
    # Phoenix is listening; `bin/aviary eval` against an un-booted
    # release exits non-zero.
    puts "  waiting for aviary endpoint..."
    wait_for_http("http://localhost:#{LOCAL_PORT}/", timeout: 60)
    sh!("sudo docker exec aviary bin/aviary eval 'Aviary.Release.migrate()'")
    forward_port_to_tailscale(local_port: LOCAL_PORT, tailscale_port: TAILSCALE_PORT)
    # Public access for non-tailnet family. Activates only if the
    # tailnet's ACL grants this device funnel capability (admin console
    # → ACL → nodeAttrs target this machine, attr "funnel"). Otherwise
    # a silent no-op. See README for the one-time admin console step.
    forward_port_to_internet(local_port: LOCAL_PORT)
  end

  # ============================================================
  # Sonarr webhook registration
  # ============================================================

  # Register an Aviary-receiving notification in Sonarr so health-events
  # fire to /api/sonarr/webhook with the shared secret. Aviary uses
  # OnHealthRestored + OnApplicationUpdate to re-fire EpisodeSearch for
  # grabs that failed during an unhealthy window.
  def self.register_sonarr_webhook
    sonarr_key = Sonarr.api_key
    return if sonarr_key.nil?
    secret = File.read(WEBHOOK_SECRET_FILE).strip
    payload = {
      "name" => "Aviary",
      "implementation" => "Webhook", "implementationName" => "Webhook",
      "configContract" => "WebhookSettings", "tags" => [],
      "fields" => [
        { "name" => "url", "value" => "http://host.docker.internal:4000/api/sonarr/webhook" },
        { "name" => "method", "value" => 1 },
        { "name" => "username", "value" => "" },
        { "name" => "password", "value" => "" },
        { "name" => "headers", "value" => [{ "key" => "x-aviary-secret", "value" => secret }] },
      ],
      "onGrab" => false, "onDownload" => false, "onUpgrade" => false,
      "onRename" => false, "onSeriesAdd" => false, "onSeriesDelete" => false,
      "onEpisodeFileDelete" => false, "onEpisodeFileDeleteForUpgrade" => false,
      "onHealthIssue" => false, "onHealthRestored" => true,
      "onApplicationUpdate" => true,
      "onManualInteractionRequired" => false,
      "supportsOnGrab" => true, "supportsOnDownload" => true,
      "supportsOnHealthIssue" => true, "supportsOnHealthRestored" => true,
      "supportsOnApplicationUpdate" => true,
    }
    arr_upsert_by_name("#{Sonarr::BASE_URL}", "/api/v3/notification",
                       sonarr_key, "Aviary", payload)
  end
end
