# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'

# Parity oracle for `Sidekiq::JobLogger`, docs/target/sidekiq-free.md §18:
# "start" / "done" / "fail" at INFO, and `Sidekiq::Context.add(:elapsed, seconds)`.
#
# Upstream measures the job in seconds, rounded to 3 places, so its log line
# reads `elapsed=0.007` (sidekiq 8.1.6 lib/sidekiq/job_logger.rb). Log scrapers
# and dashboards built on that line parse the field as seconds; a value in
# milliseconds reads as a job a thousand times slower.
class JobLoggerParityTest < Wurk::Test::UnitCase
  parallelize_me!

  WORK_SECONDS = 0.05

  def setup
    super
    @io = StringIO.new
    @config = Sidekiq::Config.new
    @config.logger = Sidekiq::Logger.new(@io)
    @config.logger.formatter = Sidekiq::Logger::Formatters::WithoutTimestamp.new
  end

  def teardown
    Sidekiq::Context.current.clear
    super
  end

  def test_done_line_carries_elapsed_in_seconds
    Sidekiq::Context.with({}) do
      Sidekiq::JobLogger.new(@config).call({}, 'default') { sleep WORK_SECONDS }
    end

    assert_elapsed_seconds(line('done'))
  end

  def test_fail_line_carries_elapsed_in_seconds
    Sidekiq::Context.with({}) do
      assert_raises(RuntimeError) do
        Sidekiq::JobLogger.new(@config).call({}, 'default') do
          sleep WORK_SECONDS
          raise 'boom'
        end
      end
    end

    assert_elapsed_seconds(line('fail'))
  end

  private

  def line(message)
    found = @io.string.lines.find { |l| l.end_with?(": #{message}\n") }

    assert found, "no #{message} line in #{@io.string.inspect}"
    found
  end

  # The job slept WORK_SECONDS, so seconds are at least that; the upper bound
  # only has to rule out milliseconds, which would read 50 or more.
  def assert_elapsed_seconds(line)
    raw = line[/ elapsed=([\d.]+)/, 1]

    assert raw, "no elapsed= field in #{line.inspect}"
    assert_match(/\A\d+\.\d{1,3}\z/, raw, 'elapsed is a Float rounded to 3 places')
    assert_operator Float(raw), :>=, WORK_SECONDS
    assert_operator Float(raw), :<, WORK_SECONDS * 1000, "elapsed=#{raw} reads as milliseconds"
  end
end
