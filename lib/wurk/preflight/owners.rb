# frozen_string_literal: true

require 'json'
require_relative '../keys'

module Wurk
  module Preflight
    # Live processes and the private lists they own, judged by the same rule the
    # Reaper uses: an identity is alive while its heartbeat `info` field exists.
    # A pre-nonce key can only match on `<host>:<pid>`.
    class Owners
      Process = Struct.new(:identity, :version, :wurk, :queues, :quiet) do
        def to_h
          { 'identity' => identity, 'version' => version, 'wurk' => wurk, 'queues' => queues, 'quiet' => quiet }
        end
      end

      attr_reader :processes, :stale

      def initialize(reader) # rubocop:disable Metrics/AbcSize
        ids = reader.call('SMEMBERS', Keys::PROCESSES)
        rows = reader.pipeline(ids.map { |id| ['HMGET', id, 'info', 'quiet'] })
        live, gone = ids.zip(rows).partition { |_, (info, _)| info }
        @stale = gone.map(&:first)
        @processes = live.map { |id, (info, quiet)| build(id, info, quiet) }
        @live = @processes.flat_map { |p| [p.identity, p.identity.split(':').first(2).join(':')] }.to_set
        @public_queues = reader.call('SMEMBERS', Keys::QUEUES_SET).to_set { |q| "#{Keys::QUEUE_PREFIX}#{q}" }
      end

      def public_queue?(key) = @public_queues.include?(key)
      def queue_names = @public_queues.map { |key| key.delete_prefix(Keys::QUEUE_PREFIX) }

      # `{ 'owner_alive' => [...], 'reclaimable' => [...], 'unparseable' => [...] }`,
      # ignoring public queues whose own name holds a `|`.
      def classify(keys)
        out = { 'owner_alive' => [], 'reclaimable' => [], 'unparseable' => [] }
        keys.each do |key|
          next if public_queue?(key)

          out[verdict(key)] << key
        end
        out
      end

      def foreign = @processes.reject(&:wurk)

      private

      def verdict(key)
        parsed = Fetcher::PrivateListKey.parse_full(key)
        return 'unparseable' unless parsed

        _queue, host, pid, nonce = parsed
        owner = nonce ? "#{host}:#{pid}:#{nonce}" : "#{host}:#{pid}"
        @live.include?(owner) ? 'owner_alive' : 'reclaimable'
      end

      # Wurk's heartbeat always carries `cores`; stock does not (see BootChecks).
      def build(identity, info, quiet)
        data = parse(info)
        Process.new(identity, data['version'].to_s, data.key?('cores'), Array(data['queues']).map(&:to_s).uniq,
                    quiet == 'true')
      end

      def parse(info)
        parsed = ::JSON.parse(info)
        parsed.is_a?(::Hash) ? parsed : {}
      rescue ::JSON::ParserError
        {}
      end
    end
  end
end
