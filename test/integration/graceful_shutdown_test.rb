# frozen_string_literal: true

require_relative "../test_helper"

class GracefulShutdownTest < Wurk::Test::UnitCase
  def test_skeleton
    skip "implementation pending — SIGTERM the parent, assert in-flight jobs finish within shutdown_timeout"
  end
end
