# frozen_string_literal: true

require_relative "../test_helper"

class ClientTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-free.md (Sidekiq::Client)"
  end
end
