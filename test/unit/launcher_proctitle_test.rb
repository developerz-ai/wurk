# frozen_string_literal: true

require_relative '../test_helper'

# Ops probes find workers with `ps | grep '^sidekiq'` and read the busy count off
# the title. Stock Sidekiq 8.1's Launcher sets `$0` on every beat to
# `sidekiq <Sidekiq::VERSION> <tag> [<busy> of <concurrency> busy]`, then
# `stopping` once quieted, and leaves an embedded host's title alone.
class LauncherProctitleTest < Wurk::Test::UnitCase
  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.default_capsule.concurrency = 3
    @config.capsule('other') { |c| c.concurrency = 2 }
    @config[:tag] = 'myapp'
    @saved_title = $PROGRAM_NAME
  end

  def teardown
    $PROGRAM_NAME = @saved_title
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_the_title_is_upstreams
    launcher = Wurk::Launcher.new(@config)

    assert_equal "sidekiq #{Sidekiq::VERSION} myapp [0 of 5 busy]", launcher.send(:proctitle)

    launcher.instance_variable_set(:@done, true)

    assert_equal "sidekiq #{Sidekiq::VERSION} myapp [0 of 5 busy] stopping", launcher.send(:proctitle)
  end

  def test_a_beat_titles_the_process
    Wurk::Launcher.new(@config).send(:beat)

    assert_equal "sidekiq #{Sidekiq::VERSION} myapp [0 of 5 busy]", $PROGRAM_NAME
  end

  def test_an_embedded_beat_leaves_the_hosts_title
    $PROGRAM_NAME = 'puma 6.4.0 (tcp://0.0.0.0:3000) [app]'
    Wurk::Launcher.new(@config, embedded: true).send(:beat)

    assert_equal 'puma 6.4.0 (tcp://0.0.0.0:3000) [app]', $PROGRAM_NAME
  end

  def test_a_segment_appended_to_the_list_shows_up
    Wurk::Launcher::PROCTITLES << proc { 'extra' }

    assert_equal "sidekiq #{Sidekiq::VERSION} myapp [0 of 5 busy] extra", Wurk::Launcher.new(@config).send(:proctitle)
  ensure
    Wurk::Launcher::PROCTITLES.pop
  end
end
