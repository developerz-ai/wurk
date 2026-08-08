# frozen_string_literal: true

require 'json'

module Wurk
  module Status
    # Read-only view of one `status:<jid>` HASH. Redis hands back strings for
    # everything; this is where they become the types a caller expects, so no
    # consumer (dashboard, HTTP API, a chain deciding what to pipe onward) has
    # to know the row is stringly-typed on the wire.
    #
    # A field the writer never set reads as nil rather than 0 or '' — "this job
    # reported no progress" and "this job is at 0" are different answers.
    class Record
      attr_reader :jid, :data

      def initialize(jid, data)
        @jid  = jid
        @data = data.freeze
      end

      def state         = @data['state']
      def queue         = @data['queue']
      def message       = @data['message']
      def error_class   = @data['error_class']
      def error_message = @data['error_message']

      # `class` is the wire field name — it matches the job hash — but it is
      # not a legal reader name.
      def job_class = @data['class']

      def progress = @data['progress']&.to_i
      def total    = @data['total']&.to_i
      def attempt  = @data['attempt']&.to_i

      def enqueued_at = @data['enqueued_at']&.to_f
      def started_at  = @data['started_at']&.to_f
      def finished_at = @data['finished_at']&.to_f

      # The stored return value of `perform`, decoded. JSON only — see
      # CLAUDE.md; a result that wouldn't serialize never reached Redis.
      def result
        raw = @data['result']
        raw && ::JSON.parse(raw)
      end

      # Raw field access for anything without a reader.
      def [](field) = @data[field.to_s]

      # Wire field names, not reader names: this hash is what the dashboard and
      # the HTTP API serve, and `class` is the name every other Wurk JSON
      # surface uses for a job's class.
      def to_h
        { 'jid' => jid, 'state' => state, 'queue' => queue, 'class' => job_class,
          'enqueued_at' => enqueued_at, 'started_at' => started_at, 'finished_at' => finished_at,
          'progress' => progress, 'total' => total, 'message' => message, 'result' => result,
          'error_class' => error_class, 'error_message' => error_message, 'attempt' => attempt }
      end
    end
  end
end
