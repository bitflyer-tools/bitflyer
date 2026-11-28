# frozen_string_literal: true

require 'yaml'
require 'open3'
require 'rbconfig'
require 'bitflyer/version'

describe 'RubyGems release workflow' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:workflow) { YAML.safe_load_file(File.join(root, '.github/workflows/release.yaml')) }
  let(:job) { workflow.fetch('jobs').fetch('push') }
  let(:tag_check) { job.fetch('steps').find { |step| step['name'] == 'Check release tag' } }

  it 'runs only for version tag pushes' do
    expect(workflow.fetch('on')).to eq('push' => { 'tags' => ['v*'] })
  end

  it 'accepts the tag for the gem version' do
    _, status = check_tag("v#{Bitflyer::VERSION}")
    expect(status).to be_success
  end

  it 'rejects a tag for a different gem version' do
    major, minor, patch = Bitflyer::VERSION.split('.').map(&:to_i)
    output, status = check_tag("v#{major}.#{minor}.#{patch + 1}")
    expect(status).not_to be_success
    expect(output).to include('must match the gem')
  end

  it 'pins every action in the publishing job to a full commit SHA' do
    actions = job.fetch('steps').filter_map { |step| step['uses'] }

    expect(actions).not_to be_empty
    expect(actions).to all(match(/\A[^@]+@[0-9a-f]{40}\z/))
  end

  it 'disables credential persistence in checkout' do
    checkout = job.fetch('steps').find { |step| step['uses']&.start_with?('actions/checkout@') }

    expect(checkout.fetch('with').fetch('persist-credentials')).to be(false)
  end

  def check_tag(tag)
    Open3.capture2e({ 'RELEASE_TAG' => tag }, RbConfig.ruby, '-e', tag_check.fetch('run'), chdir: root)
  end
end
