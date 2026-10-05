# rubocop:disable Naming/FileName -- the gem's own require name, hyphen included
# frozen_string_literal: true

# Drop-in require path (sidekiq-ent.md, top): Wurk ships every Enterprise
# feature in the one gem, so this only has to load it.
require 'wurk'
# rubocop:enable Naming/FileName
