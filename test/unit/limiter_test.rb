# frozen_string_literal: true

require_relative "../test_helper"

class LimiterTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-ent.md (Sidekiq::Limiter)"
  end
end
