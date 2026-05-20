# frozen_string_literal: true

require_relative "../test_helper"

class LeaderTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-ent.md (leader election)"
  end
end
