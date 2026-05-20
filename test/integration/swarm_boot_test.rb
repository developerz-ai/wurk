# frozen_string_literal: true

require_relative "../test_helper"

# Real forks, real Redis, real perform. NEVER mock Redis here.
class SwarmBootTest < Wurk::Test::UnitCase
  def test_skeleton
    skip "implementation pending — boot the swarm with N=2, push a job, assert it runs in a child"
  end
end
