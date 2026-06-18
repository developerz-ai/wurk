# frozen_string_literal: true

require_relative '../test_helper'
require 'yard'

# Doc-coverage gate for #256: the public API surface the drop-in contract
# guarantees must stay documented. Parses lib/ with YARD and asserts the
# enumerated classes carry a class-level docstring and the DSL entry points
# carry runnable @example tags. This is the CI-checked half of the YARD work —
# a regression (someone adds a public enqueue path or strips a class overview)
# fails the suite instead of silently shipping undocumented API.
#
# Scoped to the public surface on purpose: a global "% documented" number would
# be dominated by internal/private methods and is not what the contract is about.
class YardPublicApiTest < Minitest::Test
  # Parse once for the whole class — YARD's registry is process-global, and
  # minitest-parallel_fork gives each worker its own process, so this is safe.
  def self.registry
    @registry ||= begin
      root = File.expand_path('../..', __dir__)
      YARD::Registry.clear
      YARD.parse(Dir[File.join(root, 'lib', '**', '*.rb')])
      YARD::Registry
    end
  end

  # Class/module overviews the layer-ownership + alias contract depend on.
  DOCUMENTED_TYPES = %w[
    Wurk
    Wurk::Worker
    Wurk::Worker::ClassMethods
    Wurk::Job
    Wurk::Client
    Wurk::Configuration
    Wurk::Batch
    Wurk::Limiter
    Wurk::Unique
    Sidekiq
  ].freeze

  # DSL entry points the issue says to lean on @example for.
  EXAMPLED_OBJECTS = %w[
    Wurk::Worker
    Wurk::Worker::ClassMethods#perform_async
    Wurk::Worker::ClassMethods#perform_in
    Wurk::Worker::ClassMethods#perform_bulk
    Wurk::Worker::ClassMethods#set
    Wurk::Worker::ClassMethods#sidekiq_options
    Wurk::Configuration#periodic
    Wurk::Batch
    Wurk::Limiter
    Wurk::Unique
  ].freeze

  def test_public_types_carry_class_level_docs
    undocumented = DOCUMENTED_TYPES.reject do |name|
      obj = self.class.registry.at(name)
      obj && obj.docstring.to_s.strip.length >= 20
    end

    assert_empty undocumented,
                 "public API types missing a class/module overview: #{undocumented.join(', ')}"
  end

  def test_dsl_entry_points_have_examples
    missing = EXAMPLED_OBJECTS.reject do |name|
      obj = self.class.registry.at(name)
      obj && !obj.tags(:example).empty?
    end

    assert_empty missing, "public DSL entry points missing an @example: #{missing.join(', ')}"
  end

  def test_client_enqueue_methods_document_params_and_return
    %w[Wurk::Client#push Wurk::Client#push_bulk].each do |name|
      obj = self.class.registry.at(name)

      refute_nil obj, "#{name} not found in YARD registry"
      assert_predicate obj.tags(:return), :any?, "#{name} must document its @return"
    end
  end
end
