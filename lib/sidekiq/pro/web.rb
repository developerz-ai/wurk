# frozen_string_literal: true

# Drop-in require path (sidekiq-pro.md §10): Sidekiq::Pro::Web is the same
# dashboard as Sidekiq::Web.
require 'wurk'
Sidekiq::Pro.const_get(:Web)
