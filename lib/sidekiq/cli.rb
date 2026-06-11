# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb). In Sidekiq, `Sidekiq.server?`
# is literally "has sidekiq/cli been required" — apps and ecosystem test
# helpers require this file to make `configure_server` blocks run. Wurk
# always loads its CLI class internally, so the passthrough carries the
# *semantic*: requiring it declares this process a server.
require 'wurk'
Wurk.enter_server_mode
