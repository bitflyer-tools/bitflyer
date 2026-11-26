# frozen_string_literal: true

require 'open3'
require 'rbconfig'

describe 'exe/bitflyer-console' do
  let(:exe) { File.expand_path('../../exe/bitflyer-console', __dir__) }

  def run_console(env)
    Open3.capture3(env, RbConfig.ruby, exe, stdin_data: "exit\n")
  end

  it 'is listed as a gem executable' do
    gemspec = Gem::Specification.load(File.expand_path('../../bitflyer.gemspec', __dir__))

    expect(gemspec.executables).to include('bitflyer-console')
  end

  it 'exposes only the public client without credentials' do
    stdout, stderr, status = run_console('BITFLYER_API_KEY' => nil, 'BITFLYER_API_SECRET' => nil)

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('public_client is ready.')
    expect(stdout).not_to include('private_client')
  end

  it 'exposes the private client when credentials are set' do
    stdout, stderr, status = run_console('BITFLYER_API_KEY' => 'key', 'BITFLYER_API_SECRET' => 'secret')

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('public_client and private_client are ready')
  end
end
