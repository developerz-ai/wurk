# frozen_string_literal: true

# The `SidekiqUniqueJobs` autoload, registered only when the gem is not in the
# bundle (UniqueJobsCompat.activate_native).
#
# A gem activated after Wurk (RubyGems, no Bundler) reopening `SidekiqUniqueJobs`
# lands here: say so, rather than let it add its classes to the native module.
if Gem.loaded_specs.key?(Wurk::UniqueJobsCompat::GEM)
  raise LoadError, 'sidekiq-unique-jobs was activated after Wurk had set up its native SidekiqUniqueJobs. ' \
                   'Put the gem in the Gemfile (Bundler loads it first and Wurk stands down), or remove it.'
end

# Naming Wurk::UniqueJobs loads it (its autoload).
SidekiqUniqueJobs = Wurk::UniqueJobs
Wurk::UniqueJobs::APIExtension.install
