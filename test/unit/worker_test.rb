# frozen_string_literal: true

require_relative "../test_helper"

class WorkerTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-free.md (Sidekiq::Worker / Sidekiq::Job)"
  end
end
