# rubocop:disable Naming/FileName -- the gem's own require name, hyphen included
# frozen_string_literal: true

# Drop-in require path (sidekiq-pro.md, top): Wurk ships every Pro feature in
# the one gem, so this only has to load it.
require 'wurk'
# rubocop:enable Naming/FileName
