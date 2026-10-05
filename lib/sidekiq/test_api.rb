# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb): Sidekiq 8.1's side-effect-free
# testing API. Unlike sidekiq/testing it leaves the test mode alone.
require 'wurk'
