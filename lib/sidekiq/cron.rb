# frozen_string_literal: true

# `require "sidekiq/cron"`. With the sidekiq-cron gem in the bundle this is the
# gem's own file, whichever copy the load path finds first; without it, wurk's
# native implementation (lib/wurk/sidekiq_cron.rb) defines `Sidekiq::Cron`.
if (spec = Gem.loaded_specs['sidekiq-cron'])
  require File.join(spec.full_gem_path, 'lib/sidekiq/cron.rb')
else
  require_relative '../wurk/sidekiq_cron'
end
