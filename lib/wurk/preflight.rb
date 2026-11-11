# frozen_string_literal: true

require_relative 'preflight/reader'
require_relative 'preflight/report'
require_relative 'preflight/keyspace'
require_relative 'preflight/owners'
require_relative 'preflight/checks'
require_relative 'preflight/app_scan'

module Wurk
  # `wurk preflight`: what a live Redis holds, and what will and will not carry
  # over, before a cutover. `wurk verify` (Preflight::Verify) is its post-cutover
  # counterpart. Both go through Reader, which refuses anything but reads.
  module Preflight
    DEFAULT_LIMIT = 2_000_000
    DEFAULT_SAMPLE = 100

    module_function

    # `app` is the root of the booted app (`--app`), or nil.
    # @return [Report]
    def run(config, limit: DEFAULT_LIMIT, sample: DEFAULT_SAMPLE, pause: 0.005, progress: nil, app: nil)
      reader = Reader.new(config)
      report = Report.new('preflight')
      keyspace = Keyspace.new(reader, limit: limit, pause: pause, progress: progress).walk
      report.target(reader, keyspace)
      checks = Checks.new(reader: reader, report: report, keyspace: keyspace, owners: Owners.new(reader),
                          sample: sample)
      checks.run
      app ? app_findings(checks, report, app) : report.info('app_checks_skipped', 'No --app: app code not inspected.')
      report
    ensure
      reader&.close
    end

    def app_findings(checks, report, root)
      checks.app
      AppScan.new(root: root, report: report).run
      report.info(Report::APP_CODE_RAN, "The app was booted, so its initializers ran. Wurk's own Redis clients sent " \
                                        'reads only while it booted, but a client the app opens itself ' \
                                        '(Redis.new, Rails.cache) is not covered by that.')
    end
  end
end
