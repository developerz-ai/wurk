# frozen_string_literal: true

require_relative 'preflight/reader'
require_relative 'preflight/report'
require_relative 'preflight/keyspace'
require_relative 'preflight/owners'
require_relative 'preflight/checks'

module Wurk
  # `wurk preflight`: what a live Redis holds, and what will and will not carry
  # over, before a cutover. `wurk verify` (Preflight::Verify) is its post-cutover
  # counterpart. Both go through Reader, which refuses anything but reads.
  module Preflight
    DEFAULT_LIMIT = 2_000_000
    DEFAULT_SAMPLE = 100

    module_function

    # @return [Report]
    def run(config, limit: DEFAULT_LIMIT, sample: DEFAULT_SAMPLE, pause: 0.005, progress: nil, app: false)
      reader = Reader.new(config)
      report = Report.new('preflight')
      keyspace = Keyspace.new(reader, limit: limit, pause: pause, progress: progress).walk
      report.target(reader, keyspace)
      checks = Checks.new(reader: reader, report: report, keyspace: keyspace, owners: Owners.new(reader),
                          sample: sample)
      checks.run
      app ? app_findings(checks, report) : report.info('app_checks_skipped', 'No --app: `lock:` classes not inspected.')
      report
    ensure
      reader&.close
    end

    def app_findings(checks, report)
      checks.app
      report.info(Report::APP_CODE_RAN, 'The app was booted, so its initializers ran. This run read Redis only, but ' \
                                        'anything they wrote, on whichever Redis they use, is not covered by that.')
    end
  end
end
