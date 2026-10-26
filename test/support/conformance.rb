# frozen_string_literal: true

require 'yaml'
require 'minitest'

module Conformance
  ROOT = File.expand_path('../..', __dir__)
  # The divergence ledger (docs/conformance.md): one '##' entry per documented
  # divergence. Its source ranges must span the heading of the entry they quote.
  LEDGER = 'docs/idea/parity-divergences.md'
  class Invalid < StandardError; end

  class Inventory
    attr_reader :cases

    def self.load(path, **)
      new(YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false), **)
    rescue Psych::Exception => e
      raise Invalid, e.message
    end

    def initialize(cases, root: ROOT)
      @cases = cases
      @root = root
      validate!
    end

    def covered = cases.select { |entry| entry.key?('oracles') }
    def pending = cases.reject { |entry| entry.key?('oracles') }

    # Bang contract: raises on the first missing oracle, true otherwise — a
    # gate, not a query, so the name keeps its bang despite the boolean return.
    def validate_references!(runnables = Minitest::Runnable.runnables) # rubocop:disable Naming/PredicateMethod
      # Not #runnable_methods: minitest >= 6 reseeds the global RNG from
      # Minitest.seed inside it, which is still nil at install/load time — and
      # run order is irrelevant here, only the runnable names.
      available = runnables.flat_map do |klass|
        klass.public_instance_methods(true).grep(/\Atest_/).map { |method| "#{klass.name}##{method}" }
      end
      covered.each do |entry|
        entry.fetch('oracles').each do |reference|
          raise Invalid, "#{entry['id']}: missing runnable oracle #{reference}" unless available.include?(reference)
        end
      end
      true
    end

    private

    def text?(value) = value.is_a?(String) && !value.strip.empty?

    def validate!
      raise Invalid, 'inventory must be a nonempty array' unless cases.is_a?(Array) && !cases.empty?

      ids = []
      work = []
      cases.each { |entry| validate_case!(entry, ids, work) }
    end

    def validate_case!(entry, ids, work)
      raise Invalid, 'case must be a mapping' unless entry.is_a?(Hash)

      %w[id area behavior source promise].each do |key|
        raise Invalid, "missing #{key}: #{entry.inspect}" unless text?(entry[key])
      end
      require_unique_id!(entry, ids)
      validate_promise!(entry)
      if entry.key?('oracles')
        validate_oracles!(entry)
      else
        validate_pending!(entry, work)
      end
    end

    def require_unique_id!(entry, ids)
      raise Invalid, "invalid id #{entry['id']}" unless entry['id'].match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/)
      raise Invalid, "duplicate id #{entry['id']}" if ids.include?(entry['id'])

      ids << entry['id']
    end

    def validate_pending!(entry, work)
      %w[reason future_work].each do |key|
        raise Invalid, "#{entry['id']}: missing pending #{key}" unless text?(entry[key])
      end
      raise Invalid, "duplicate future_work #{entry['future_work']}" if work.include?(entry['future_work'])

      work << entry['future_work']
    end

    def validate_oracles!(entry)
      refs = entry['oracles']
      valid = refs.is_a?(Array) && !refs.empty? && refs.uniq == refs && refs.all? do |ref|
        ref.is_a?(String) && ref.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*#test_\w+\z/)
      end
      raise Invalid, "#{entry['id']}: invalid oracles" unless valid
      return unless entry.key?('reason') || entry.key?('future_work')

      raise Invalid, "#{entry['id']}: covered case has pending fields"
    end

    def validate_source!(source)
      match = %r{\A(docs/[\w./-]+\.md)#L([1-9]\d*)(?:-L([1-9]\d*))?\z}.match(source)
      raise Invalid, "invalid source anchor #{source}" unless match

      path = File.expand_path(match[1], @root)
      raise Invalid, "source escapes docs: #{source}" unless path.start_with?("#{@root}/docs/")
      raise Invalid, "missing source #{source}" unless File.file?(path)

      lines = File.readlines(path)
      first = match[2].to_i
      last = (match[3] || match[2]).to_i
      range = lines[(first - 1)..(last - 1)]
      unless last.between?(first, lines.size) && range.any? { |line| !line.strip.empty? }
        raise Invalid, "absent source lines #{source}"
      end

      validate_boundary!(source, lines, first) if last > first

      range
    end

    # A multi-line quote must open where a reader could have started reading:
    # the file's first line, a heading, or a fresh paragraph. A mid-paragraph,
    # blank-line, mid-list, mid-table or code-fence-tail start anchors nothing.
    def validate_boundary!(source, lines, first)
      opening = lines[first - 1]
      return if first == 1 || opening.start_with?('#') ||
                (!opening.strip.empty? && lines[first - 2].strip.empty?)

      raise Invalid, "source range not at a heading or paragraph start #{source}"
    end

    def normalize_whitespace(value)
      value.lines.map(&:strip).reject(&:empty?).join(' ').squeeze(' ')
    end

    def validate_promise!(entry)
      range = validate_source!(entry['source'])
      promise = normalize_whitespace(entry['promise'])
      anchored = normalize_whitespace(range.join)
      raise Invalid, "#{entry['id']}: promise withdrawn from #{entry['source']}" unless anchored.include?(promise)

      validate_ledger_heading!(entry, range, promise)
    end

    # A ledger range quoting one entry's body must also span that entry's own
    # '##' heading, else the promise is presented under another entry's.
    def validate_ledger_heading!(entry, range, promise)
      doc = entry['source'].split('#').first
      return unless File.expand_path(doc, @root) == File.expand_path(LEDGER, @root)

      headed = range.each_with_index.any? do |line, index|
        line.start_with?('## ') && normalize_whitespace(range[index..].join).include?(promise)
      end
      raise Invalid, "ledger source range omits its entry heading: #{entry['source']}" unless headed
    end
  end

  # Full-retention stat reporter. minitest-parallel_fork marshals each worker's
  # [count, assertions, results] from the FIRST stat-shaped reporter, and
  # minitest >= 6 prunes passing results from its own stat reporters — first
  # here, so green oracles can cross the fork at all.
  class Transport < Minitest::AbstractReporter
    attr_writer :composite
    attr_reader :results
    attr_accessor :count, :assertions

    def initialize
      super
      @composite = nil
      @results = []
      @count = 0
      @assertions = 0
    end

    def record(result)
      @count += 1
      @assertions += result.assertions
      @results << result
    end

    # The fork gem concatenates the marshaled full-retention results into every
    # stat-shaped sibling — minitest's own Summary included — whose contract is
    # results = failures and skips only (minitest >= 6 reads Summary#passed?
    # off that array and lists its contents as failures). This reporter reports
    # first, so prune the passing results back out before the Summary speaks.
    def report
      return unless @composite

      @composite.reporters.each do |rep|
        next if rep.equal?(self)
        next unless rep.respond_to?(:results) && rep.results.is_a?(Array)

        rep.results.reject!(&:passed?)
      end
    end
  end

  # record runs in the parent, including results transported by parallel_fork.
  # No process-local after_run counters or worker-written shared files are needed.
  class Reporter < Minitest::AbstractReporter
    attr_reader :results

    def initialize(inventory, out: $stdout, transport: nil)
      super()
      @inventory = inventory
      @out = out
      @results = {}
      @skipped = {}
      @transport = transport
    end

    def record(result)
      reference = "#{result.klass}##{result.name}"
      successful = result.passed? && !result.skipped? && result.assertions.positive?
      results[reference] = results.fetch(reference, true) && successful
      @skipped[reference] = result.skipped?
    end

    # minitest-parallel_fork ships each worker's results from the transport
    # above and never calls #record in the parent of a forked run, so the
    # transported results are folded in here through the same record gate.
    # Only an empty ledger folds: serial runs and the workers themselves record
    # live through #record, and folding there would pollute the accounting.
    def fold_parallel_fork_results!
      return unless results.empty?

      @transport&.results&.each { |result| record(result) }
    end

    def totals
      fold_parallel_fork_results!
      passed = @inventory.covered.count do |entry|
        entry['oracles'].all? { |reference| results[reference] == true }
      end
      pending = @inventory.pending.count do |entry|
        @skipped["ConformancePendingTest#test_pending_#{entry['id'].tr('.-', '__')}"] == true
      end
      { passed: passed, pending: pending, failed: @inventory.cases.size - passed - pending }
    end

    def passed? = totals[:failed].zero?

    def report
      counts = totals
      @out.puts "Conformance: #{counts[:passed]} passed, #{counts[:pending]} pending, #{counts[:failed]} failed"
      @inventory.covered.each do |entry|
        missing = entry['oracles'].reject { |reference| results[reference] == true }
        @out.puts "  #{entry['id']}: unsuccessful or missing #{missing.join(', ')}" unless missing.empty?
      end
    end
  end

  def self.install(inventory)
    inventory.validate_references!
    pending_class = Class.new(Minitest::Test)
    Object.const_set(:ConformancePendingTest, pending_class)
    inventory.pending.each do |entry|
      pending_class.define_method("test_pending_#{entry['id'].tr('.-', '__')}") do
        skip "#{entry['id']}: #{entry['reason']} (#{entry['future_work']})"
      end
    end
    Minitest.extensions << 'conformance'
    Minitest.define_singleton_method(:plugin_conformance_init) do |options|
      transport = Transport.new
      # First: the fork gem marshals worker results from the first stat-shaped
      # reporter (see Transport).
      reporter.reporters.unshift(transport)
      transport.composite = reporter
      reporter << Reporter.new(inventory, out: options[:io] || $stdout, transport: transport)
    end
  end
end
