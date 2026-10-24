# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/conformance'

# require is idempotent when Rake also supplies these files to its loader.
Dir[File.expand_path('../parity/**/*_test.rb', __dir__)].each { |path| require path }

class ConformanceInventoryTest < Minitest::Test
  def test_inventory_references_loaded_runnable_oracles
    assert CONFORMANCE_INVENTORY.validate_references!
  end
end

CONFORMANCE_INVENTORY = Conformance::Inventory.load(File.join(__dir__, 'cases.yml'))
Conformance.install(CONFORMANCE_INVENTORY)
