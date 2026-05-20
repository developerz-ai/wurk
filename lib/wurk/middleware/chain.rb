# frozen_string_literal: true

module Wurk
  module Middleware
    # Ordered list of middleware bound to a config/capsule. Sidekiq contract:
    # `add` appends (removing any existing entry for the same klass), `prepend`
    # pushes to index 0, `insert_before`/`insert_after` anchor relative to an
    # existing entry, `invoke` walks the chain handing the inner block to each.
    #
    # `retrieve` instantiates a fresh instance per entry on every job — entries
    # store klass + ctor args, not the live object. This keeps middleware
    # thread-safe by construction and matches Sidekiq's lifecycle.
    #
    # Spec: docs/target/sidekiq-free.md §10.1.
    class Chain
      include Enumerable

      attr_reader :entries
      attr_accessor :config

      def initialize(config = nil)
        @config = config
        @entries = []
        yield self if block_given?
      end

      def each(&) = @entries.each(&)

      # Bind a duplicate of this chain to `capsule`. Capsules share the parent
      # config's entries by reference initially but mutate independently after
      # the first `add`/`remove`/etc. (Array#dup on `@entries`).
      def copy_for(capsule)
        copy = dup
        copy.instance_variable_set(:@config, capsule)
        copy
      end

      def remove(klass)
        @entries.delete_if { |entry| entry.klass == klass }
      end

      def add(klass, *)
        remove(klass)
        @entries << Entry.new(klass, *)
      end

      def prepend(klass, *)
        remove(klass)
        @entries.unshift(Entry.new(klass, *))
      end

      def insert_before(oldklass, newklass, *)
        i = @entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? Entry.new(newklass, *) : @entries.delete_at(i)
        i = @entries.index { |entry| entry.klass == oldklass } || 0
        @entries.insert(i, new_entry)
      end

      def insert_after(oldklass, newklass, *)
        i = @entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? Entry.new(newklass, *) : @entries.delete_at(i)
        i = @entries.index { |entry| entry.klass == oldklass } || (@entries.size - 1)
        @entries.insert(i + 1, new_entry)
      end

      def exists?(klass)
        any? { |entry| entry.klass == klass }
      end
      alias include? exists?

      def empty?
        @entries.empty?
      end

      def retrieve
        map { |entry| entry.make_new(@config) }
      end

      def clear
        @entries.clear
      end

      # Walks the chain inside-out. Each middleware receives a block that
      # advances to the next; the innermost block is the caller's `&block`,
      # whose return value is propagated back out. Empty chain: `yield`.
      def invoke(*args, &block)
        return yield if @entries.empty?

        chain = retrieve
        traverse = lambda do
          if chain.empty?
            block.call
          else
            chain.shift.call(*args, &traverse)
          end
        end
        traverse.call
      end

      private

      # Custom dup semantics: deep-copy the entries array so a child chain's
      # mutations don't bleed into the parent (or sibling capsules).
      def initialize_copy(orig)
        super
        @entries = orig.entries.dup
      end

      # Holds the klass + ctor args for a registered middleware. Defers
      # instantiation until `retrieve` runs so each job gets a fresh object.
      class Entry
        attr_reader :klass

        def initialize(klass, *args)
          @klass = klass
          @args = args
        end

        def make_new(config = nil)
          instance = @klass.new(*@args)
          instance.config = config if config && instance.respond_to?(:config=)
          instance
        end
      end
    end
  end
end
