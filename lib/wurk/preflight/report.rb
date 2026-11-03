# frozen_string_literal: true

require 'json'

module Wurk
  module Preflight
    # What a run found. `warning` findings decide the exit status; `info` findings
    # are facts an operator should see that do not by themselves mean trouble.
    class Report
      CLEAN = 0
      FINDINGS = 1
      LABELS = { warning: 'WARN', info: 'info' }.freeze
      APP_CODE_RAN = 'app_code_ran'

      Finding = Struct.new(:severity, :code, :message)

      attr_reader :findings, :sections

      def initialize(command)
        @command = command
        @findings = []
        @sections = {}
      end

      def warning(code, message) = @findings << Finding.new(:warning, code, message)
      def info(code, message) = @findings << Finding.new(:info, code, message)
      def section(name, data) = @sections[name] = data

      # Which Redis this verdict is about, first in the report. An empty keyspace is
      # far likelier a wrong URL or DB than a real Redis with nothing in it.
      def target(reader, keyspace)
        place = reader.target
        section('target', place)
        return unless keyspace.scanned.zero?

        warning('empty_keyspace', "No keys in #{::JSON.generate(place)}. A Redis with a live fleet is never empty: " \
                                  'check this is the right URL and DB.')
      end

      def exit_status = @findings.any? { |finding| finding.severity == :warning } ? FINDINGS : CLEAN

      def to_h
        scrub({ 'command' => @command, 'status' => exit_status.zero? ? 'clean' : 'findings', 'sections' => @sections,
                'findings' => @findings.map { |f| finding_row(f) } })
      end

      def to_json(*) = ::JSON.pretty_generate(to_h)

      def to_text
        ordered = @findings.sort_by { |f| f.severity == :warning ? 0 : 1 }
        [*scrub(@sections).map { |name, data| "#{name}: #{::JSON.generate(data)}" }, '',
         *ordered.map { |f| scrub(line_for(f)) }, '', summary].join("\n")
      end

      private

      def finding_row(finding)
        { 'severity' => finding.severity.to_s, 'code' => finding.code, 'message' => finding.message }
      end

      def summary
        warnings = @findings.count { |f| f.severity == :warning }
        return "wurk #{@command}: #{warnings} finding(s) to review" unless warnings.zero?

        ran = @findings.any? { |f| f.code == APP_CODE_RAN }
        "wurk #{@command}: #{ran ? 'nothing found in Redis, but app code ran: see above' : 'clean'}"
      end

      # Keys and payload fields can hold any bytes; output must stay valid UTF-8.
      def scrub(value)
        case value
        when ::String then value.dup.force_encoding(::Encoding::UTF_8).scrub('?')
        when ::Hash then value.to_h { |k, v| [scrub(k), scrub(v)] }
        when ::Array then value.map { |v| scrub(v) }
        else value
        end
      end

      def line_for(finding) = "#{LABELS.fetch(finding.severity)} #{finding.code}: #{finding.message}"
    end
  end
end
