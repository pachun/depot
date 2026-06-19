# unpackerr — extraction sidecar for Sonarr and Radarr. Watches their
# finished folders, unpacks any release that arrived as a multi-volume
# archive, and tells the arr to import the extracted media.
#
# No UI. The compose file mounts the sonarr/radarr config dirs and
# the seeding dir. SONARR_API_KEY and RADARR_API_KEY come from
# whichever config.xml was written by Sonarr.install / Radarr.install
# earlier in this run.

module Unpackerr
  def self.install_prompt
    {}
  end

  def self.install(prompts)
    compose_up!("unpackerr", env: {
      "PUID" => Process.uid,
      "PGID" => Process.gid,
      "TZ"   => `timedatectl show -p Timezone --value`.strip,
      "SONARR_API_KEY" => Sonarr.api_key.to_s,
      "RADARR_API_KEY" => Radarr.api_key.to_s,
    })
  end

  def self.update
    install({})
  end

  def self.summary
    if `docker ps --format '{{.Names}}'`.lines.map(&:strip).include?("unpackerr")
      puts "Unpackerr:      running"
    else
      puts "Unpackerr:      not running"
    end
  end
end
