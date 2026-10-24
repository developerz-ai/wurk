# frozen_string_literal: true

require 'yaml'
require 'minitest'

module Conformance
  ROOT = File.expand_path('../..', __dir__)
  class Invalid < StandardError; end

  class Inventory
    attr_reader :cases

    def self.load(path, **options)
      new(YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false), **options)
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

    def validate_references!(runnables = Minitest::Runnable.runnables)
      available = runnables.flat_map do |klass|
        klass.runnable_methods.map { |method| "#{klass.name}##{method}" }
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
      cases.each do |entry|
        raise Invalid, 'case must be a mapping' unless entry.is_a?(Hash)

        %w[id area behavior source].each do |key|
          raise Invalid, "missing #{key}: #{entry.inspect}" unless text?(entry[key])
        end
        raise Invalid, "invalid id #{entry['id']}" unless entry['id'].match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/)
        raise Invalid, "duplicate id #{entry['id']}" if ids.include?(entry['id'])

        ids << entry['id']
        validate_source!(entry['source'])
        if entry.key?('oracles')
          validate_oracles!(entry)
        else
          %w[reason future_work].each do |key|
            raise Invalid, "#{entry['id']}: missing pending #{key}" unless text?(entry[key])
          end
          raise Invalid, "duplicate future_work #{entry['future_work']}" if work.include?(entry['future_work'])

          work << entry['future_work']
        end
      end
    end

    def validate_oracles!(entry)
      refs = entry['oracles']
      valid = refs.is_a?(Array) && !refs.empty? && refs.uniq == refs && refs.all? do |ref|
        ref.is_a?(String) && ref.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*#test_\w+\z/)
      end
      raise Invalid, "#{entry['id']}: invalid oracles" unless valid
      raise Invalid, "#{entry['id']}: covered case has pending fields" if entry.key?('reason') || entry.key?('future_work')
    end

    def validate_source!(source)
      match = /\A(docs\/[\w.\/-]+\.md)#L([1-9]\d*)(?:-L([1-9]\d*))?\z/.match(source)
      raise Invalid, "invalid source anchor #{source}" unless match

      path = File.expand_path(match[1], @root)
      raise Invalid, "source escapes docs: #{source}" unless path.start_with?("#{@root}/docs/")
      raise Invalid, "missing source #{source}" unless File.file?(path)

      lines = File.readlines(path)
      first = match[2].to_i
      last = (match[3] || match[2]).to_i
      return if first <= last && last <= lines.size && lines[(first - 1)..(last - 1)].any? { |line| !line.strip.empty? }

      raise Invalid, "absent source lines #{source}"
    end
  end

  # record runs in the parent, including results transported by parallel_fork.
  # No process-local after_run counters or worker-written shared files are needed.
  class Reporter < Minitest::AbstractReporter
    attr_reader :results

    def initialize(inventory, io: $stdout)
      super()
      @inventory = inventory
      @io = io
      @results = {}
      @skipped = {}
    end

    def record(result)
      reference = "#{result.klass}##{result.name}"
      successful = result.passed? && !result.skipped? && result.assertions.positive?
      results[reference] = results.fetch(reference, true) && successful
      @skipped[reference] = result.skipped?
    end

    def totals
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
      @io.puts "Conformance: #{counts[:passed]} passed, #{counts[:pending]} pending, #{counts[:failed]} failed"
      @inventory.covered.each do |entry|
        missing = entry['oracles'].reject { |reference| results[reference] == true }
        @io.puts "  #{entry['id']}: unsuccessful or missing #{missing.join(', ')}" unless missing.empty?
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
      reporter << Reporter.new(inventory, io: options[:io] || $stdout)
    end
  end
end
