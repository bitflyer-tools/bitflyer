require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

desc 'Type check lib/ against the RBS signatures in sig/'
task :steep do
  sh 'steep check'
end
