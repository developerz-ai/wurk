# frozen_string_literal: true

require_relative "../test_helper"

class MiddlewareChainTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_skeleton
    skip "implementation pending — see docs/target/sidekiq-free.md (Sidekiq::Middleware::Chain)"
  end
end
