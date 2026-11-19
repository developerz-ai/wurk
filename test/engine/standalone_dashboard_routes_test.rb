# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'wurk/web/dashboard/routes'

# The standalone mount (Wurk::Web::Dashboard::Routes) serves the dashboard's
# JSON API and profile routes without Rails. Its table must stay the engine's:
# a route drawn in config/routes.rb and missing here works under
# `mount Wurk::Engine` and 404s under `run Sidekiq::Web`.
class StandaloneDashboardRoutesTest < Wurk::Test::EngineCase
  def test_the_standalone_table_is_the_engines_api_and_profile_routes
    engine = ::Wurk::Engine.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next unless %w[wurk/api wurk/profiles].include?(controller)

      [route.verb, route.path.spec.to_s.delete_suffix('(.:format)'), route.defaults[:action].to_sym]
    end
    standalone = ::Wurk::Web::Dashboard::Routes::TABLE.map do |verb, segments, _endpoint, action|
      [verb, "/#{segments.join('/')}", action]
    end

    assert_equal engine.sort, standalone.sort
  end
end
