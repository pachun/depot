# storage — the NAS's two tiers of disk.
#
# 1. RAIDZ1 ZFS pool across the SATA HDDs at ~/hdds. One drive can
#    fail; swap it and the pool rebuilds. compression=lz4 (cheap),
#    atime=off (no metadata write per read), recordsize=1M (good for
#    media), ashift=12 (4K alignment), weekly scrub via systemd timer,
#    ZED on for disk-event logging.
#
# 2. ext4 on a non-boot NVMe at ~/downloading. Separate from the pool
#    so heavy random-write download workloads don't pound the HDDs.
#    Plain ext4; we don't need ZFS features for a transient staging
#    tier where loss just means re-downloading.
#
# ZFS itself comes from archzfs (precompiled `zfs-linux-lts` matched
# to each linux-lts release). The repo + GPG key are set up the first
# time this module runs. -Sy (not -Syu) so we don't pull in a newer
# kernel mid-install and drift out of sync with the precompiled
# module.

module Storage
  POOL_NAME         = "tank"
  ZFS_MOUNT         = File.join(Dir.home, "hdds")
  DOWNLOADING_MOUNT = File.join(Dir.home, "downloading")
  ARCHZFS_KEY       = "3A9917BF0DED5C13F69AC68FABEC0A1208037BE9"

  def self.install_prompt
    hdds = []
    if !system("sudo zpool list #{POOL_NAME}", out: File::NULL, err: File::NULL)
      hdds = pick_storage_hdds
    end
    ssd = nil
    if !`mountpoint -q #{DOWNLOADING_MOUNT} 2>/dev/null; echo $?`.strip.then { |s| s == "0" }
      ssd = pick_download_ssd
    end
    { selected_storage_hdds: hdds, selected_download_ssd: ssd }
  end

  def self.install(prompts)
    ensure_zfs_installed
    ensure_pacman_installed("jq", "sqlite", "openssl")
    disable_faillock
    create_zfs_pool(prompts[:selected_storage_hdds])
    format_download_ssd(prompts[:selected_download_ssd])
  end

  def self.update
  end

  def self.summary
    if system("sudo zpool list #{POOL_NAME}", out: File::NULL, err: File::NULL)
      size = `sudo zpool list -H -o size #{POOL_NAME}`.strip
      puts "Storage pool:   #{size} mounted at #{ZFS_MOUNT}"
    end
    if `mountpoint -q #{DOWNLOADING_MOUNT}; echo $?`.strip == "0"
      puts "Downloads:      #{DOWNLOADING_MOUNT}"
    end
  end

  # ------------------------------------------------------------
  # Prompt helpers
  # ------------------------------------------------------------

  def self.pick_storage_hdds
    available = list_storage_hdds
    if available.empty?
      puts "  No SATA spinning disks present — skipping pool creation."
      return []
    end

    preamble = "Storage HDDs:\n" +
      available.each_with_index.map { |name, i| disk_info_line(name, i + 1) }.join("\n")

    selected = prompt(
      preamble: preamble,
      question: "Pick storage HDDs (space-separated numbers)",
      parse:    parse_indices_against(available),
      confirm:  "destroy and create pool",
    )
    if selected.size < 3
      puts "  RAIDZ1 needs at least 3 disks; got #{selected.size}. Skipping pool creation."
      return []
    end
    selected
  end

  def self.pick_download_ssd
    available = list_download_ssd_candidates
    return nil if available.empty?

    preamble = "Non-boot NVMe drives:\n" +
      available.each_with_index.map { |name, i| disk_info_line(name, i + 1) }.join("\n")

    selected = prompt(
      preamble: preamble,
      question: "Pick the SSD for downloads (single number)",
      parse:    ->(input) {
        i = Integer(input.strip) rescue (raise "not a number: #{input}")
        raise "index out of range" unless (1..available.size).cover?(i)
        available[i - 1]
      },
      confirm:  "format ssd",
    )
    selected
  end

  # ------------------------------------------------------------
  # ZFS install
  # ------------------------------------------------------------

  def self.ensure_zfs_installed
    sudo!("pacman-key --recv-keys #{ARCHZFS_KEY}")
    sudo!("pacman-key --lsign-key #{ARCHZFS_KEY}")

    pacman_conf = File.read("/etc/pacman.conf") rescue ""
    unless pacman_conf =~ /^\[archzfs\]/
      tmp = "/tmp/archzfs.repo.#{Process.pid}"
      File.write(tmp, <<~REPO)

        [archzfs]
        SigLevel = Required
        Server = https://github.com/archzfs/archzfs/releases/download/experimental
      REPO
      sh!("sudo sh -c 'cat #{tmp} >> /etc/pacman.conf'")
      File.delete(tmp)
    end

    sudo!("pacman -Sy --needed --noconfirm zfs-linux-lts zfs-utils")
    unless `lsmod`.lines.any? { |l| l.start_with?("zfs") }
      sudo!("modprobe zfs")
    end
  end

  # ------------------------------------------------------------
  # Disable PAM faillock
  # ------------------------------------------------------------

  # Arch defaults to locking the account after 3 failed sudo password
  # attempts within 15 minutes; the lockout EXTENDS every time you
  # retry during it (the "wrong password" message during lockout
  # tricks muscle memory into immediate re-attempts that pile on more
  # lockout time). Single-user NAS behind LAN + tailscale + SSH key
  # auth doesn't need brute-force protection at the sudo layer.
  # deny=0 is the documented "never lock" setting.
  def self.disable_faillock
    conf = "/etc/security/faillock.conf"
    raise "expected #{conf} to exist (shipped by pam)" unless File.exist?(conf)
    sudo!("sed -i '/^[[:space:]]*deny[[:space:]]*=/d' #{conf}")
    sh!("echo 'deny = 0' | sudo tee -a #{conf} > /dev/null")
  end

  # ------------------------------------------------------------
  # Pool creation
  # ------------------------------------------------------------

  def self.create_zfs_pool(disks)
    if system("sudo zpool list #{POOL_NAME}", out: File::NULL, err: File::NULL)
      puts "  ZFS pool '#{POOL_NAME}' already exists — skipping."
      return
    end
    return if disks.nil? || disks.empty?

    disk_ids = disks.map { |name| stable_id_for(name) || raise("no by-id path for /dev/#{name}") }

    puts "  Creating RAIDZ1 pool '#{POOL_NAME}' across:"
    disk_ids.each { |id| puts "    #{id}" }

    sudo!(<<~CMD.gsub("\n", " ").strip)
      zpool create
        -o ashift=12
        -O compression=lz4
        -O atime=off
        -O recordsize=1M
        -O mountpoint=#{ZFS_MOUNT}
        #{POOL_NAME} raidz1 #{disk_ids.join(" ")}
    CMD

    sudo!("chown #{ENV["USER"]}:#{ENV["USER"]} #{ZFS_MOUNT}")
    sudo!("systemctl enable --now zfs-import-cache.service")
    sudo!("systemctl enable --now zfs-mount.service")
    sudo!("systemctl enable zfs.target")
    sudo!("systemctl enable --now zfs-scrub-weekly@#{POOL_NAME}.timer")
    sudo!("systemctl enable --now zfs-zed.service")
  end

  def self.stable_id_for(name)
    `find /dev/disk/by-id/ -maxdepth 1 -lname '*/#{name}'`
      .lines
      .map(&:strip)
      .find { |l| l =~ %r{/(ata|nvme)-} } || `find /dev/disk/by-id/ -maxdepth 1 -lname '*/#{name}'`.lines.first&.strip
  end

  # ------------------------------------------------------------
  # SSD formatting
  # ------------------------------------------------------------

  def self.format_download_ssd(name)
    return if name.nil?
    if `mountpoint -q #{DOWNLOADING_MOUNT}; echo $?`.strip == "0"
      puts "  #{DOWNLOADING_MOUNT} already mounted — skipping."
      return
    end

    dev    = "/dev/#{name}"
    id     = stable_id_for(name)

    puts "  Formatting #{dev} as ext4 → #{DOWNLOADING_MOUNT}"
    sudo!("mkfs.ext4 -F -L downloading #{dev}")
    sudo!("mkdir -p #{DOWNLOADING_MOUNT}")

    fstab_line = "#{id}  #{DOWNLOADING_MOUNT}  ext4  defaults,noatime  0  2"
    fstab = File.read("/etc/fstab") rescue ""
    unless fstab.include?(id)
      sh!("echo '#{fstab_line}' | sudo tee -a /etc/fstab >/dev/null")
    end

    sudo!("mount #{DOWNLOADING_MOUNT}")
    sudo!("chown #{ENV["USER"]}:#{ENV["USER"]} #{DOWNLOADING_MOUNT}")
  end
end
