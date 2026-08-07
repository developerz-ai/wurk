# frozen_string_literal: true

module Wurk
  module Middleware
    # Ordered list of middleware bound to a config/capsule. Sidekiq contract:
    # `add` appends (removing any existing entry for the same klass), `prepend`
    # pushes to index 0, `insert_before`/`insert_after` anchor relative to an
    # existing entry, `invoke` walks the chain handing the inner block to each.
    #
    # Entries store klass + ctor args, not the live object: every job gets a
    # fresh instance per entry (`invoke` builds each as it reaches it, `retrieve`
    # builds them all up front). This keeps middleware thread-safe by
    # construction and matches Sidekiq's lifecycle.
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
      #
      # Hot path — one job pays this per invocation, so instantiation is folded
      # into an index walk over `@entries`: no instance array from `retrieve`,
      # no traversal lambda, and no `shift` (which memmoves the array per entry).
      # Cost is one allocation per entry (the middleware itself), zero to walk.
      def invoke(*args, &block)
        raise ArgumentError, 'middleware chain requires a block' unless block
        return yield if @entries.empty?

        traverse(@entries, 0, args, &block)
      end

      private

      def traverse(entries, index, args, &block)
        return yield if index == entries.size

        entries[index].make_new(@config).call(*args) do
          traverse(entries, index + 1, args, &block)
        end
      end

      # Custom dup semantics: deep-copy the entries array so a child chain's
      # mutations don't bleed into the parent (or sibling capsules).
      def initialize_copy(orig)
        super
        @entries = orig.entries.dup
      end

      # Holds the klass + ctor args for a registered middleware. Defers
      # instantiation until `retrieve`/`invoke` runs so each job gets a fresh
      # object.
      #
      # Whether the class declares `config=` is resolved once, at registration,
      # so the common case (the setter comes from `include
      # Wurk::Middleware::ServerMiddleware`) skips a `respond_to?` on every job
      # × every entry. It is a fast path, not the rule: the contract is "set
      # `config` if the instance is respondable" (spec §10.1), which also covers
      # a setter defined on the singleton in `initialize`, one reached through
      # `method_missing`, or one added to the class after it was registered — so
      # a class that does not declare it still gets asked.
      class Entry
        attr_reader :klass

        def initialize(klass, *args)
          @klass = klass
          @args = args
          @takes_config = klass.public_method_defined?(:config=)
        end

        def make_new(config = nil)
          instance = @klass.new(*@args)
          instance.config = config if config && (@takes_config || instance.respond_to?(:config=))
          instance
        end
      end
    end
  end
end
