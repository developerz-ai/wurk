# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/conformance'

# The live ledger-anchor gate (docs/conformance.md, "Pin the ledger anchors"):
# the divergence ledger's **Anchor:** paragraphs against the shipped records.
# It runs inside test:parity, so CI fails when code moves out from under a
# documented anchor instead of leaving a stale pin behind.
class ConformanceLedgerAnchorsTest < Minitest::Test
  def test_ledger_anchor_records_pin_every_documented_anchor
    assert Conformance::Ledger.load(
      ledger: File.join(Conformance::ROOT, Conformance::LEDGER),
      dir: File.join(Conformance::ROOT, 'test/conformance/ledger_anchors')
    ).validate!
  end
end
