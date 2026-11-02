# frozen_string_literal: true

require_relative '../test_helper'
require 'yaml'

# The manifests under examples/kubernetes are what people paste into production,
# so a renamed metric or a wrong port must fail here and not in somebody's pager.
class ExamplesKubernetesTest < Wurk::Test::UnitCase
  parallelize_me!

  DIR = File.expand_path('../../examples/kubernetes', __dir__)
  RULES = File.join(DIR, 'prometheus-rule.yaml')
  WORKERS = %w[worker-deployment.yaml worker-recreate.yaml].freeze
  METRIC = /\bwurk_[a-z_]+\b/

  def test_every_metric_the_rules_use_exists_in_the_exporter
    used = rules.flat_map { |rule| rule.fetch('expr').scan(METRIC) }.uniq
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    exposed = Wurk::Metrics::Prometheus.new(config).render(expected_children: 1).scan(/^# TYPE (\w+)/).flatten

    assert_operator used.size, :>=, 8
    assert_empty used - exposed, "not exported: #{(used - exposed).inspect}"
  end

  def test_the_exporter_going_away_has_an_alert_of_its_own
    assert(rules.any? { |rule| rule.fetch('expr').start_with?('absent(') },
           'alerts on series that stopped existing never fire without an absent() arm')
  end

  def test_every_rule_can_route
    rules.each do |rule|
      assert_kind_of String, rule['alert']
      assert_includes rule.keys, 'for', rule['alert']
      assert_includes %w[critical warning info], rule.dig('labels', 'severity'), rule['alert']
      assert_kind_of String, rule.dig('annotations', 'summary'), rule['alert']
    end
  end

  # Grace budget from docs/deployment.md, read from the manifest's own numbers.
  def test_worker_grace_covers_prestop_shutdown_and_the_swarm_grace
    WORKERS.each do |file|
      pod = worker(file).dig('spec', 'template', 'spec')
      container = pod['containers'].first
      flag = container['command'].index('-t')
      shutdown = flag ? Integer(container['command'][flag + 1]) : 25
      budget = 5 + shutdown + Wurk::Swarm::SHUTDOWN_GRACE

      assert_operator pod['terminationGracePeriodSeconds'], :>, budget, file
    end
  end

  def test_workers_open_the_listener_their_probes_and_the_service_monitor_expect
    documents = YAML.load_stream(File.read(File.join(DIR, 'service-monitor.yaml')))
    endpoint = documents.find { |doc| doc['kind'] == 'ServiceMonitor' }.dig('spec', 'endpoints', 0)

    assert_equal '/metrics', endpoint['path']
    WORKERS.each do |file|
      container = worker(file).dig('spec', 'template', 'spec', 'containers', 0)
      env = container['env'].to_h { |entry| [entry['name'], entry['value']] }

      assert_equal '7433', env['WURK_HEALTH_PORT'], file
      assert_equal 7433, container['ports'].find { |port| port['name'] == endpoint['port'] }['containerPort']
      assert_equal '/live', container.dig('livenessProbe', 'httpGet', 'path')
      assert_equal '/ready', container.dig('readinessProbe', 'httpGet', 'path')
    end
  end

  def test_the_recreate_variant_is_what_it_says
    assert_equal 'Recreate', worker('worker-recreate.yaml').dig('spec', 'strategy', 'type')
  end

  private

  def rules
    YAML.safe_load_file(RULES).dig('spec', 'groups').flat_map { |group| group['rules'] }
  end

  def worker(file)
    YAML.safe_load_file(File.join(DIR, file))
  end
end
