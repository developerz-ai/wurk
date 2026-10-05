# frozen_string_literal: true

require 'json'
require_relative '../cron'

module Wurk
  module Import
    # Reads the schedule sidekiq-cron keeps in Redis and maps each entry onto a
    # native periodic loop (`Wurk::Cron::Loop`). `rake wurk:import:cron` drives
    # it: a dry run prints the plan plus a `config.periodic` block to paste into
    # code; `APPLY=1` persists the loops straight into the `periodic` registry.
    #
    # sidekiq-cron's layout (v1.12+ / 2.x, namespaced): `cron_jobs:<namespace>`
    # is a SET of `cron_job:<namespace>:<name>` HASH keys. Releases before
    # namespaces used one `cron_jobs` SET of `cron_job:<name>` keys; both are
    # read. Nothing here writes or deletes a sidekiq-cron key, so a rollback to
    # Sidekiq still finds its schedule intact.
    class SidekiqCron
      LEGACY_SET = 'cron_jobs'
      NAMESPACED_SETS = 'cron_jobs:*'
      GLOBALID_KEY = '_sc_globalid'
      TRUE_FLAG = /\A(?:true|t|yes|y|1)\z/i
      ZONE_TOKEN = %r{\A[A-Za-z][A-Za-z0-9_+\-/]*\z}

      # One sidekiq-cron entry and what it becomes. `loop` is nil exactly when
      # `skip_reason` says why the entry cannot be carried over unchanged.
      Entry = Struct.new(:key, :namespace, :name, :source, :loop, :skip_reason, :warnings, keyword_init: true) do
        def importable? = !loop.nil?
      end

      def entries
        rows = redis do |c|
          keys = schedule_keys(c)
          keys.map { |key| [key, c.call('HGETALL', key).to_h] }
        end
        rows.reject { |(_key, h)| h.empty? }.map { |key, h| build_entry(key, h) }
      end

      # Persists every importable entry and returns the entries it wrote.
      # Idempotent: a loop's lid is a hash of its schedule, class and options,
      # so a second run rewrites the same keys, and `paused` is only seeded
      # (Cron.persist uses HSETNX), so a dashboard pause survives a re-import.
      def apply!(list = entries)
        list.select(&:importable?).each { |entry| Cron.persist(entry.loop) }
      end

      def registered?(lid)
        redis { |c| c.call('SISMEMBER', Cron::PERIODIC_KEY, lid) }.to_i == 1
      end

      # What `rake wurk:import:cron` prints. Returns the entries it found.
      def run(apply:, out: $stdout)
        list = entries
        if list.empty?
          out.puts "No sidekiq-cron entries found (looked for #{NAMESPACED_SETS} and #{LEGACY_SET})."
          return list
        end

        report(list, out)
        if apply
          written = apply!(list)
          out.puts "\nRegistered #{written.size} loop(s) in the `#{Cron::PERIODIC_KEY}` registry. " \
                   'sidekiq-cron keys were left untouched.'
        else
          out.puts "\nDry run: nothing was written. Re-run with APPLY=1 to register the importable loops in Redis."
        end
        list
      end

      private

      def report(list, out)
        importable = list.select(&:importable?)
        out.puts "sidekiq-cron entries: #{list.size} (#{importable.size} importable, " \
                 "#{list.size - importable.size} skipped)\n\n"
        list.each { |entry| report_entry(entry, out) }
        return if importable.empty?

        out.puts "\nTo keep these in code (recommended), paste into config/initializers/wurk.rb:\n\n"
        out.puts snippet(importable)
      end

      def report_entry(entry, out)
        id = "#{entry.namespace}/#{entry.name}"
        if entry.importable?
          lp = entry.loop
          state = registered?(lp.lid) ? 'already registered' : 'new'
          out.puts "  import  #{id}  #{lp.schedule.inspect} #{lp.klass}  -> lid #{lp.lid} (#{state})"
        else
          out.puts "  skip    #{id}  #{entry.skip_reason}"
        end
        entry.warnings.each { |w| out.puts "  warn    #{id}  #{w}" }
      end

      def snippet(entries)
        lines = entries.map do |entry|
          lp = entry.loop
          opts = lp.options.map { |k, v| "#{k}: #{v.inspect}" }
          opts << "tz: #{lp.tz_name.inspect}" if lp.tz_name
          "    mgr.register(#{[lp.schedule.inspect, lp.klass.inspect, *opts].join(', ')})"
        end
        ['Wurk.configure_server do |config|', '  config.periodic do |mgr|', *lines, '  end', 'end'].join("\n")
      end

      def schedule_keys(conn)
        sets = scan(conn, NAMESPACED_SETS)
        sets << LEGACY_SET if conn.call('EXISTS', LEGACY_SET).to_i == 1
        sets.flat_map { |set| conn.call('SMEMBERS', set) }.uniq.sort
      end

      def scan(conn, pattern)
        cursor = '0'
        found = []
        loop do
          cursor, batch = conn.call('SCAN', cursor, 'MATCH', pattern, 'COUNT', 500)
          found.concat(batch)
          break if cursor == '0'
        end
        found.select { |key| conn.call('TYPE', key) == 'set' }.sort
      end

      def build_entry(key, h)
        entry = Entry.new(key: key, namespace: blank(h['namespace']) || 'default', name: h['name'].to_s,
                          source: blank(h['source']) || 'dynamic', warnings: [])
        entry.skip_reason = skip_reason(h)
        entry.loop = build_loop(h, entry) unless entry.skip_reason
        entry
      rescue ArgumentError => e
        entry.loop = nil
        entry.skip_reason = e.message
        entry
      end

      def skip_reason(hash)
        return 'no class (`klass`) recorded' if blank(hash['klass'] || hash['class']).nil?
        return 'no cron expression recorded' if blank(hash['cron']).nil?
        return '`date_as_argument` appends the enqueue time to args; Wurk loops have no equivalent' if
          flag?(hash['date_as_argument'])
        return 'args carry a serialized GlobalID; Wurk loops pass args verbatim' if
          hash['args'].to_s.include?(GLOBALID_KEY)

        nil
      end

      def build_loop(hash, entry)
        schedule, tz = split_zone(hash['cron'].strip)
        validate_schedule!(schedule)
        message = parse_json(hash['message'])
        Cron::Loop.new(schedule: schedule, klass: (hash['klass'] || hash['class']).to_s, tz: tz,
                       options: options_for(hash, message, entry))
      end

      def validate_schedule!(schedule)
        Cron::Parser.new(schedule)
      rescue ArgumentError => e
        raise ArgumentError, "unsupported schedule #{schedule.inspect} (#{e.message}); Wurk takes a " \
                             '5-field crontab or an @alias, not fugit seconds or natural language'
      end

      # fugit accepts a trailing zone (`0 5 * * * Europe/Paris`); Wurk takes the
      # zone as `tz:`. A sixth token that is not a zone is fugit's seconds field
      # or natural language, which the native 5-field parser rejects.
      def split_zone(cron)
        tokens = cron.split
        return [cron, nil] unless tokens.size == 6 && tokens.last.match?(ZONE_TOKEN) && tokens.last.match?(/[A-Za-z]/)

        zone = tokens.last
        raise ArgumentError, "unknown timezone #{zone.inspect}" unless Cron::Parser.resolve_zone(zone)

        [tokens.first(5).join(' '), zone]
      end

      def options_for(hash, message, entry)
        add_warnings(hash, entry)
        args = args_for(hash['args'])
        opts = { 'label' => label_for(entry) }
        opts['args'] = args unless args.empty?
        opts.merge!(message_options(message))
        opts['paused'] = true if hash['status'] == 'disabled'
        opts
      end

      # The label is part of the loop's lid, so it has to carry the namespace:
      # sidekiq-cron keys an entry by namespace + name, and `nightly` in
      # `billing` and in `default` are two jobs that must stay two loops. The
      # default namespace (and the pre-namespace legacy set) keeps the bare
      # name, so an entry imported before this keeps its lid on re-import.
      def label_for(entry)
        entry.namespace == 'default' ? entry.name : "#{entry.namespace}/#{entry.name}"
      end

      # sidekiq-cron pushes the queue and retry frozen into `message` when the
      # entry was saved, not the worker's current options.
      def message_options(message)
        opts = {}
        opts['queue'] = message['queue'] if blank(message['queue'])
        opts['retry'] = retry_value(message['retry']) unless message['retry'].nil?
        opts
      end

      def add_warnings(hash, entry)
        if blank(hash['queue_name_prefix'])
          entry.warnings << "ActiveJob `queue_name_prefix` #{hash['queue_name_prefix'].inspect} is not carried over"
        end
        return unless flag?(hash['symbolize_args'])

        entry.warnings << '`symbolize_args` is not carried over; hash args arrive with string keys'
      end

      # sidekiq-cron stores args as a JSON string, falling back to `[*raw]` when
      # it does not parse; a bare Hash becomes the single argument.
      def args_for(raw)
        return [] if blank(raw).nil?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : [parsed]
      rescue JSON::ParserError
        [raw]
      end

      def retry_value(value)
        return value unless value.is_a?(String)
        return true if value == 'true'
        return false if value == 'false'

        value.match?(/\A\d+\z/) ? value.to_i : value
      end

      def parse_json(raw)
        return {} if blank(raw).nil?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def flag?(value) = value == true || value.to_s.match?(TRUE_FLAG)

      def blank(value)
        str = value&.to_s
        str.nil? || str.strip.empty? ? nil : str
      end

      def redis(&) = Wurk.redis(&)
    end
  end
end
