# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb): loads the lazy surface it names.
require 'wurk'
Sidekiq.const_get(:Manager)
