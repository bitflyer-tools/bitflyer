# frozen_string_literal: true

require 'yaml'

describe 'RubyGems release workflow' do
  let(:job) do
    workflow = File.expand_path('../.github/workflows/release.yaml', __dir__)
    YAML.safe_load_file(workflow).fetch('jobs').fetch('push')
  end

  it 'pins every action in the publishing job to a full commit SHA' do
    actions = job.fetch('steps').filter_map { |step| step['uses'] }

    expect(actions).not_to be_empty
    expect(actions).to all(match(/\A[^@]+@[0-9a-f]{40}\z/))
  end
end
