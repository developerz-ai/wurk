# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb). In Sidekiq, `Sidekiq.server?`
# is literally "has sidekiq/cli been required" — apps and ecosystem test
# helpers require this file to make `configure_server` blocks run, so the
# passthrough carries that *semantic* as well as the CLI class: requiring it
# declares this process a server.
require 'wurk'
require 'wurk/compat/server'
Wurk.enter_server_mode
