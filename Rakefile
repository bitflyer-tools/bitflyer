require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubygems/installer"
require "tmpdir"

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

desc 'Type check lib/ against the RBS signatures in sig/'
task steep: :validate_public_signatures do
  sh 'steep check'
end

desc 'Validate the public RBS signatures from an installed gem'
task :validate_public_signatures do
  Dir.mktmpdir('bitflyer-signatures') do |directory|
    package = File.join(directory, 'bitflyer.gem')
    sh 'gem', 'build', 'bitflyer.gemspec', '--output', package
    installed = Gem::Installer.at(package, install_dir: directory, ignore_dependencies: true).install
    signatures = File.join(installed.full_gem_path, 'sig')
    sh 'rbs', '-I', signatures, '-r', 'uri', '-r', 'net-http', '-r', 'forwardable', '-r', 'openssl', 'validate'
  end
end
