# frozen_string_literal: true

require_relative '../test_helper'

# The host a private list is stamped with, the leader lock's holder and the
# heartbeat identity must be one string. A list stamped with a host the reaper
# does not recognise as its own falls off the instant kill(0) path onto the
# heartbeat path, and a leader identity that is not a `processes` member never
# reads as leader on the Busy page.
class HostnameSourceTest < Wurk::Test::UnitCase
  HOST = 'drifted-host'

  def test_private_list_names_use_component_hostname
    name = with_hostname(HOST) { Wurk::Fetcher::Reliable.private_queue_name('queue:q') }

    assert_equal "queue:q|#{HOST}|#{Process.pid}|#{Wurk::Component::PROCESS_NONCE}|0", name
  end

  def test_leader_owner_is_the_component_identity
    owner = with_hostname(HOST) { Wurk::Leader.new(pool: Object.new).owner }

    assert_equal "#{HOST}:#{Process.pid}:#{Wurk::Component::PROCESS_NONCE}", owner
  end

  private

  def with_hostname(host)
    original = Wurk::Component.method(:hostname)
    Wurk::Component.define_singleton_method(:hostname) { host }
    yield
  ensure
    Wurk::Component.define_singleton_method(:hostname, original)
  end
end
