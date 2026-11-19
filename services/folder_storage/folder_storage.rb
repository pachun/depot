# folder storage — a plain folder at ~/hdds on the machine's own drive.
#
# What a demo server uses in place of the NAS's ZFS pool: every service
# keeps its config and media under ~/hdds exactly as it does on a NAS,
# so nothing else in depot has to know which kind of disk is beneath it.
module FolderStorage
  FOLDER             = File.join(Dir.home, "hdds")
  BYTES_PER_KILOBYTE = 1024

  def self.install_prompt
    {}
  end

  def self.install(prompts)
    ensure_pacman_installed("jq", "sqlite", "openssl")
    FileUtils.mkdir_p(FOLDER)
  end

  def self.update
  end

  def self.summary
    puts "Storage folder: #{FOLDER}"
  end

  def self.usable_bytes
    kilobytes_on_the_drive = `df --output=size -k #{FOLDER} 2>/dev/null`.lines.last.to_i
    kilobytes_on_the_drive * BYTES_PER_KILOBYTE
  end
end
