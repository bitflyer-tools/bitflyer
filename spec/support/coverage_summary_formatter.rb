# frozen_string_literal: true

class CoverageSummaryFormatter
  def format(result)
    summary = [
      '### Line coverage',
      '',
      '| File | Covered lines | Total lines | Coverage |',
      '| --- | ---: | ---: | ---: |',
      coverage_row('**Total**', result)
    ]
    result.files.sort_by(&:filename).each do |file|
      summary << coverage_row("`#{file.project_filename}`", file)
    end

    summary_path = ENV['GITHUB_STEP_SUMMARY']
    summary_path ? File.open(summary_path, 'a') { |output| output.puts(summary) } : puts(summary)
  end

  private

  def coverage_row(label, coverage)
    lines = coverage.coverage_statistics(:line)
    "| #{label} | #{lines.covered} | #{lines.total} | #{'%.2f' % lines.percent}% |"
  end
end
