require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'uri'

class DeploymentTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('depot-deployment-')
    {
      'hdds/.config/depot/server_kind' => 'demo',
      'hdds/.config/aviary/secret_key_base' => 'test-secret',
      'hdds/.config/aviary/sonarr_webhook_secret' => 'test-webhook',
      'hdds/.config/jellyfin/data/jellyfin.db' => 'test-database',
    }.each do |name, value|
      path = File.join(@directory, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, value)
    end
    FileUtils.mkdir_p(File.join(@directory, 'code/aviary/.git'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def shared_routing
    {
      'TCP' => { '443' => { 'HTTPS' => true }, '8443' => { 'HTTPS' => true } },
      'Web' => {
        'review.example.ts.net:443' => { 'Handlers' => {
          '/' => { 'Proxy' => 'http://localhost:4000' },
          '/notes' => { 'Proxy' => 'http://127.0.0.1:7000' },
          '/tasks' => { 'Proxy' => 'http://127.0.0.1:7001' },
        } },
        'review.example.ts.net:8443' => { 'Handlers' => {
          '/' => { 'Proxy' => 'http://localhost:8096' },
        } },
      },
      'AllowFunnel' => { 'review.example.ts.net:443' => true },
    }
  end

  def update(routing, funnel_allowed: true, service: 'aviary')
    path = File.join(@directory, 'routing.json')
    File.write(path, JSON.generate({ routing: routing, snapshots: [], funnel_allowed: funnel_allowed }))
    output, status = Open3.capture2e(
      { 'HOME' => @directory, 'DEPOT_TEST_STATE' => path, 'DEPOT_TEST_SERVICE' => service },
      RbConfig.ruby, File.expand_path('support/update.rb', __dir__),
    )
    [JSON.parse(File.read(path)), output, status]
  end

  def test_updating_the_review_server_keeps_neighboring_services_reachable_and_private_ports_private
    routing = shared_routing
    result, output, status = update(routing)
    assert status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
  end

  def test_a_server_without_funnel_permission_remains_available_only_on_the_tailnet
    routing = shared_routing
    routing['Web'].delete('review.example.ts.net:443')
    routing['TCP'].delete('443')
    routing['AllowFunnel'].clear
    result, output, status = update(routing, funnel_allowed: false)
    assert status.success?, output
    assert_equal({ 'Proxy' => 'http://localhost:4000' },
                 result.dig('routing', 'Web', 'review.example.ts.net:443', 'Handlers', '/'))
    assert_equal false, result.dig('routing', 'AllowFunnel', 'review.example.ts.net:443')
    assert_equal routing['Web']['review.example.ts.net:8443'],
                 result.dig('routing', 'Web', 'review.example.ts.net:8443')
  end

  def test_a_failed_funnel_update_does_not_take_existing_public_services_offline
    routing = shared_routing
    result, output, status = update(routing, funnel_allowed: false)
    refute status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
    assert_includes output, 'Existing public routes were left unchanged'
  end

  def test_private_neighboring_routes_are_never_exposed_by_publishing_aviary
    routing = shared_routing
    routing['AllowFunnel'].clear
    result, output, status = update(routing)
    refute status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
    assert_includes output, 'Refusing to expose other private routes on port 443'
  end

  def test_another_app_at_the_root_is_not_overwritten
    routing = shared_routing
    routing['Web']['review.example.ts.net:443']['Handlers']['/'] = { 'Proxy' => 'http://localhost:9000' }
    result, output, status = update(routing)
    refute status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
    assert_includes output, 'Port 443 root route belongs to another service'
  end

  def test_an_existing_tcp_forwarder_is_not_replaced_with_a_public_web_server
    routing = shared_routing
    routing['Web'].delete('review.example.ts.net:443')
    routing['TCP']['443'] = { 'TCPForward' => '127.0.0.1:9000' }
    result, output, status = update(routing)
    refute status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
    assert_includes output, 'Port 443 is already used by a different listener'
  end

  def test_updating_sabnzbd_downloads_shows_back_catalogs_after_movies
    File.delete(File.join(@directory, 'hdds/.config/depot/server_kind'))
    sabnzbd_ini = File.join(@directory, 'hdds/.config/sabnzbd/sabnzbd.ini')
    FileUtils.mkdir_p(File.dirname(sabnzbd_ini))
    File.write(sabnzbd_ini, "[misc]\napi_key = test-sab-key\n")

    result, output, status = update(shared_routing, service: 'sabnzbd')

    assert status.success?, output
    category_changes = result.fetch('requests').select do |request|
      request['path'].include?('mode=set_config') && request['body'].to_s.include?('section=categories')
    end
    assert_equal [{ 'section' => 'categories', 'keyword' => 'tv', 'priority' => '-1' }],
                 category_changes.map { |request| URI.decode_www_form(request['body']).to_h.except('apikey') }
  end

  def test_updating_a_production_nas_preserves_its_existing_public_and_private_routes
    File.delete(File.join(@directory, 'hdds/.config/depot/server_kind'))
    routing = shared_routing
    routing['Web']['review.example.ts.net:443']['Handlers'].delete('/notes')
    routing['Web']['review.example.ts.net:443']['Handlers'].delete('/tasks')
    result, output, status = update(routing)
    assert status.success?, output
    result.fetch('snapshots').each { |snapshot| assert_equal routing, snapshot }
  end
end
