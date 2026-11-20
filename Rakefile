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
    validate_websocket_subscription_signature(signatures)
  end
end

def validate_websocket_subscription_signature(signatures)
  require 'rbs'

  loader = RBS::EnvironmentLoader.new(core_root: nil)
  loader.add(path: Pathname(signatures))
  environment = RBS::Environment.from_loader(loader)
  client = RBS::TypeName.parse('::Bitflyer::Realtime::WebSocketClient')
  subscriptions = environment.class_decls.fetch(client).primary_decl.members
                             .grep(RBS::AST::Members::MethodDefinition)
                             .select { |method| method.kind == :instance && method.name == :subscribe }
  expected = RBS::Parser.parse_method_type('(channel_name: Symbol) { (untyped message) -> void } -> void')
  return if subscriptions.flat_map(&:overloads).map(&:method_type) == [expected]

  abort 'Expected WebSocketClient#subscribe to require the channel_name: Symbol keyword and a message block'
end
