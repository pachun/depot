require 'json'
require 'net/http'
require 'open3'
require 'shellwords'

module DeploymentCommands
  def self.run(command)
    words = Shellwords.split(command).reject { |word| word == '2>/dev/null' }
    words.shift if words.first == 'sudo'
    state = JSON.parse(File.read(ENV.fetch('DEPOT_TEST_STATE')))
    output = ''
    success = true

    case words.first
    when '-v', 'git', 'docker', 'docker-compose', 'zpool'
    when /\A[A-Z_]+=/
      raise "Unexpected command: #{words.inspect}" unless words.include?('docker-compose')
    when 'sqlite3'
      output = 'test-jellyfin-key'
    when 'timedatectl'
      output = 'America/New_York'
    when 'df'
      output = "Size\n1000000\n"
    when 'zfs'
      output = "1000000\t200000\n"
    when 'mountpoint'
      output = '0'
    when 'tailscale'
      if words[1..] == ['status', '--json']
        output = JSON.generate({ 'Self' => { 'DNSName' => 'review.example.ts.net.' } })
      elsif words[1..] == ['serve', 'status', '--json']
        output = JSON.generate(state.fetch('routing'))
      else
        port = words.find { |word| word.start_with?('--https=') }&.split('=')&.last || '443'
        host = "review.example.ts.net:#{port}"
        routing = state.fetch('routing')
        if words.last == 'off'
          routing.fetch('Web').delete(host)
          routing.fetch('AllowFunnel').delete(host)
        elsif words[1] == 'funnel' && !state.fetch('funnel_allowed', true)
          success = false
        else
          path = words.find { |word| word.start_with?('--set-path=') }&.split('=', 2)&.last || '/'
          routing['Web'][host] ||= { 'Handlers' => {} }
          routing['Web'][host]['Handlers'][path] = { 'Proxy' => words.last }
          routing['TCP'][port] = { 'HTTPS' => true }
          routing['AllowFunnel'][host] = words[1] == 'funnel'
        end
      end
    else
      raise "Unexpected external command: #{words.inspect}"
    end

    state['snapshots'] << JSON.parse(JSON.generate(state.fetch('routing')))
    File.write(ENV.fetch('DEPOT_TEST_STATE'), JSON.generate(state))
    [output, success]
  end
end

module SimulatedShell
  def system(command, **)
    DeploymentCommands.run(command).last
  end

  def `(command)
    DeploymentCommands.run(command).first
  end
end
Kernel.prepend(SimulatedShell)

CommandStatus = Struct.new(:successful) do
  def success? = successful
end

module SimulatedCapture
  def capture2e(command)
    output, success = DeploymentCommands.run(command)
    [output, CommandStatus.new(success)]
  end

  def capture3(command)
    output, success = DeploymentCommands.run(command)
    [output, '', CommandStatus.new(success)]
  end
end
Open3.singleton_class.prepend(SimulatedCapture)

module AvailableWebServer
  def start(*)
    client = Object.new
    def client.request(request)
      state = JSON.parse(File.read(ENV.fetch('DEPOT_TEST_STATE')))
      state['requests'] = state.fetch('requests', []) << {
        'method' => request.method, 'path' => request.path, 'body' => request.body,
      }
      File.write(ENV.fetch('DEPOT_TEST_STATE'), JSON.generate(state))
      Struct.new(:code, :body).new('200', '[]')
    end
    yield client
  end
end
Net::HTTP.singleton_class.prepend(AvailableWebServer)

ARGV.replace(['update', ENV.fetch('DEPOT_TEST_SERVICE', 'aviary')])
ENV['DEPOT_RUNNING_LATEST'] = '1'
load File.expand_path('../../depot', __dir__)
