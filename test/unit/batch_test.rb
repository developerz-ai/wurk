# frozen_string_literal: true

require_relative "../test_helper"

class BatchTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-pro.md (Sidekiq::Batch)"
  end
end
