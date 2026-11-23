# frozen_string_literal: true

module Wurk
  module SidekiqCron
    # A sidekiq-cron `cron` string, read the way its fugit parser reads the
    # forms a schedule file uses: five crontab fields or an `@alias`, then an
    # optional IANA zone (`*/5 * * * * America/Caracas`). Month and weekday
    # names (`jan`, `mon-fri`) are accepted. Wurk's own {Cron::Parser} answers
    # the match, so the native periodic loops and this agree on every schedule.
    #
    # Not accepted, and reported as a validation error rather than guessed:
    # a seconds field, fugit's natural language (`every day at 5pm`), `L`/`#`
    # day forms, and numeric offsets in place of a zone.
    class Schedule
      MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
      DAYS = %w[sun mon tue wed thu fri sat].freeze

      # The newest occurrence the poller can still fire is at most
      # `reschedule_grace_period` old; a save looks back further, to the
      # occurrence the gem marks as already enqueued (`Job#save`).
      CREATION_LOOKBACK = 366 * 24 * 3600

      # No zone in the string means the process's local zone, as fugit reads
      # it (ENV['TZ'], else the system's), not UTC as a periodic loop does.
      module LocalZone
        def self.at(epoch) = ::Time.at(epoch)
      end

      attr_reader :parser, :zone

      def initialize(string)
        tokens = string.to_s.strip.split(/\s+/)
        fields, rest = split_fields(tokens, string)
        raise ArgumentError, "expected one trailing timezone, got #{rest.join(' ').inspect}" if rest.size > 1

        @zone = rest.empty? ? LocalZone : resolve_zone(rest.first, string)
        @parser = Cron::Parser.new(fields.join(' '))
      end

      def crontab = @parser.expression

      # The zone the string names, nil for the local zone.
      def zone_name = @zone.equal?(LocalZone) ? nil : @zone.identifier

      # Latest occurrence at or before `time - 1s`, whole seconds, as a UTC Time
      # (fugit's `previous_time`: it steps one second back, then truncates).
      # Nil when there is none within `lookback` seconds. sidekiq-cron keys a
      # fire by this instant, so it has to be the same one the gem computes.
      def previous_time(time, lookback)
        from = (time.to_f - 1).floor
        epoch = from - (from % 60)
        floor = from - lookback
        while epoch >= floor
          local = @parser.local_components(epoch, @zone)
          return ::Time.at(epoch).utc if @parser.match?(::Time.at(epoch), @zone)

          # Inside an hour whose hour or day cannot match, skip to the minute
          # before that hour began; otherwise step one minute.
          epoch -= hour_open?(local) ? 60 : (local[0] * 60) + 60
        end
        nil
      end

      def next_time(time)
        epoch = @parser.next_fire_at(time.to_i, @zone)
        epoch && ::Time.at(epoch).utc
      end

      private

      def split_fields(tokens, string)
        return split_alias(tokens, string) if tokens.first.to_s.start_with?('@')
        raise ArgumentError, "not a 5-field crontab: #{string.inspect}" if tokens.size < 5

        fields = tokens.first(5)
        fields[3] = names_to_numbers(fields[3], MONTHS, 1)
        fields[4] = names_to_numbers(fields[4], DAYS, 0)
        [fields, tokens.drop(5)]
      end

      def split_alias(tokens, string)
        crontab = Cron::Parser::ALIASES[tokens.first.downcase]
        raise ArgumentError, "unknown cron alias in #{string.inspect}" unless crontab

        [crontab.split, tokens.drop(1)]
      end

      def names_to_numbers(field, names, base)
        field.downcase.gsub(/[a-z]{3}/) do |name|
          index = names.index(name)
          raise ArgumentError, "unknown name #{name.inspect} in cron field #{field.inspect}" unless index

          (index + base).to_s
        end
      end

      def resolve_zone(name, string)
        zone = name.match?(%r{\A[A-Za-z][A-Za-z0-9_+\-/]*\z}) ? Cron::Parser.resolve_zone(name) : nil
        return zone if zone

        raise ArgumentError, "#{name.inspect} in #{string.inspect} is not a timezone tzinfo knows " \
                             '(a seconds field and natural-language schedules are not supported)'
      end

      # Never false for an hour that holds a match: the day test is the looser
      # OR of the two day fields, whichever the parser applies.
      def hour_open?(local)
        _min, hour, dom, mon, dow = local
        fields = @parser.fields
        fields[1].include?(hour) && fields[3].include?(mon) && (fields[2].include?(dom) || fields[4].include?(dow))
      end
    end
  end
end
