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
    validate_order_book_side_signatures(signatures)
  end
end

def validate_order_book_side_signatures(signatures)
  loader = RBS::EnvironmentLoader.new
  %w[uri net-http forwardable openssl].each { |library| loader.add(library: library) }
  loader.add(path: Pathname(signatures))
  builder = RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
  order_book = '::Bitflyer::Realtime::OrderBook'
  view = builder.build_instance(RBS::TypeName.parse("#{order_book}::View"))

  %i[bids asks].each do |reader|
    type = view.methods.fetch(reader).method_types.fetch(0).type.return_type
    abort "Expected OrderBook::View##{reader} to return a read-only interface" unless type.is_a?(RBS::Types::Interface)

    methods = builder.build_interface(type.name).methods.keys
    expected = %i[each map [] fetch first last empty? length size]
    abort "Unexpected methods on OrderBook::View##{reader}: #{methods.sort.inspect}" unless methods.sort == expected.sort
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
