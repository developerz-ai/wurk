# frozen_string_literal: true

require_relative '../test_helper'

# The abstract Wurk::Fetcher base class defines the drop-in fetcher contract
# (retrieve_work / bulk_requeue / terminate) as safe no-ops. A custom
# config[:fetch_class] that subclasses it inherits these, so Manager#quiet can
# call terminate and Manager#hard_shutdown can call bulk_requeue unconditionally.
class FetcherTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @fetcher = Wurk::Fetcher.new
  end

  def test_retrieve_work_defaults_to_nil
    assert_nil @fetcher.retrieve_work
  end

  def test_bulk_requeue_defaults_to_noop
    assert_nil @fetcher.bulk_requeue([:anything])
  end

  def test_terminate_defaults_to_noop
    # Quiet hook: a subclass without its own terminate must not raise when quieted.
    assert_nil @fetcher.terminate
  end
end
