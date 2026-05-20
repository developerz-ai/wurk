# frozen_string_literal: true

require_relative "../test_helper"

class UniqueTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-ent.md (unique jobs)"
  end
end
