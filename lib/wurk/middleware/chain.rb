# frozen_string_literal: true

module Wurk
  module Middleware
    # Ordered list of middleware bound to a config/capsule. Sidekiq contract:
    # `add` appends (removing any existing entry for the same klass), `prepend`
    # pushes to index 0, `insert_before`/`insert_after` anchor relative to an
    # existing entry, `invoke` walks the chain handing the inner block to each.
    #
    # `add` has one opt-in exception, declared per middleware class: a class
    # may name the classes it must stay OUTSIDE of in a class-level `outer_of`,
    # and `add` then places it before the first of those anchors instead of at
    # the tail. A class that declares no anchor keeps the plain append.
    #
    # Entries store klass + ctor args + the config they were registered with,
    # not the live object: every job gets a
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

      # Bind a duplicate of this chain to `capsule`. Entries carry their
      # config, so each is duplicated and only the duplicate rebound: the
      # capsule's middleware resolve the capsule while the parent's entries
      # keep the parent config. Array#dup on `@entries` keeps the two chains
      # independent after the first `add`/`remove`/etc.
      def copy_for(capsule)
        copy = dup
        copy.instance_variable_set(:@config, capsule)
        copy.entries.map! do |entry|
          rebound = entry.dup
          rebound.config = capsule
          rebound
        end
        copy
      end

      def remove(klass)
        @entries.delete_if { |entry| entry.klass == klass }
      end

      # Appends the middleware — the documented Sidekiq behaviour (spec
      # §10.1): any existing entry for `klass` is removed and the new one
      # lands at the tail (innermost).
      #
      # One opt-in exception, declared per class: a middleware may name the
      # classes it must stay OUTSIDE of in a class-level `outer_of`. When one
      # of those anchors is registered, the entry is placed before the first
      # of them instead of at the tail — so re-registering such a middleware
      # cannot silently move it inside the middleware it depends on being
      # outside of. A class that declares no anchor keeps the plain append.
      #
      # An entry already registered before the anchor keeps its slot (only
      # its ctor args are refreshed): moving it would be a relocation the
      # caller did not ask for.
      def add(klass, *)
        entry = make_entry(klass, *)
        anchors = anchor_classes(klass)
        existing = @entries.index { |e| e.klass == klass }
        anchor = @entries.index { |e| anchors.include?(e.klass) }

        # No anchor registered: remove the old entry, append at the tail.
        if anchor.nil?
          remove(klass)
          @entries << entry
          return @entries
        end

        # Already outside the anchor: keep the slot, refresh the entry.
        if existing && existing < anchor
          @entries[existing] = entry
          return @entries
        end

        # Registered inside the anchor (or not registered at all): move it
        # out, to just before the first anchor.
        remove(klass)
        @entries.insert(anchor, entry)
        @entries
      end

      def prepend(klass, *)
        remove(klass)
        @entries.unshift(make_entry(klass, *))
      end

      def insert_before(oldklass, newklass, *)
        i = @entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? make_entry(newklass, *) : @entries.delete_at(i)
        i = @entries.index { |entry| entry.klass == oldklass } || 0
        @entries.insert(i, new_entry)
      end

      def insert_after(oldklass, newklass, *)
        i = @entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? make_entry(newklass, *) : @entries.delete_at(i)
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
        map(&:make_new)
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

        entries[index].make_new.call(*args) do
          traverse(entries, index + 1, args, &block)
        end
      end

      # Custom dup semantics: deep-copy the entries array so a child chain's
      # mutations don't bleed into the parent (or sibling capsules).
      def initialize_copy(orig)
        super
        @entries = orig.entries.dup
      end

      # The ordering anchors a middleware class declares, if any: a class-level
      # `outer_of` returning the classes it must stay OUTSIDE of. Empty when
      # the class declares none — the plain Sidekiq append.
      def anchor_classes(klass)
        return [] unless klass.respond_to?(:outer_of)

        Array(klass.outer_of)
      end

      # Registration binds the entry to this chain's config/capsule so that
      # `Entry#make_new` can stay zero-argument (spec §10.1).
      def make_entry(klass, *)
        entry = Entry.new(klass, *)
        entry.config = @config
        entry
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
        attr_accessor :config

        def initialize(klass, *args)
          @klass = klass
          @args = args
          @takes_config = klass.public_method_defined?(:config=)
        end

        def make_new
          instance = @klass.new(*@args)
          instance.config = config if @takes_config || instance.respond_to?(:config=)
          instance
        end
      end
    end
  end
end
