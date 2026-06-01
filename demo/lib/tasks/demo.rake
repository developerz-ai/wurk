# frozen_string_literal: true

namespace :demo do
  desc "Run the demo traffic producer in the foreground (Ctrl-C to stop)"
  task workload: :environment do
    logger = Logger.new($stdout)
    logger.formatter = ->(_sev, time, _prog, msg) { "#{time.strftime('%H:%M:%S')} #{msg}\n" }
    DemoProducer.new(logger: logger).run
  end

  desc "Flush the demo Redis so the producer re-seeds from a clean slate"
  task reset: :environment do
    Wurk.redis { |c| c.call("FLUSHDB") }
    puts "demo Redis flushed — the producer reseeds within one tick."
  end
end
