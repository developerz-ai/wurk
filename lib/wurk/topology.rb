# frozen_string_literal: true

module Wurk
  # Worker topology DSL (Wurk extension on top of Ent's flat swarm).
  # Lets users declare specialized slots: e.g. 2 forks dedicated to the
  # critical queue with low concurrency, 2 forks for bulk + low with high
  # concurrency. Stronger queue isolation than a flat swarm.
  #
  # Each Slot describes a *kind* of fork; `count` is how many identical
  # forks of that kind to spawn. Swarm consumes `assignments` (the flat
  # list of forks to spawn, in order) so a slot with count=2 yields two
  # assignment entries pointing at the same Slot.
  #
  # See docs/idea/03-process-model.md §Worker topology.
  class Topology
    # `:count` shadows Struct#count by design — Slot is a kw-init data
    # carrier and the slot's child-count is the field users read.
    Slot = Struct.new(:count, :queues, :concurrency, keyword_init: true) do # rubocop:disable Lint/StructNewOverride
      def to_h
        { count: count, queues: queues, concurrency: concurrency }
      end
    end

    def initialize
      @slots = []
    end

    # Declare one slot kind. Returns self so calls chain.
    def slot(count:, queues:, concurrency:)
      queue_list = validate_slot!(count, queues, concurrency)
      @slots << Slot.new(count: count, queues: queue_list, concurrency: concurrency).freeze
      self
    end

    def slots
      @slots.dup.freeze
    end

    def empty?
      @slots.empty?
    end

    # Flat ordered list of slots to fork, one per child process. A slot
    # with count=N contributes N entries.
    def assignments
      @slots.flat_map { |s| Array.new(s.count, s) }
    end

    def total_processes
      @slots.sum(&:count)
    end

    # Convenience: build a flat topology of `count` identical forks
    # consuming `queues` with `concurrency` threads each. Used by the
    # railtie when the host hasn't declared a custom topology.
    def self.flat(count:, queues:, concurrency:)
      new.slot(count: count, queues: queues, concurrency: concurrency)
    end

    private

    def validate_slot!(count, queues, concurrency)
      raise ArgumentError, "count must be > 0 (got #{count.inspect})" unless count.is_a?(Integer) && count.positive?
      unless concurrency.is_a?(Integer) && concurrency.positive?
        raise ArgumentError, "concurrency must be > 0 (got #{concurrency.inspect})"
      end

      queue_list = Array(queues).map(&:to_s)
      raise ArgumentError, 'queues cannot be empty' if queue_list.empty?

      queue_list.freeze
    end
  end
end
