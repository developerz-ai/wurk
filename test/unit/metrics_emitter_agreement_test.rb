# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Wurk emits per-job metrics from two independent middlewares —
# Wurk::Metrics::History (Redis buckets, Ent §5) and Wurk::Metrics::Statsd
# (dogstatsd, Pro §9) — each carrying its own `success` boolean around the same
# `yield`. Nothing in the code couples them, so a classification change landing
# in one and not the other is invisible to either class's own tests while an
# operator watching both dashboards sees one job counted two ways.
#
# This pins the invariant the sign-off requires: one event, one classification,
# both emitters. docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md §1.
class MetricsEmitterAgreementTest < Wurk::Test::UnitCase
  parallelize_me!

  # `Wurk.configuration.dogstatsd` is process-global; see MetricsStatsdTest.
  def run(*args, &)
    Wurk::Test::STATSD_MUTEX.synchronize { super }
  end

  # Records the surface Metrics::Statsd reaches for. Only counter names
  # classify; the duration emits just have to not raise.
  class Recorder
    attr_reader :metrics

    def initialize
      @metrics = []
    end

    def increment(metric, **_opts)
      @metrics << metric
    end

    def gauge(_metric, _value, **_opts); end

    def distribution(_metric, _value, **_opts); end
  end

  # Job outcome → the classification both emitters owe it. The interrupted row
  # is #394: a cooperative interruption is not a failure.
  PATHS = [
    ['clean return', :processed, -> { :ok }],
    ['cooperative interruption', :processed, -> { raise Wurk::Job::Interrupted }],
    ['real exception', :failed, -> { raise 'boom' }]
  ].freeze

  def setup
    super
    @prev_builder = Wurk.configuration.dogstatsd
    Wurk::Metrics::Statsd.reset!
  end

  def teardown
    Wurk.configuration.dogstatsd = @prev_builder
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  def test_both_emitters_classify_every_path_identically
    PATHS.each do |name, expected, body|
      assert_equal expected, history_classification(body), "Metrics::History misclassified a #{name}"
      assert_equal expected, statsd_classification(body), "Metrics::Statsd misclassified a #{name}"
    end
  end

  private

  # Which counter Metrics::History moved for one run of `body`. The class name
  # is unique per call so the two candidate minute buckets (the middleware
  # records at its own Time.now, which may cross a minute) can be merged.
  def history_classification(body)
    klass = "AgreementJob-#{SecureRandom.hex(8)}"
    middleware = Wurk::Metrics::History.new
    middleware.config = Wurk.configuration
    before = ::Time.now.utc
    swallow { middleware.call(nil, { 'class' => klass }, 'default', &body) }
    Wurk::Metrics::History.flush

    fields = recorded_fields(klass, before, ::Time.now.utc)
    return :failed if fields.include?('f')

    fields.include?('p') ? :processed : :none
  end

  # Which counter Metrics::Statsd emitted for one run of `body`, in History's
  # vocabulary so the two answers compare directly.
  def statsd_classification(body)
    recorder = Recorder.new
    Wurk.configuration.dogstatsd = recorder
    middleware = Wurk::Metrics::Statsd.new
    middleware.config = Wurk.configuration
    swallow { middleware.call(nil, { 'class' => 'AgreementJob' }, 'default', &body) }

    return :failed if recorder.metrics.include?('sidekiq.jobs.failure')

    recorder.metrics.include?('sidekiq.jobs.success') ? :processed : :none
  end

  # Both middlewares re-raise; what they recorded on the way out is the
  # assertion, not the exception. Wurk::Job::Interrupted is a RuntimeError.
  def swallow
    yield
  rescue RuntimeError
    nil
  end

  def recorded_fields(klass, started_at, ended_at)
    [started_at, ended_at].map { |t| Wurk::Metrics::History.minute_key(t) }.uniq.flat_map do |key|
      raw = Wurk.redis { |conn| conn.call('HGETALL', key) }
      fields = raw.is_a?(::Hash) ? raw.keys : raw.each_slice(2).map(&:first)
      fields.select { |field| field.start_with?("#{klass}|") }.map { |field| field.split('|', 2).last }
    end
  end
end
