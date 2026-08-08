# frozen_string_literal: true

# One-line require for Rails hosts: `require "wurk/rails"`.
# Loads core Wurk, then defines the engine and railtie that mounts the
# dashboard and forks the swarm after `after_initialize`.

require_relative '../wurk'
require_relative 'engine'
require_relative 'railtie'
