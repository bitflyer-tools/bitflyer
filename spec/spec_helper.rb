if ENV['COVERAGE'] == 'true'
  require 'simplecov'
  require_relative 'support/coverage_summary_formatter'

  SimpleCov.start do
    merging false
    cover 'lib/**/*.rb'
    minimum_coverage line: 98
    history_limit 0
    formatter CoverageSummaryFormatter
  end
end

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'bitflyer'
