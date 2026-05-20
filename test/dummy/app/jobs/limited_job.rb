# frozen_string_literal: true

# Uses Wurk::Limiter (Ent parity).
class LimitedJob
  include Wurk::Worker

  def perform(*args); end
end
