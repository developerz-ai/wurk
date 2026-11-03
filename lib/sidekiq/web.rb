# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb). Wurk loads this surface whole.
require 'wurk'

# Extension renderer dependencies, deferred on the worker path (web/extension.rb).
# Loaded here for a helper called outside a request, as unique-jobs' specs do.
require 'cgi'
require 'erb'
