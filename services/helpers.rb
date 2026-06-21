# helpers.rb — utilities shared by depot's entry-point script and every
# service module. Sourced from depot at startup; the methods become
# top-level (available everywhere) and the constants are namespaced
# under module Helpers for the rare case of disambiguation.

require 'json'
require 'net/http'
require 'open3'
require 'uri'
require 'io/console'
require 'fileutils'
require 'readline'
require 'socket'
require 'stringio'
require 'io/console'

# ============================================================
# Shell helpers
# ============================================================

# Braille pattern that reads as a smooth rotating animation in a
# monospaced terminal — same set Docker / Heroku use.
SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

# Runs `yield` with a single spinner on the current line, labeled as
# the top-level action ("Aviary update", "Sonarr install", "depot
# update"). For the duration of the block:
#
#   - $stdout is redirected to a buffer, so any `puts`/`print` from
#     inside the operation is captured silently rather than breaking
#     the spinner's \r-based redraw.
#   - The spinner thread writes to a saved reference to the real
#     STDOUT (the terminal), bypassing the redirection so it stays
#     visible.
#
# On success: the spinner's line collapses to `✓ <label>.`
# On failure: collapses to `✗ <label>.`, dumps the captured output
# beneath it so the actual error is visible, then re-raises.
#
# Non-TTY (piped output, CI): falls through to plain text so logs
# stay greppable.
def with_spinner(label)
  unless STDOUT.tty?
    puts "  #{present_progressive(label)}..."
    yield
    puts "  #{past_tense(label)}."
    return
  end

  # Truncate to fit terminal width — a label wider than the terminal
  # wraps onto a second visual line, and our \r-based redraw then
  # targets the wrapped row only, leaving prior frames in scrollback.
  cols = (IO.console.winsize[1] rescue 80)
  # Account for "X " prefix (no leading indent now) + 1 margin column.
  max = [cols - 3, 20].max

  # Three forms of the label, derived from the single "Subject verb"
  # input (e.g., "Aviary update"):
  #   active → "Updating Aviary"      (spinning)
  #   done   → "Aviary updated"       (success)
  #   failed → "Aviary update failed" (failure)
  active = truncate_for_terminal(present_progressive(label), max)
  done   = truncate_for_terminal(past_tense(label), max)
  failed = truncate_for_terminal("#{label} failed", max)

  # STDOUT (constant) writes always reach the terminal — they're
  # unaffected by `$stdout = buffer` below. The block's puts/print
  # calls go through $stdout, into the buffer, so they don't break
  # the spinner.
  buffer = StringIO.new

  # Hide the terminal cursor for the duration of the spinner. \e[?25l
  # hides, \e[?25h restores. Without this, the blinking cursor sits at
  # the end of the spinner line ("Updating aviary█") and visually
  # competes with the spinning glyph. Restore happens in the ensure
  # block so it survives exceptions; the SIGINT trap in `depot` also
  # restores so Ctrl-C never leaves the cursor hidden.
  STDOUT.print("\e[?25l")
  STDOUT.flush

  running = true
  thread = Thread.new do
    i = 0
    while running
      STDOUT.print("\r\e[2K#{SPINNER_FRAMES[i % SPINNER_FRAMES.size]} #{active}")
      STDOUT.flush
      sleep(0.1)
      i += 1
    end
  end

  original_stdout = $stdout
  $stdout = buffer
  success = false

  begin
    yield
    success = true
  ensure
    running = false
    thread.join
    $stdout = original_stdout

    if success
      STDOUT.print("\r\e[2K✓ #{done}.\n")
    else
      STDOUT.print("\r\e[2K✗ #{failed}.\n")
      STDOUT.print(buffer.string) unless buffer.string.empty?
    end
    STDOUT.print("\e[?25h")  # restore cursor
    STDOUT.flush
  end
end

def truncate_for_terminal(str, max)
  str.length > max ? "#{str[0, max - 3]}..." : str
end

# Convert the last word of a "Subject verb" label to present
# progressive, with the verbing in front:
#   "Aviary update"   → "Updating Aviary"
#   "Storage install" → "Installing Storage"
#   "depot update"    → "Updating depot"
# "update" → "updating" (drop trailing "e"); "install" → "installing".
def present_progressive(label)
  parts = label.split
  return label if parts.empty?
  verb = parts.pop
  ing = (verb.end_with?("e") ? verb[0..-2] : verb) + "ing"
  ([ing.capitalize] + parts).join(" ")
end

# Append "ed" / "d" to the last word of a label so the completion
# line reads as past tense:
#   "depot update"    → "depot updated"
#   "Aviary update"   → "Aviary updated"
#   "Storage install" → "Storage installed"
def past_tense(label)
  parts = label.split
  return label if parts.empty?
  last = parts.pop
  past = last.end_with?("e") ? "#{last}d" : "#{last}ed"
  (parts + [past]).join(" ")
end

# Execute a shell command silently. Captures stdout+stderr; on
# success, throws the output away. On failure, raises with the
# captured output embedded in the exception message so the caller
# (or with_spinner's failure path) can surface it.
def sh!(cmd)
  output, status = Open3.capture2e(cmd)
  return if status.success?

  message = "command failed: #{cmd}"
  message += "\n#{output.strip}" unless output.nil? || output.empty?
  raise message
end

# Run a shell command silently, raise on failure. For quiet
# idempotency-checks where we don't want to clutter output.
def sh_quiet!(cmd)
  unless system(cmd, out: File::NULL, err: File::NULL)
    raise "command failed: #{cmd}"
  end
end

# Same as sh!, but with a leading `sudo`.
def sudo!(cmd)
  sh!("sudo #{cmd}")
end

# Run a command, capture stdout/stderr, return [stdout, status]. Used
# when we need to look at the output before deciding what to do (e.g.
# `sudo docker inspect` to check container state).
def capture(cmd)
  stdout, _stderr, status = Open3.capture3(cmd)
  [stdout, status]
end

# ============================================================
# pacman + system assertions
# ============================================================

# Idempotent pacman install. Lists every package this caller depends on,
# at the top of every install method. Redundant declarations across
# modules are fine — they make each module self-contained, so removing
# one doesn't silently break others.
def ensure_pacman_installed(*pkgs)
  sudo!("pacman -S --needed --noconfirm #{pkgs.join(' ')}")
end

# Predicate: are all the named docker containers in `running` state?
# Returns false (with a warning printed) as soon as any one isn't.
# Pattern: `fail unless containers_are_running :jellyfin, :sonarr`
def containers_are_running(*names)
  names.all? do |name|
    stdout, status = capture("sudo docker inspect #{name} --format '{{.State.Status}}'")
    status.success? && stdout.strip == "running"
  end
end

# Convenience: raises with a clear message instead of returning false.
def fail_unless_containers_are_running(*names)
  names.each do |name|
    stdout, status = capture("sudo docker inspect #{name} --format '{{.State.Status}}'")
    if !status.success? || stdout.strip != "running"
      raise "container #{name} is not running (state: #{stdout.strip.inspect})"
    end
  end
end

# Remove a container if it exists but isn't currently running. Half-
# initialized containers from a previous failed run (Created, Restarting,
# Exited from a port-conflict abort) don't recover by being started —
# `docker-compose up -d` tries to start them as-is and they fail again.
# This nukes them so the next compose-up creates fresh.
def cleanup_stale_container(name)
  stdout, status = capture("sudo docker inspect #{name} --format '{{.State.Status}}'")
  return unless status.success?
  state = stdout.strip
  return if state == "running"
  sh_quiet!("sudo docker rm -f #{name}")
end

# ============================================================
# Tailscale helpers
# ============================================================

# Tear down tailscale's binding for a port BEFORE bringing the docker
# container up. Tailscaled binds tailnet-IP:PORT for each active serve
# mapping and that bind persists across container removals; a re-run
# that recreates the container then fails with "address already in use".
def free_tailscale_port(port)
  system("sudo tailscale serve --https=#{port} off", out: File::NULL, err: File::NULL)
end

# Re-establish a tailscale serve mapping AFTER the container is up.
# Reach the service from any tailnet device at
# https://<hostname>.<tailnet>.ts.net[:tailscale_port].
def forward_port_to_tailscale(local_port:, tailscale_port:)
  sudo!("tailscale serve --bg --https=#{tailscale_port} http://localhost:#{local_port}")
end

# Expose a serve mapping to the public internet via Tailscale Funnel.
# Reachability still uses the tailnet's https://<hostname>.<tailnet>.ts.net/
# URL — funnel doesn't generate a separate hostname. The operator
# decides who gets the URL.
#
# Whether this actually works is entirely controlled by the tailnet's
# ACL (admin console → ACL → nodeAttrs grants `funnel` to this device).
# If the ACL doesn't grant it, this command fails silently and the
# tailnet binding from forward_port_to_tailscale is unaffected.
def forward_port_to_internet(local_port:)
  system("sudo tailscale funnel --bg http://localhost:#{local_port}",
         out: File::NULL, err: File::NULL)
end

# Print the tailnet HTTPS URL for the given port. Empty string if
# tailscale isn't authenticated.
def tailscale_url(port)
  stdout, status = capture("tailscale status --json")
  return "" unless status.success?
  fqdn = JSON.parse(stdout).dig("Self", "DNSName").to_s.chomp(".")
  return "" if fqdn.empty?
  port.to_s == "443" ? "https://#{fqdn}" : "https://#{fqdn}:#{port}"
end

# ============================================================
# docker-compose
# ============================================================

# Run docker-compose up -d for the given service module. The compose
# file lives at services/<svc>/docker-compose.yml. The env hash is
# expanded as VAR=value before the sudo invocation — SETENV in
# sudoers (set during install/arch) lets these pass through.
# DEPOT_USER_HOME is also auto-added so compose's ${DEPOT_USER_HOME}
# substitution resolves to the caller's home (sudo special-cases HOME
# so we can't rely on it).
def compose_up!(service, env: {}, build: false)
  compose_file = File.join(__dir__, service.to_s, 'docker-compose.yml')
  env = { "DEPOT_USER_HOME" => Dir.home }.merge(env)
  env_str = env.map { |k, v| "#{k}=#{shellescape(v.to_s)}" }.join(' ')
  cmd = "sudo #{env_str} docker-compose -f #{compose_file} up -d"
  cmd += " --build" if build
  sh!(cmd)
end

# Minimal shellescape — wraps in single quotes, handles existing single
# quotes. Used internally; matches the Bash escape Ruby's Shellwords
# would produce but without pulling in the require.
def shellescape(s)
  return "''" if s.empty?
  "'" + s.gsub("'") { %q('\'') } + "'"
end

# ============================================================
# HTTP
# ============================================================

# Make an HTTP request. Returns the Net::HTTPResponse object (so callers
# can check `.code`, `.body`, `.code.to_i.between?(200, 299)`).
def http(method, url, body: nil, headers: {})
  uri = URI(url)
  req_class = {
    get:    Net::HTTP::Get,
    post:   Net::HTTP::Post,
    put:    Net::HTTP::Put,
    delete: Net::HTTP::Delete,
  }.fetch(method)
  req = req_class.new(uri)
  headers.each { |k, v| req[k.to_s] = v.to_s }
  if body
    req["Content-Type"] = headers["Content-Type"] || headers[:"Content-Type"] || "application/json"
    req.body = body.is_a?(String) ? body : JSON.generate(body)
  end
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                  open_timeout: 10, read_timeout: 30) do |http|
    http.request(req)
  end
rescue Errno::ECONNREFUSED,  # nothing listening yet
       Errno::ECONNRESET,    # server closed connection mid-handshake (LSIO containers do this during init)
       Errno::EHOSTUNREACH,  # no route
       Errno::ENETUNREACH,   # network unreachable
       Errno::EPIPE,         # write to closed socket
       EOFError,             # server died mid-response
       Net::OpenTimeout,
       Net::ReadTimeout
  nil
end

# GET and parse JSON. Returns parsed hash/array, or nil if request
# failed or body wasn't JSON.
def http_get_json(url, headers: {})
  resp = http(:get, url, headers: headers)
  return nil unless resp && resp.code.to_i.between?(200, 299)
  JSON.parse(resp.body) rescue nil
end

# Block until the given URL returns 2xx, or timeout.
def wait_for_http(url, timeout: 60, message: nil)
  puts message if message
  timeout.times do
    resp = http(:get, url)
    return true if resp && resp.code.to_i.between?(200, 299)
    sleep 1
  end
  false
end

# ============================================================
# Prompt
# ============================================================

# Interactive prompt. Returns the answer (parsed/transformed if a parser
# was supplied; raw string otherwise).
#
# Keyword args:
#   question:  the prompt text (required)
#   preamble:  a string printed before the question (e.g. a disk list).
#              Omit for plain questions.
#   secret:    hide input as the user types (passwords, API keys).
#   parse:     either a symbol naming a built-in parser (see PARSERS
#              below) or a proc. Parsers both validate and transform —
#              they return the value to assign to the constant. On a
#              parse failure they raise, and prompt re-asks (with a
#              brief error explanation) until the user gets it right or
#              Ctrl-C's out.
#   confirm:   a literal phrase the user must type back, used for
#              destructive actions ("destroy and create pool"). After
#              the parsed answer is collected, we ask the confirm
#              question; mismatch raises Aborted.
#   completion: :filename to enable tab path completion via Readline
#              (e.g. the WireGuard .conf path prompt). Default nil =
#              no completion.
#   verify:    true asks the user to re-enter their answer once and
#              re-prompts the whole thing on mismatch. For secret
#              inputs (passwords) where a typo would lock you out
#              with no way to see what you typed.
def prompt(question:, preamble: nil, secret: false, parse: nil, confirm: nil, completion: nil, verify: false)
  loop do
    if preamble
      puts
      puts preamble
    end

    raw = read_prompt_input("  #{question}: ", secret: secret, completion: completion)
    raise Interrupt if raw.nil?  # Ctrl-D
    raw = raw.chomp

    begin
      parsed = case parse
               when nil    then raw
               when Symbol then PARSERS.fetch(parse).call(raw)
               when Proc   then parse.call(raw)
               else raise "unknown parser type: #{parse.class}"
               end
    rescue => e
      puts "    -> #{e.message}"
      next
    end

    if verify
      check = read_prompt_input("  Confirm #{question.downcase}: ",
                                secret: secret, completion: completion)
      raise Interrupt if check.nil?
      if check.chomp != raw
        puts "    -> doesn't match, try again"
        next
      end
    end

    if confirm
      print "  Type '#{confirm}' to confirm: "
      typed = STDIN.gets.to_s.chomp
      if typed != confirm
        raise "Aborted (confirmation phrase did not match)"
      end
    end

    return parsed
  end
end

def read_prompt_input(line, secret:, completion:)
  if secret
    print line
    STDIN.noecho(&:gets).tap { puts }
  else
    Readline.completion_append_character = nil
    Readline.completion_proc = case completion
      when :filename
        ->(str) { Dir.glob("#{str}*").map { |f| File.directory?(f) ? "#{f}/" : f } }
      else
        ->(_str) { [] }
    end
    Readline.readline(line, false)
  end
end

# Built-in parsers. Each gets the raw input string, returns the parsed
# value, or raises with a one-line user-facing error message.
PARSERS = {
  # ProtonVPN WireGuard .conf — INI-shaped. Extracts PrivateKey and
  # Address from [Interface]; strips IPv6 from Addresses because
  # gluetun's default mode doesn't enable IPv6 inside the container
  # and a dual-stack Address line crashes it.
  wireguard_conf: ->(path) {
    path = File.expand_path(path)
    raise "no file at #{path}" unless File.file?(path)
    body = File.read(path).gsub("\r", "")
    private_key = body[/^\s*PrivateKey\s*=\s*(\S+)/, 1]
    addresses   = body[/^\s*Address\s*=\s*(\S.*)/, 1]
    raise "no PrivateKey in #{path}" if private_key.to_s.empty?
    raise "no Address in #{path}"    if addresses.to_s.empty?
    addresses = addresses.split(",").first.strip
    { private_key: private_key, addresses: addresses }
  },

  # A single non-empty line of text.
  nonempty: ->(s) {
    raise "can't be empty" if s.empty?
    s
  },
}

# Convenience for the disk pickers — they parse user-typed indices
# against an array of available devices. Used inline as a Proc when
# calling prompt, so it can close over the disk list.
def parse_indices_against(available)
  ->(input) {
    indices = input.split(/[\s,]+/).reject(&:empty?).map { |s|
      i = Integer(s) rescue (raise "not a number: #{s}")
      raise "index #{i} out of range (have 1..#{available.size})" unless (1..available.size).cover?(i)
      i
    }
    indices.map { |i| available[i - 1] }
  }
end

# ============================================================
# Disk discovery helpers (used by Storage's prompts)
# ============================================================

def list_storage_hdds
  `lsblk -dno NAME,TYPE,ROTA,TRAN`
    .lines
    .map(&:split)
    .select { |_name, type, rota, tran| type == "disk" && rota == "1" && tran == "sata" }
    .map { |name, *| name }
end

def list_download_ssd_candidates
  boot_part = `findmnt -no SOURCE /`.strip
  boot_disk = `lsblk -dno pkname #{boot_part}`.strip rescue ""
  `lsblk -dno NAME,TYPE,ROTA,TRAN`
    .lines
    .map(&:split)
    .select { |_name, type, rota, tran| type == "disk" && rota == "0" && tran == "nvme" }
    .map { |name, *| name }
    .reject { |name| name == boot_disk }
end

def disk_info_line(name, index)
  size   = `lsblk -dno SIZE /dev/#{name}`.strip
  model  = `lsblk -dno MODEL /dev/#{name}`.strip.tr_s(" ", " ")
  serial = `lsblk -dno SERIAL /dev/#{name}`.strip
  format("  %d) %-8s %-7s %-32s %s", index, name, size, model, serial)
end

# ============================================================
# Env file persistence
# ============================================================

# Write a small env file at the given path. Contents passed as a hash;
# values are wrapped in single quotes so passwords containing shell-
# special characters round-trip safely when later sourced.
def write_env_file(path, values)
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path, "w", 0o600) do |f|
    f.puts "# Auto-managed by depot. Edit + re-run `depot install` to rotate."
    values.each do |k, v|
      f.puts "#{k}=#{shellescape(v.to_s)}"
    end
  end
end

# Read a key=value env file into a hash. Returns {} if missing.
def read_env_file(path)
  return {} unless File.file?(path)
  File.readlines(path).each_with_object({}) do |line, h|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    k, v = line.split("=", 2)
    next unless v
    h[k] = v.sub(/\A'/, "").sub(/'\z/, "").gsub(%q(\\''), "'")
  end
end

# ============================================================
# Arr API helpers (Sonarr / Radarr / Prowlarr / shared between modules)
# ============================================================

# Read the <ApiKey>X</ApiKey> value from an arr's config.xml. Returns
# nil if the file doesn't exist yet (e.g. the container hasn't started).
def arr_read_api_key(config_xml)
  return nil unless File.file?(config_xml) && File.size(config_xml) > 0
  body = File.read(config_xml)
  body[%r{<ApiKey>([^<]+)</ApiKey>}, 1]
end

# Poll an arr's REST API until /system/status returns 2xx.
# version: "v1" for Prowlarr, "v3" for Sonarr/Radarr.
def arr_wait_for_api(base_url, version, api_key)
  30.times do
    resp = http(:get, "#{base_url}/api/#{version}/system/status",
                headers: { "X-Api-Key" => api_key })
    return true if resp && resp.code.to_i.between?(200, 299)
    sleep 1
  end
  puts "  WARN: #{base_url}/api/#{version}/system/status didn't come up in 30s"
  false
end

# Each arr exposes /initialize.json anonymous-accessible until the
# first admin exists; we POST creds there and set authentication to
# Forms with DisabledForLocalAddresses. Idempotent: 4xx-on-already-set
# is treated as success.
def arr_create_admin(base_url, username, password, label)
  body = URI.encode_www_form(
    username: username,
    password: password,
    passwordConfirmation: password,
    authenticationMethod: "Forms",
    authenticationRequired: "DisabledForLocalAddresses",
  )
  resp = http(:post, "#{base_url}/initialize.json",
              body: body,
              headers: { "Content-Type" => "application/x-www-form-urlencoded" })
  return if resp.nil?
  code = resp.code.to_i
  return if (200..299).cover?(code) || [401, 404, 409].include?(code)
  puts "  WARN: #{label} initialize.json returned HTTP #{code} — #{resp.body.to_s[0, 200]}"
end

# Add a root folder (where to save finished media). Idempotent.
def arr_set_library_directory(base_url, api_key, path)
  existing = http_get_json("#{base_url}/api/v3/rootfolder",
                           headers: { "X-Api-Key" => api_key }) || []
  return if existing.any? { |f| f["path"] == path }
  http(:post, "#{base_url}/api/v3/rootfolder",
       body: { "path" => path },
       headers: { "X-Api-Key" => api_key })
end

# Add qBittorrent as a download client. tvCategory/movieCategory both
# get the same value because the arr schema requires both fields;
# qBit ignores the irrelevant one per release.
def arr_connect_to_qbit(base_url, api_key, qbit_user, qbit_pass, category)
  payload = {
    "name" => "qBittorrent", "enable" => true, "protocol" => "torrent",
    "priority" => 1, "removeCompletedDownloads" => true,
    "removeFailedDownloads" => true,
    "implementation" => "QBittorrent",
    "implementationName" => "qBittorrent",
    "configContract" => "QBittorrentSettings",
    "fields" => [
      { "name" => "host", "value" => "host.docker.internal" },
      { "name" => "port", "value" => 8080 },
      { "name" => "useSsl", "value" => false },
      { "name" => "urlBase", "value" => "" },
      { "name" => "username", "value" => qbit_user },
      { "name" => "password", "value" => qbit_pass },
      { "name" => "tvCategory", "value" => category },
      { "name" => "movieCategory", "value" => category },
      { "name" => "recentTvPriority", "value" => 0 },
      { "name" => "olderTvPriority", "value" => 0 },
      { "name" => "recentMoviePriority", "value" => 0 },
      { "name" => "olderMoviePriority", "value" => 0 },
      { "name" => "initialState", "value" => 0 },
    ],
    "tags" => [],
  }
  arr_upsert_by_name(base_url, "/api/v3/downloadclient", api_key, "qBittorrent", payload)
end

# Add Jellyfin as a notification target so on-import/upgrade/rename
# events fire a library refresh.
def arr_connect_to_jellyfin(base_url, api_key, jellyfin_api_key)
  payload = {
    "name" => "Jellyfin", "onGrab" => false, "onDownload" => true,
    "onUpgrade" => true, "onRename" => true,
    "implementation" => "MediaBrowser", "implementationName" => "Emby",
    "configContract" => "MediaBrowserSettings",
    "fields" => [
      { "name" => "host", "value" => "host.docker.internal" },
      { "name" => "port", "value" => 8096 },
      { "name" => "useSsl", "value" => false },
      { "name" => "apiKey", "value" => jellyfin_api_key },
      { "name" => "updateLibrary", "value" => true },
    ],
    "tags" => [],
  }
  arr_upsert_by_name(base_url, "/api/v3/notification", api_key, "Jellyfin", payload)
end

# Generic upsert-by-name. Looks up by .name; PUTs if found, POSTs if
# not. Returns the response object.
def arr_upsert_by_name(base_url, list_path, api_key, name, payload)
  existing = http_get_json("#{base_url}#{list_path}",
                           headers: { "X-Api-Key" => api_key }) || []
  found = existing.find { |x| x["name"] == name }
  headers = { "X-Api-Key" => api_key, "Content-Type" => "application/json" }
  if found
    payload_with_id = payload.merge("id" => found["id"])
    http(:put, "#{base_url}#{list_path}/#{found["id"]}", body: payload_with_id, headers: headers)
  else
    http(:post, "#{base_url}#{list_path}", body: payload, headers: headers)
  end
end

# Custom-format JSON blobs (used by the opinionate routine below).
ARR_FORMAT_AUDIO_DESCRIPTION = {
  "name" => "Audio Description", "includeCustomFormatWhenRenaming" => false,
  "specifications" => [{
    "name" => "descriptive in title",
    "implementation" => "ReleaseTitleSpecification",
    "negate" => false, "required" => true,
    "fields" => [{ "name" => "value",
                   "value" => '\b(descriptive|audio.{0,2}description|narration)\b' }],
  }],
}.freeze

ARR_FORMAT_CAM_TS = {
  "name" => "Theater Cam / Telesync / Screener",
  "includeCustomFormatWhenRenaming" => false,
  "specifications" => [{
    "name" => "cam-rip indicators",
    "implementation" => "ReleaseTitleSpecification",
    "negate" => false, "required" => true,
    "fields" => [{ "name" => "value",
                   "value" => '\b(CAM|HDCAM|HDTS|TELESYNC|TELECINE|HC[._\-]?HDRip|SCREENER|DVDSCR|PDVD)\b' }],
  }],
}.freeze

ARR_FORMAT_BAD_GROUPS = {
  "name" => "Banned Release Groups",
  "includeCustomFormatWhenRenaming" => false,
  "specifications" => [{
    "name" => "known low-quality groups",
    "implementation" => "ReleaseGroupSpecification",
    "negate" => false, "required" => true,
    "fields" => [{ "name" => "value",
                   "value" => '^(YIFY|YTS.*|KOGI|Kitsune|aXXo|mSD)$' }],
  }],
}.freeze

# HEVC/x265: browsers can't direct-stream; every play needs Jellyfin
# to transcode to h264, expensive even with QSV. Banning auto-grabs
# forces 1080p h264.
ARR_FORMAT_HEVC = {
  "name" => "Codec: HEVC / x265",
  "includeCustomFormatWhenRenaming" => false,
  "specifications" => [{
    "name" => "HEVC video codec",
    "implementation" => "ReleaseTitleSpecification",
    "negate" => false, "required" => true,
    "fields" => [{ "name" => "value", "value" => '\b(HEVC|H[._\-]?265|x265)\b' }],
  }],
}.freeze

# 2160p/4K: typically HEVC 10-bit + HDR/DV. Server-side transcoding to
# browser-playable h264 SDR is prohibitively heavy.
ARR_FORMAT_RES_2160P = {
  "name" => "Resolution: 2160p / 4K",
  "includeCustomFormatWhenRenaming" => false,
  "specifications" => [{
    "name" => "matches 2160p",
    "implementation" => "ResolutionSpecification",
    "negate" => false, "required" => true,
    "fields" => [{ "name" => "value", "value" => 2160 }],
  }],
}.freeze

# Upsert all banned-format custom formats into the arr, then apply a
# policy to every quality profile: language=English, upgrades on,
# banned formats scored at -10000 (disqualifies at search time, shows
# up in Cutoff Unmet for upgrade). Idempotent.
def arr_opinionate_downloads(base_url, api_key)
  return unless arr_wait_for_api(base_url, "v3", api_key)

  [ARR_FORMAT_AUDIO_DESCRIPTION, ARR_FORMAT_CAM_TS, ARR_FORMAT_BAD_GROUPS,
   ARR_FORMAT_RES_2160P, ARR_FORMAT_HEVC].each do |fmt|
    arr_upsert_by_name(base_url, "/api/v3/customformat", api_key, fmt["name"], fmt)
  end

  banned_names = [ARR_FORMAT_AUDIO_DESCRIPTION["name"], ARR_FORMAT_CAM_TS["name"],
                  ARR_FORMAT_BAD_GROUPS["name"], ARR_FORMAT_RES_2160P["name"],
                  ARR_FORMAT_HEVC["name"]]

  cfs = http_get_json("#{base_url}/api/v3/customformat",
                      headers: { "X-Api-Key" => api_key }) || []
  banned_ids = cfs.select { |cf| banned_names.include?(cf["name"]) }.map { |cf| cf["id"] }

  profiles = http_get_json("#{base_url}/api/v3/qualityprofile",
                           headers: { "X-Api-Key" => api_key }) || []
  profiles.each do |profile|
    items = (profile["formatItems"] || []).map do |item|
      if banned_ids.include?(item["format"])
        item.merge("score" => -10000)
      else
        item
      end
    end
    existing_ids = items.map { |i| i["format"] }
    cfs.select { |cf| banned_ids.include?(cf["id"]) && !existing_ids.include?(cf["id"]) }
      .each { |cf| items << { "format" => cf["id"], "name" => cf["name"], "score" => -10000 } }

    updated = profile.merge(
      "language"          => { "id" => 1, "name" => "English" },
      "upgradeAllowed"    => true,
      "minFormatScore"    => 0,
      "cutoffFormatScore" => 0,
      "formatItems"       => items,
    )
    http(:put, "#{base_url}/api/v3/qualityprofile/#{profile["id"]}",
         body: updated,
         headers: { "X-Api-Key" => api_key, "Content-Type" => "application/json" })
  end
end
