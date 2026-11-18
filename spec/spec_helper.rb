if ENV['COVERAGE'] == 'true'
  require 'simplecov'
  require_relative 'support/coverage_summary_formatter'

  SimpleCov.start do
    use_merging false
    track_files 'lib/**/*.rb'
    add_filter { |file| !file.filename.start_with?("#{SimpleCov.root}/lib/") }
    formatter CoverageSummaryFormatter
  end
end

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'bitflyer'
