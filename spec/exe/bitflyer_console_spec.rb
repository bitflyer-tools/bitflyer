# frozen_string_literal: true

require 'open3'
require 'rbconfig'

describe 'exe/bitflyer-console' do
  let(:exe) { File.expand_path('../../exe/bitflyer-console', __dir__) }

  # `private_client` is a lexical local (nil) even on the no-credentials branch, so assert on its
  # runtime value rather than `defined?`, which would be "local-variable" either way.
  PRIVATE_CLIENT_CHECK = 'puts "PRIVATE_CLIENT_VALUE=#{private_client.inspect}"' + "\nexit\n"

  def run_console(env)
    Open3.capture3(env, RbConfig.ruby, exe, stdin_data: PRIVATE_CLIENT_CHECK)
  end

  it 'is listed as a gem executable' do
    gemspec = Gem::Specification.load(File.expand_path('../../bitflyer.gemspec', __dir__))

    expect(gemspec.executables).to include('bitflyer-console')
  end

  it 'exposes only the public client without credentials' do
    stdout, stderr, status = run_console('BITFLYER_API_KEY' => nil, 'BITFLYER_API_SECRET' => nil)

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('public_client is ready.')
    expect(stdout).to include('PRIVATE_CLIENT_VALUE=nil')
  end

  it 'exposes the private client when credentials are set' do
    stdout, stderr, status = run_console('BITFLYER_API_KEY' => 'key', 'BITFLYER_API_SECRET' => 'secret')

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('public_client and private_client are ready')
    expect(stdout).to include('PRIVATE_CLIENT_VALUE=#<Bitflyer::HTTP::Private::Client')
  end
end
