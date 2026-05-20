# frozen_string_literal: true

# Uses Wurk::Unique (Ent parity). Demonstrates until_executed.
class UniqueJob
  include Wurk::Worker

  def perform(*args); end
end
