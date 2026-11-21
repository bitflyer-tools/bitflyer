# frozen_string_literal: true

require 'open3'
require 'rbconfig'

describe 'Bitflyer entry points' do
  def check_import(entry_point, assertions)
    lib = File.expand_path('../lib', __dir__)
    script = "require '#{entry_point}'\n#{assertions}"
    _, stderr, status = Open3.capture3(RbConfig.ruby, '-w', '-I', lib, '-e', script)

    expect(status.success?).to be(true), stderr
    expect(stderr).not_to include('circular require')
  end

  it 'loads both HTTP clients without the realtime transport' do
    check_import('bitflyer/http', <<~'RUBY')
      Bitflyer::HTTP::Public::Client.new
      Bitflyer::HTTP::Private::Client.new('key', 'secret')
      abort 'Loaded the realtime client' if defined?(Bitflyer::Realtime)
      abort 'Loaded the WebSocket transport' if defined?(WebSocket::Driver)
    RUBY
  end

  it 'loads the realtime client without the HTTP client' do
    check_import('bitflyer/realtime', <<~'RUBY')
      abort 'Missing the realtime client' unless defined?(Bitflyer::Realtime::Client)
      abort 'Loaded the HTTP client' if defined?(Bitflyer::HTTP)
    RUBY
  end

  it 'exposes all client factories from the top-level entry point' do
    check_import('bitflyer', <<~'RUBY')
      factories = %i[http_public_client http_private_client realtime_client]
      missing = factories.reject { |factory| Bitflyer.respond_to?(factory) }
      abort "Missing factories: #{missing.join(', ')}" unless missing.empty?
    RUBY
  end
end
