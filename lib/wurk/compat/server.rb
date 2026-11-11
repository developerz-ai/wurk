# frozen_string_literal: true

# Autoload target of the server tier's Sidekiq aliases (compat.rb). The Wurk
# files define only their Wurk names; this assigns the Sidekiq ones.

module Sidekiq
  CLI        = Wurk::CLI
  Embedded   = Wurk::Embedded
  Launcher   = Wurk::Launcher
  Manager    = Wurk::Manager
  Scheduled  = Wurk::Scheduled
  History    = Wurk::History
  Periodic   = Wurk::Cron
  CronParser = Wurk::Cron::Parser
end
