# frozen_string_literal: true

# `require "sidekiq/cron/web"`. The gem's file registers the gem's tab when the
# gem is bundled. Native entries need no extension: the dashboard's own Cron
# page lists them beside the periodic loops (Wurk::SidekiqCron::WebRows).
if (spec = Gem.loaded_specs['sidekiq-cron'])
  require File.join(spec.full_gem_path, 'lib/sidekiq/cron/web.rb')
else
  require_relative '../../wurk/sidekiq_cron'
end
