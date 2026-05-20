# frozen_string_literal: true

module Wurk
  # EVALSHA-cached Lua scripts. Loaded once per pool, never re-uploaded.
  # Bulk enqueue, multi-pop, atomic schedule promotion.
  module Lua
    SCRIPTS = {}.freeze
  end
end
