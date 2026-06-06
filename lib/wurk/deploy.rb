# frozen_string_literal: true

module Wurk
  # Records deploy markers into Redis so the history pane can overlay
  # "deployed at" lines onto job-throughput charts. Wire-compatible with
  # Sidekiq's `Sidekiq::Deploy`:
  #
  #   <YYYYMMDD>-marks    HASH    fields = iso8601 timestamp (rounded to minute),
  #                               values = label string, TTL = 90 days
  #   deploylock-<label>  STRING  SET NX EX 60, dedupe lock for same-label marks
  #
  # The lock collapses multiple `mark!` calls for the same label inside a
  # 60-second window into a single HSET — fleet-wide deploys where every
  # process calls `Wurk::Deploy.mark!` at boot end up with one row, not N.
  #
  # Spec: docs/target/sidekiq-free.md §23.
  class Deploy
    MARK_TTL = 90 * 24 * 60 * 60   # 90 days
    LOCK_TTL = 60                  # 1 minute dedupe window
    LOCK_PREFIX = 'deploylock-'
    MARKS_SUFFIX = '-marks'

    # Default label maker: short git SHA + commit subject. Same shape as
    # Sidekiq Pro's LABEL_MAKER so existing deploy hooks keep working.
    LABEL_MAKER = -> { `git log -1 --format="%h %s"`.strip }

    # Class-level shorthand: builds a one-shot Deploy and delegates. Sidekiq's
    # `Sidekiq::Deploy.mark!` takes a POSITIONAL label (spec §23,
    # `def self.mark!(label = nil)`) — capistrano-sidekiq and custom deploy
    # hooks call `Sidekiq::Deploy.mark!("abc123 release")` that way. The `**opts`
    # also absorbs the `label:` keyword so Wurk's own keyword callers keep
    # working; positional wins when both are given.
    def self.mark!(label = nil, at: ::Time.now, **opts)
      new.mark!(label: label.nil? ? opts[:label] : label, at: at)
    end

    def initialize(pool: nil)
      @pool = pool
    end

    # Writes a deploy marker. Returns the iso8601 timestamp written, or
    # `nil` when the per-label lock was already held (a previous process
    # within the last 60 seconds beat us to it for the same label).
    def mark!(label: nil, at: ::Time.now)
      label = resolve_label(label)
      return nil if label.nil? || label.empty?

      ts = round_to_minute(at)
      iso = ts.iso8601
      write_mark?(label, ts, iso) ? iso : nil
    end

    # Returns the deploy marks for `date` (Date or Time) as `{iso8601 => label}`.
    def fetch(date = ::Time.now.utc)
      date = date.utc if date.respond_to?(:utc)
      key = "#{date.strftime('%Y%m%d')}#{MARKS_SUFFIX}"
      with_redis { |c| c.call('HGETALL', key) } || {}
    end

    private

    def round_to_minute(at)
      utc = at.utc
      ::Time.utc(utc.year, utc.month, utc.day, utc.hour, utc.min)
    end

    def write_mark?(label, time, iso)
      lock_key = "#{LOCK_PREFIX}#{label}"
      marks_key = "#{time.strftime('%Y%m%d')}#{MARKS_SUFFIX}"
      with_redis do |conn|
        return false unless conn.call('SET', lock_key, iso, 'NX', 'EX', LOCK_TTL) == 'OK'

        conn.call('HSET', marks_key, iso, label)
        conn.call('EXPIRE', marks_key, MARK_TTL)
      end
      true
    end

    def resolve_label(label)
      return label unless label.nil? || label.empty?

      LABEL_MAKER.call
    rescue StandardError
      nil
    end

    def with_redis(&)
      if @pool
        @pool.with(&)
      else
        Wurk.redis(&)
      end
    end
  end
end
