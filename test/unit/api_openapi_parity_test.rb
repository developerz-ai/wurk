# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'wurk'
require 'wurk/api/app'

# Plan 101 slice 10 A1: docs/api/openapi.yaml and the routers in lib/wurk/api/
# describe the same surface. A route drawn without a spec entry, a spec entry
# with no route, or a scope that differs between the two fails here.
class ApiOpenapiParityTest < Minitest::Test
  parallelize_me!

  SPEC_PATH = File.expand_path('../../docs/api/openapi.yaml', __dir__)
  VERBS = %w[get post put patch delete].freeze

  def spec = @spec ||= YAML.safe_load_file(SPEC_PATH, aliases: false)

  # [VERB, '/jobs/:jid', scope] per operation; `{jid}` read back as `:jid`, an
  # empty security requirement as Auth::ANY.
  def spec_routes
    spec.fetch('paths').flat_map do |path, item|
      pattern = path.gsub(/\{(\w+)\}/, ':\1')
      item.slice(*VERBS).map { |verb, operation| [verb.upcase, pattern, scope_of(path, verb, operation)] }
    end
  end

  def scope_of(path, verb, operation)
    requirements = operation.fetch('security') { flunk("#{verb.upcase} #{path} declares no security") }
    scopes = requirements.flat_map { |requirement| requirement.fetch('bearer') }

    assert_operator scopes.size, :<=, 1, "#{verb.upcase} #{path} names more than one scope"
    scopes.empty? ? Wurk::API::Auth::ANY : scopes.first.to_sym
  end

  def app_routes = Wurk::API::App.new.routes

  def test_every_drawn_route_is_in_the_spec_with_its_scope
    missing = app_routes - spec_routes

    assert_empty missing, "routes drawn in lib/wurk/api/ but absent from (or scoped differently in) #{SPEC_PATH}"
  end

  def test_every_spec_operation_is_a_drawn_route_with_its_scope
    extra = spec_routes - app_routes

    assert_empty extra, "operations in #{SPEC_PATH} that no router draws (or draws with another scope)"
  end

  def test_a_route_removed_from_a_router_table_fails_the_check
    router = Wurk::API::Router.new
    Wurk::API::Queues::TABLE.reject { |_verb, pattern, *| pattern == '/stats' }.each do |verb, pattern, scope, _|
      router.public_send(verb, pattern, scope: scope) { nil }
    end

    refute_includes router.routes, ['GET', '/stats', :read]
    assert_includes spec_routes, ['GET', '/stats', :read]
  end

  def test_every_path_parameter_is_declared
    spec.fetch('paths').each do |path, item|
      declared = (item['parameters'] || []) + item.slice(*VERBS).values.flat_map { |op| op['parameters'] || [] }
      names = declared.map { |param| resolve(param) }.select { |param| param['in'] == 'path' }.map { |p| p['name'] }

      assert_equal path.scan(/\{(\w+)\}/).flatten.sort, names.sort, "path parameters of #{path}"
    end
  end

  def test_problem_types_match_the_slugs_the_api_renders
    slugs = Wurk::API::Problem.constants.map { |name| Wurk::API::Problem.const_get(name) }
                              .select { |value| value.is_a?(String) && value.match?(/\A[a-z_]+\z/) }
    documented = spec.dig('components', 'schemas', 'Problem', 'properties', 'type', 'enum')

    assert_equal slugs.sort, documented.sort
  end

  def test_every_reference_resolves
    refs = []
    walk(spec) { |ref| refs << ref }

    refs.uniq.each { |ref| refute_nil dig_ref(ref), "unresolved #{ref}" }
  end

  private

  def resolve(node) = node.key?('$ref') ? dig_ref(node['$ref']) : node

  def dig_ref(ref) = spec.dig(*ref.delete_prefix('#/').split('/'))

  def walk(node, &block)
    case node
    when Hash
      yield node['$ref'] if node['$ref']
      node.each_value { |value| walk(value, &block) }
    when Array then node.each { |value| walk(value, &block) }
    end
  end
end
