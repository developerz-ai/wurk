# frozen_string_literal: true

require 'yaml'
require 'minitest'

module Conformance
  ROOT = File.expand_path('../..', __dir__)
  # The divergence ledger (docs/conformance.md): one '##' entry per documented
  # divergence. Its source ranges must span the heading of the entry they quote.
  LEDGER = 'docs/idea/parity-divergences.md'
  class Invalid < StandardError; end

  ORACLE_CLASS_EXEMPTIONS = {
    'IterableJobStateParityTest' => 'State-schema oracle not yet mapped to behavior cases.'
  }.freeze

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
      require_registered_oracle_classes!(runnables)
      true
    end

    private

    def require_registered_oracle_classes!(runnables)
      registered = covered.flat_map { |entry| entry.fetch('oracles') }.map { |reference| reference.split('#').first }
      uncited = runnables.select { |klass| parity_oracle?(klass) }.map(&:name).uniq -
                registered - ORACLE_CLASS_EXEMPTIONS.keys
      return if uncited.empty?

      raise Invalid, "unregistered parity oracle classes: #{uncited.sort.join(', ')}; " \
                     'register each class in a cases.yml oracles entry or add its class name with a reason to ' \
                     'Conformance::ORACLE_CLASS_EXEMPTIONS'
    end

    def parity_oracle?(klass)
      return false unless klass.name && klass < Minitest::Runnable
      return false unless klass.public_instance_methods(true).any? { |method| method.to_s.start_with?('test_') }

      # Method locations would misclassify helpers or reopened unit classes;
      # the constant's definition identifies the suite that owns the oracle.
      location = Object.const_source_location(klass.name)&.first
      location && File.expand_path(location).start_with?(File.join(@root, 'test/parity/'))
    end

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

  # Ledger-anchor gate: every line-bearing anchor in a divergence entry's
  # **Anchor:** paragraph must be pinned by a record in
  # test/conformance/ledger_anchors/*.yml quoting a fragment that still
  # appears, whitespace-normalized, at exactly those lines; path-only anchors
  # are existence-checked straight from the ledger. When the anchored code
  # moves, the ledger's path:line and the record's fragment move together — a
  # record quoting whatever now sits at the old lines is the exact drift this
  # gate exists to reject (docs/conformance.md, "Pin the ledger anchors").
  class Ledger
    Record = Struct.new(:file, :entry, :anchor, :fragment)
    Entry = Struct.new(:heading, :paragraph)
    Anchor = Struct.new(:path, :from, :to) do
      def line_bearing? = !from.nil?

      def canonical
        return path unless line_bearing?

        to > from ? "#{path}#L#{from}-L#{to}" : "#{path}#L#{from}"
      end
    end

    RECORD_KEYS = %w[entry anchor fragment].freeze
    PATH_SPAN = %r{\A[\w./-]+\z}
    # `path:56-59,81-89` — one backtick span, one anchor per comma range.
    PATH_WITH_RANGES = %r{\A(?<path>[\w./-]+):(?<ranges>\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\z}
    # Backticked spans and inline links share one scan so a span inside a link
    # label is consumed by the link, never re-read as a path.
    SPAN_OR_LINK = /`([^`]+)`|\[[^\]]*\]\(([^)\s]+)\)/
    LINE_FRAGMENT = /\AL(?<first>[1-9]\d*)(?:-L(?<last>[1-9]\d*))?\z/

    attr_reader :records

    def self.load(ledger:, dir:, root: ROOT)
      path = File.expand_path(ledger, root)
      new(File.read(path), File.expand_path(dir, root), ledger_path: path, root: root)
    end

    def initialize(text, dir, ledger_path:, root: ROOT)
      @text = text
      @dir = dir
      @root = root
      @records_glob = File.join(@dir, '*.yml')
      @link_base = File.dirname(ledger_path)
      @records = load_records
    end

    # Bang contract as in Inventory: raises on the first unpinned or unquotable
    # anchor, true otherwise — a gate, not a query.
    def validate! # rubocop:disable Naming/PredicateMethod
      by_entry = records.group_by(&:entry)
      validate_record_entries!(by_entry)
      entries.each do |heading, paragraph|
        raise Invalid, "#{heading}: entry has no **Anchor:** paragraph" unless paragraph

        pinned = []
        anchors(heading, paragraph).each do |anchor|
          if anchor.line_bearing?
            validate_line_anchor!(heading, anchor, by_entry[heading])
            pinned << anchor.canonical
          else
            validate_path_anchor!(heading, anchor)
          end
        end
        validate_entry_records!(heading, by_entry[heading], pinned)
      end
      true
    end

    private

    # One '##' entry per heading. Its **Anchor:** paragraph is that line until
    # the next blank line — nothing else in the entry is in scope, and '###'
    # blocks are body prose, not entries.
    def entries
      @entries ||= scan_entries
    end

    def scan_entries
      found = []
      entry = nil
      collecting = false
      @text.each_line do |line|
        if line.start_with?('## ')
          found << close_entry(entry) if entry
          entry = Entry.new(line[3..].strip)
          collecting = false
        elsif entry && collecting
          collecting = absorb_anchor_line(entry, line)
        elsif entry&.paragraph.nil? && line.start_with?('**Anchor:**')
          entry.paragraph = [line]
          collecting = true
        end
      end
      found << close_entry(entry) if entry
      found
    end

    def close_entry(entry)
      [entry.heading, entry.paragraph&.join]
    end

    # Returns the still-open paragraph, or nil once a blank line closes it —
    # a state, not a boolean, so the name carries no `?`.
    def absorb_anchor_line(entry, line)
      return if line.strip.empty?

      entry.paragraph << line
    end

    def anchors(heading, paragraph)
      list = []
      paragraph.scan(SPAN_OR_LINK) do |span, target|
        list.concat(span ? span_anchors(heading, span) : link_anchors(heading, target))
      end
      list
    end

    def span_anchors(heading, span)
      ranges = PATH_WITH_RANGES.match(span)
      return ranges[:ranges].split(',').map { |range| line_anchor(heading, ranges[:path], range) } if ranges
      return [build_anchor(heading, span, nil, nil)] if path_span?(span)

      []
    end

    # Branch names (`fix/shutdown-requeue`) ride the same backticks as file
    # paths; a real repo path carries a file extension or sits under an
    # existing top-level directory. Both markers are required alongside the
    # directory separator.
    def path_span?(span)
      return false unless span.match?(PATH_SPAN) && span.include?('/')

      span.include?('.') || File.directory?(File.join(@root, span.split('/').first))
    end

    def line_anchor(heading, path, range)
      first, last = range.split('-')
      build_anchor(heading, path, first.to_i, (last || first).to_i)
    end

    def link_anchors(heading, target)
      return [] if target.match?(/\A[a-z][a-z0-9+.-]*:/i) || target.start_with?('#', '//')

      file, fragment = target.split('#', 2)
      resolved = File.expand_path(file, @link_base)
      unless resolved.start_with?("#{@root}/")
        raise Invalid, "#{heading}: link anchor escapes the repository: #{target}"
      end

      path = resolved.delete_prefix("#{@root}/")
      match = LINE_FRAGMENT.match(fragment.to_s)
      return [build_anchor(heading, path, nil, nil)] unless match

      [build_anchor(heading, path, match[:first].to_i, (match[:last] || match[:first]).to_i)]
    end

    def build_anchor(heading, path, first, last)
      raise Invalid, "#{heading}: anchor path must be repo-relative: #{path}" if path.start_with?('/')
      raise Invalid, "#{heading}: anchor path escapes the repository: #{path}" if path.split('/').include?('..')
      raise Invalid, "#{heading}: anchor range descends: #{path}#L#{first}-L#{last}" if first && last < first
      raise Invalid, "#{heading}: anchor range starts at line zero: #{path}#L#{first}-L#{last}" if first && first < 1

      Anchor.new(path, first, last)
    end

    def validate_line_anchor!(heading, anchor, candidates)
      # nil group = no record names this entry: the same missing-pin as an
      # empty one, while validate_entry_records! keeps nil as the valid
      # path-only shape.
      pinned = (candidates || []).select { |record| record.anchor == anchor.canonical }
      if pinned.empty?
        raise Invalid, "#{heading}: line-bearing anchor #{anchor.canonical} has no record in #{@records_glob}"
      end

      record = pinned.first
      path = File.expand_path(anchor.path, @root)
      unless File.file?(path)
        raise Invalid, "#{heading}: anchor #{anchor.canonical}: missing target file #{anchor.path} (#{record.file})"
      end

      lines = File.readlines(path)
      if anchor.to > lines.size
        raise Invalid, "#{heading}: anchor #{anchor.canonical}: range past end of #{anchor.path} " \
                       "(#{lines.size} lines) — the code moved; re-pin the anchor and fragment (#{record.file})"
      end

      anchored = normalize_whitespace(lines[(anchor.from - 1)..(anchor.to - 1)].join)
      return if anchored.include?(normalize_whitespace(record.fragment))

      raise Invalid, "#{heading}: anchor #{anchor.canonical}: fragment not found at the anchored lines " \
                     "(#{record.file})"
    end

    def validate_path_anchor!(heading, anchor)
      return if File.file?(File.expand_path(anchor.path, @root))

      raise Invalid, "#{heading}: path-only anchor #{anchor.path}: missing target file"
    end

    def validate_entry_records!(heading, entry_records, pinned)
      # An entry whose anchors are all path-only pins nothing and ships no
      # records: by_entry carries no key for it, and that is the valid shape.
      return if entry_records.nil?

      entry_records.each do |record|
        next if pinned.include?(record.anchor)

        raise Invalid, "#{record.file}: record anchor #{record.anchor.inspect} does not pin a line-bearing " \
                       "anchor of the entry #{heading.inspect}"
      end
      entry_records.group_by(&:anchor).each do |anchor, group|
        next unless group.size > 1

        raise Invalid, "#{heading}: anchor #{anchor} pinned #{group.size} times " \
                       "(#{group.map(&:file).uniq.sort.join(', ')})"
      end
    end

    def validate_record_entries!(by_entry)
      unknown = by_entry.keys - entries.map(&:first)
      return if unknown.empty?

      record = by_entry[unknown.first].first
      raise Invalid, "#{record.file}: record names unknown ledger entry #{unknown.first.inspect}"
    end

    def load_records
      Dir[@records_glob].flat_map do |file|
        begin
          data = YAML.safe_load_file(file, permitted_classes: [], permitted_symbols: [], aliases: false)
        rescue Psych::Exception => e
          raise Invalid, "#{file}: #{e.message}"
        end
        raise Invalid, "#{file}: anchor records must be an array" unless data.is_a?(Array)

        data.map { |raw| build_record(file, raw) }
      end
    end

    def build_record(file, raw)
      raise Invalid, "#{file}: record must be a mapping: #{raw.inspect}" unless raw.is_a?(Hash)
      unless raw.keys.sort == RECORD_KEYS.sort
        raise Invalid, "#{file}: record keys must be exactly #{RECORD_KEYS.join('/')} — got #{raw.keys.inspect}"
      end

      entry, anchor, fragment = raw.values_at(*RECORD_KEYS)
      if [entry, anchor, fragment].any? { |value| !value.is_a?(String) || value.strip.empty? }
        raise Invalid, "#{file}: entry, anchor and fragment must be nonempty strings"
      end

      Record.new(file, entry, anchor, fragment)
    end

    # Same normalization as the Inventory promise check, which stays private
    # to it — the rule is shared, the implementation deliberately duplicated.
    def normalize_whitespace(value)
      value.lines.map(&:strip).reject(&:empty?).join(' ').squeeze(' ')
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
