# rubocop:disable Naming/FileName -- the gem's own require name, hyphen included
# frozen_string_literal: true

# `require "sidekiq-cron"`, the gem's entrypoint (Bundler's auto-require).
# Bundled, the gem loads itself; otherwise wurk's native sidekiq-cron does.
if (spec = Gem.loaded_specs['sidekiq-cron'])
  require File.join(spec.full_gem_path, 'lib/sidekiq-cron.rb')
else
  require_relative 'wurk/sidekiq_cron'
end
# rubocop:enable Naming/FileName
