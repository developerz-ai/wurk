# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require 'yaml'

# Guards the maintainer policy contract this repo's own automation depends on.
#
# WHY: .dz/maintainer/maintainer.yml is consumed by a platform that lives
# outside this checkout, so nothing in the repo turns red when a guarded key
# is renamed, dropped, or handed a value the platform does not understand —
# the agent would fall back to a schema default and this repo's handoff lane,
# triage thresholds and merge gate would move without a red build. This file
# pins the contract in two layers that are deliberately kept apart:
#
#   1. SHAPE — every guarded path is present, carries the right type and
#      holds a value inside the vocabulary the policy documents. A missing
#      path is reported as MISSING; no schema default is ever substituted.
#   2. PIN — the repo's current values, asserted one by one. A deliberate
#      policy change updates the pin in this file in the same commit.
#
# The layers answer different questions, and the mutation cases at the bottom
# of this file keep them distinguishable: malformed input fails SHAPE, while a
# valid-but-different policy (another handoff mode, another threshold) passes
# SHAPE and fails only the PINs. That is what an intentional change looks
# like, and it must not be mistaken for corruption.
#
# Reads files only; touches no Redis, no network and no shared state.
class MaintainerPolicyContractTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  POLICY = File.join(ROOT, '.dz', 'maintainer', 'maintainer.yml')
  WORKFLOWS_DIR = File.join(ROOT, '.github', 'workflows')

  # Each guarded path, the type it must have, and the vocabulary its value
  # must come from. The service vocabulary is CLOSED: the policy documents
  # `redis` and `postgres`, and a key that names anything else is a policy
  # that would ask a box to start a process it was never cleared for.
  SHAPE_RULES = {
    'handoff.mode' => { type: String, values: %w[fleet webhook] },
    'handoff.ask_reporter_first' => { type: [TrueClass, FalseClass] },
    'triage.confidence_threshold' => { type: Numeric, range: (0.0..1.0) },
    'triage.qualify_into' => { type: Array, item_type: String, min_items: 1 },
    'pr.required_checks' => { type: Array, item_type: String, min_items: 1 },
    'escalate.ask_before_acting' => { type: Array, item_type: String, min_items: 0 },
    'services' => { type: Array, item_type: String, min_items: 1, item_values: %w[redis postgres] }
  }.freeze

  # The values this repo depends on today. An intentional policy change
  # updates the pin in this file in the same commit as the policy.
  PINS = {
    'handoff.mode' => 'fleet',
    'handoff.ask_reporter_first' => false,
    'triage.confidence_threshold' => 0.4,
    'triage.qualify_into' => %w[bug feature dupe question],
    'pr.required_checks' => [
      'test + coverage (latest ruby/rails)',
      'lint (rubocop)',
      'parity (oracle)',
      'spec docs (exist + non-empty)',
      'frontend (vitest)',
      'actionlint (workflow lint)'
    ],
    'escalate.ask_before_acting' => [],
    'services' => ['redis']
  }.freeze

  # The tail of every pin failure: a failing pin is a deliberate change, and
  # the deliberate change has to land together with the pin.
  PIN_CHANGE_HINT = 'an intentional policy change updates the pin in this file in the same commit'

  TYPE_NAMES = {
    String => 'a String',
    TrueClass => 'true or false',
    FalseClass => 'true or false',
    Numeric => 'a Number',
    Array => 'a list'
  }.freeze

  def setup
    @policy = YAML.safe_load_file(POLICY, permitted_classes: [Date, Time], aliases: true)
  end

  def test_the_policy_carries_every_guarded_path_with_the_documented_shape
    violations = shape_violations(@policy)

    assert_empty violations,
                 "the maintainer policy must satisfy the shape contract: #{violations.join('; ')}"
  end

  def test_the_policy_keeps_the_values_this_repo_depends_on
    violations = pin_violations(@policy)

    assert_empty violations,
                 "the maintainer policy must keep its pinned values: #{violations.values.join('; ')}"
  end

  def test_every_required_check_is_the_name_of_a_workflow_job
    jobs = workflow_jobs_by_name

    PINS.fetch('pr.required_checks').each do |check|
      assert_includes jobs.keys, check,
                      "#{check.inspect} must be the name of a job in .github/workflows/*.yml " \
                      "(jobs found: #{jobs.keys.sort.join(', ')})"
    end
  end

  def test_the_shape_layer_rejects_a_misspelled_key
    mutated = deep_copy(@policy)
    mutated['handoff']['ask_reporter_firts'] = mutated['handoff'].delete('ask_reporter_first')

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the misspelling must be the only violation: #{violations.inspect}"
    assert_match(/handoff\.ask_reporter_first/, violations.first)
    assert_match(/missing/, violations.first)
    assert_match(/ask_reporter_firts/, violations.first)
  end

  def test_the_shape_layer_rejects_a_missing_key
    mutated = deep_copy(@policy)
    mutated['escalate'].delete('ask_before_acting')

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the dropped key must be the only violation: #{violations.inspect}"
    assert_match(/escalate\.ask_before_acting/, violations.first)
    assert_match(/missing/, violations.first)
    assert_match(/no schema default/, violations.first)
  end

  def test_the_shape_layer_rejects_a_wrong_shape
    mutated = deep_copy(@policy)
    mutated['services'] = 'redis'

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the wrong shape must be the only violation: #{violations.inspect}"
    assert_match(/\Aservices\b/, violations.first)
    assert_match(/must be a list/, violations.first)
  end

  def test_the_shape_layer_rejects_values_outside_the_documented_vocabulary
    mutated = deep_copy(@policy)
    mutated['handoff']['mode'] = 'slack'
    mutated['services'] = ['mysql']

    violations = shape_violations(mutated)

    assert_equal 2, violations.size,
                 "both out-of-vocabulary values must be reported: #{violations.inspect}"

    report = violations.join("\n")

    assert_match(/handoff\.mode.*slack/, report)
    assert_match(/services\[0\].*mysql/, report)
  end

  # The policy on disk satisfies every shape rule, so nothing but a case that
  # hands the guard a value the rule must reject can catch that rule being
  # deleted: without these, a rule that stops firing leaves the suite green.
  def test_the_shape_layer_rejects_a_threshold_outside_the_documented_range
    mutated = deep_copy(@policy)
    mutated['triage']['confidence_threshold'] = 1.5

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the out-of-range threshold must be the only violation: #{violations.inspect}"
    assert_match(/triage\.confidence_threshold/, violations.first)
    assert_match(/must be between 0\.0 and 1\.0/, violations.first)
  end

  def test_the_shape_layer_rejects_an_empty_list
    mutated = deep_copy(@policy)
    mutated['triage']['qualify_into'] = []

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the empty list must be the only violation: #{violations.inspect}"
    assert_match(/triage\.qualify_into/, violations.first)
    assert_match(/must not be empty/, violations.first)
  end

  def test_the_shape_layer_rejects_a_non_string_list_item
    mutated = deep_copy(@policy)
    mutated['triage']['qualify_into'] = ['bug', 42]

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the non-String item must be the only violation: #{violations.inspect}"
    assert_match(/triage\.qualify_into\[1\]/, violations.first)
    assert_match(/must be a String/, violations.first)
  end

  def test_the_shape_layer_rejects_an_empty_string_list_item
    mutated = deep_copy(@policy)
    mutated['pr']['required_checks'] = ['lint (rubocop)', '']

    violations = shape_violations(mutated)

    assert_equal 1, violations.size,
                 "the empty String must be the only violation: #{violations.inspect}"
    assert_match(/pr\.required_checks\[1\]/, violations.first)
    assert_match(/must not be an empty String/, violations.first)
  end

  # A block that is gone is not a block with a bad value: every path under it
  # is missing, and the guard has to walk past the absent parent rather than
  # raise on it.
  def test_the_shape_layer_reports_every_path_of_a_deleted_block_as_missing
    mutated = deep_copy(@policy)
    mutated.delete('handoff')

    violations = shape_violations(mutated)

    assert_equal 2, violations.size,
                 "both handoff paths must be reported missing: #{violations.inspect}"

    report = violations.join("\n")

    assert_match(/handoff\.mode is missing/, report)
    assert_match(/handoff\.ask_reporter_first is missing/, report)
  end

  def test_a_valid_but_different_policy_passes_shape_and_fails_only_the_pins
    mutated = deep_copy(@policy)
    mutated['handoff']['mode'] = 'webhook'
    mutated['triage']['confidence_threshold'] = 0.6

    shape_failures = shape_violations(mutated)
    pin_failures = pin_violations(mutated)

    assert_empty shape_failures,
                 'a valid policy with different values must pass the shape layer: ' \
                 "#{shape_failures.join('; ')}"
    assert_equal ['handoff.mode', 'triage.confidence_threshold'], pin_failures.keys.sort,
                 'an intentional change must fail exactly the pins it touches'
  end

  private

  # SHAPE: every guarded path present, correctly typed, inside its vocabulary.
  def shape_violations(policy)
    SHAPE_RULES.each_with_object([]) do |(path, rule), violations|
      value = fetch_path(policy, path)

      if value.nil?
        violations << missing_message(policy, path)
        next
      end

      violations.concat(type_violations(path, value, rule))
    end
  end

  # PIN: the repo's current values, one by one.
  def pin_violations(policy)
    PINS.each_with_object({}) do |(path, expected), violations|
      actual = fetch_path(policy, path)
      next if actual == expected

      violations[path] = "#{path} is pinned to #{expected.inspect}, got #{actual.inspect}; #{PIN_CHANGE_HINT}"
    end
  end

  def type_violations(path, value, rule)
    violations = []

    unless type_matches?(value, rule[:type])
      violations << "#{path} must be #{type_name(rule[:type])}, got #{value.inspect}"

      return violations
    end

    if rule[:values] && !rule[:values].include?(value)
      violations << "#{path} must be one of #{rule[:values].join(' / ')}, got #{value.inspect}"
    end

    if rule[:range] && !rule[:range].cover?(value)
      range = rule[:range]

      violations << "#{path} must be between #{range.min} and #{range.max}, got #{value.inspect}"
    end

    violations.concat(array_violations(path, value, rule)) if value.is_a?(Array)

    violations
  end

  def array_violations(path, value, rule)
    violations = []

    violations << "#{path} must not be empty" if value.size < rule.fetch(:min_items, 0)

    value.each_with_index do |item, index|
      if rule[:item_type] && !item.is_a?(rule[:item_type])
        violations << "#{path}[#{index}] must be a #{rule[:item_type]}, got #{item.inspect}"
      elsif item.is_a?(String) && item.empty?
        violations << "#{path}[#{index}] must not be an empty String"
      else
        violations.concat(vocabulary_violations(path, index, item, rule))
      end
    end

    violations
  end

  def vocabulary_violations(path, index, item, rule)
    vocabulary = rule[:item_values]
    return [] unless vocabulary
    return [] if vocabulary.include?(item)

    ["#{path}[#{index}] (#{item.inspect}) is outside the closed vocabulary " \
     "(#{vocabulary.join(' / ')})"]
  end

  def type_name(type)
    Array(type).map { |klass| TYPE_NAMES.fetch(klass, klass.name) }.uniq.join(' or ')
  end

  # `is_a?` takes one class, so a rule may name several.
  def type_matches?(value, type)
    Array(type).any? { |klass| value.is_a?(klass) }
  end

  # A missing path is reported as missing, and never as the schema default the
  # platform would silently substitute for it.
  def missing_message(policy, path)
    suggestion = near_miss(policy, path)
    hint = suggestion ? " (did you mean #{suggestion.inspect}?)" : ''

    "#{path} is missing from the policy#{hint}; no schema default is substituted for it"
  end

  # The sibling key a typo most likely meant, so a misspelling is diagnosed
  # instead of merely reported as absent.
  def near_miss(policy, path)
    segments = path.split('.')
    parent = segments[0...-1].reduce(policy) do |node, segment|
      return nil unless node.is_a?(Hash)

      node[segment]
    end
    return nil unless parent.is_a?(Hash)

    expected = segments.last
    key = parent.keys.find { |candidate| candidate.is_a?(String) && edit_distance(candidate, expected) <= 2 }
    return nil unless key

    (segments[0...-1] + [key]).join('.')
  end

  def edit_distance(left, right)
    previous = (0..right.length).to_a

    left.each_char.with_index do |left_char, index|
      current = [index + 1]

      right.each_char.with_index do |right_char, position|
        current << [current[position] + 1,
                    previous[position + 1] + 1,
                    previous[position] + (left_char == right_char ? 0 : 1)].min
      end

      previous = current
    end

    previous.last
  end

  def fetch_path(policy, path)
    path.split('.').reduce(policy) do |node, segment|
      return nil unless node.is_a?(Hash)

      node[segment]
    end
  end

  # Every job name declared under `jobs:` in .github/workflows/*.yml, mapped to
  # the workflow files that declare it.
  def workflow_jobs_by_name
    Dir[File.join(WORKFLOWS_DIR, '*.yml')].each_with_object({}) do |path, jobs|
      workflow = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: true)
      definitions = workflow.is_a?(Hash) ? workflow['jobs'] : nil
      next unless definitions.is_a?(Hash)

      definitions.each_value do |definition|
        name = definition.is_a?(Hash) ? definition['name'] : nil
        next unless name.is_a?(String)

        (jobs[name] ||= []) << File.basename(path)
      end
    end
  end

  # A copy the mutation cases can change without touching the real policy.
  def deep_copy(value)
    case value
    when Hash then value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
    when Array then value.map { |item| deep_copy(item) }
    else value
    end
  end
end
