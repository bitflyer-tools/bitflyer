require 'yaml'

RSpec.describe 'Release workflow' do
  let(:steps) do
    workflow = File.expand_path('../.github/workflows/release.yaml', __dir__)
    YAML.safe_load_file(workflow).fetch('jobs').fetch('push').fetch('steps')
  end

  it 'pins every release action to a full commit SHA' do
    actions = steps.filter_map { |step| step['uses'] }
    expect(actions).not_to be_empty
    expect(actions).to all(match(%r{\A[\w.-]+/[\w.-]+@[0-9a-f]{40}\z}))
  end
end
