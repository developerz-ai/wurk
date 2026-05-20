# frozen_string_literal: true

require_relative "../test_helper"

class RollingRestartTest < Wurk::Test::UnitCase
  def test_skeleton
    skip "implementation pending — send SIGUSR1 to parent, assert each child cycles in turn with no dropped jobs"
  end
end
