# frozen_string_literal: true

# Drop-in require path, deprecated upstream exactly like sidekiq/testing.
require 'wurk'

Wurk.testing!(:inline)
warn('⛔️ `require "sidekiq/testing/inline"` is deprecated and will be removed in Sidekiq 9.0. ' \
     'Use `Sidekiq.testing!(:inline)` instead.')
