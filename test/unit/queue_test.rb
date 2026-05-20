# frozen_string_literal: true

require_relative "../test_helper"

class QueueTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-free.md (Sidekiq::Queue)"
  end
end
