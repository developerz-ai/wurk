# frozen_string_literal: true

namespace :demo do
  desc 'Run the self-healing demo workload generator in the foreground (Ctrl-C to stop)'
  task workload: :environment do
    logger = Logger.new($stdout)
    logger.formatter = ->(_severity, time, _progname, msg) { "#{time.strftime('%H:%M:%S')} #{msg}\n" }
    Demo::Workload.new(logger: logger).run
  end
end
