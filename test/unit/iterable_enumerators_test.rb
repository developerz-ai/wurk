# frozen_string_literal: true

require_relative '../test_helper'
require 'csv'

# Pins the IterableJob enumerator builders (§6.4) — array / CSV / ActiveRecord
# — used inside #build_enumerator. Cursor parity with Sidekiq: array & CSV use
# the integer index, ActiveRecord uses the record's primary key, and every
# helper yields `[item, cursor]` pairs that resume from `cursor:`.
class IterableEnumeratorsTest < Wurk::Test::UnitCase
  parallelize_me!

  # A minimal AR-relation double: find_each/find_in_batches/in_batches honor
  # `start:` (primary-key cursor) exactly like ActiveRecord, so resume is real.
  Record = Struct.new(:id)

  class FakeRelation
    def initialize(ids)
      @ids = ids
    end

    def count = @ids.size
    def first = Record.new(@ids.first)

    def from(start)
      @ids.select { |i| start.nil? || i >= start }
    end

    def find_each(start: nil, **)
      from(start).each { |i| yield Record.new(i) }
    end

    def find_in_batches(start: nil, batch_size: 100, **)
      from(start).each_slice(batch_size) { |slice| yield slice.map { |i| Record.new(i) } }
    end

    # `of:` is ActiveRecord's in_batches keyword — must keep the name to match.
    def in_batches(start: nil, of: 100, **) # rubocop:disable Naming/MethodParameterName
      from(start).each_slice(of) { |slice| yield FakeRelation.new(slice) }
    end
  end

  # A bare IterableJob whose only override is the required #each_iteration; the
  # enumerator helpers are pure, so no jid/redis state is needed.
  class EnumJob
    include Wurk::IterableJob

    def each_iteration(*); end
  end

  def setup
    super
    @job = EnumJob.new
  end

  # --- array_enumerator -------------------------------------------------

  def test_array_enumerator_yields_item_index_pairs
    assert_equal [['a', 0], ['b', 1], ['c', 2]], @job.array_enumerator(%w[a b c], cursor: nil).to_a
  end

  def test_array_enumerator_resumes_from_cursor
    assert_equal [['c', 2], ['d', 3]], @job.array_enumerator(%w[a b c d], cursor: 2).to_a
  end

  def test_array_enumerator_rejects_non_array
    assert_raises(ArgumentError) { @job.array_enumerator('nope', cursor: nil) }
  end

  # --- csv_enumerator ---------------------------------------------------

  def test_csv_rows_yields_row_index_pairs_and_resumes
    full = collect(@job.csv_enumerator(csv, cursor: nil)) { |row, i| [row['a'], i] }
    resumed = collect(@job.csv_enumerator(csv, cursor: 1)) { |row, i| [row['a'], i] }

    assert_equal [['1', 0], ['3', 1], ['5', 2]], full
    assert_equal [['3', 1], ['5', 2]], resumed
  end

  def test_csv_batches_yields_batch_index_pairs_and_resumes
    rows = "1\n2\n3\n4\n5\n"
    sizes = collect(@job.csv_batches_enumerator(CSV.new(rows), cursor: 1, batch_size: 2)) { |b, i| [b.size, i] }

    assert_equal [[2, 1], [1, 2]], sizes
  end

  def test_csv_enumerator_rejects_non_csv
    assert_raises(ArgumentError) { @job.csv_enumerator('a,b', cursor: nil) }
  end

  # --- active_record_*_enumerator --------------------------------------

  def test_ar_records_enumerator_yields_record_and_pk_and_resumes
    pairs = @job.active_record_records_enumerator(FakeRelation.new([1, 2, 3, 4]), cursor: 3).to_a

    assert_equal [[Record.new(3), 3], [Record.new(4), 4]], pairs
  end

  def test_ar_batches_enumerator_yields_batch_and_first_pk
    pairs = @job.active_record_batches_enumerator(FakeRelation.new([1, 2, 3, 4, 5]), cursor: nil, batch_size: 2).to_a

    assert_equal([2, 2, 1], pairs.map { |batch, _| batch.size })
    assert_equal([1, 3, 5], pairs.map { |_, cur| cur })
  end

  def test_ar_relations_enumerator_yields_relation_and_first_pk
    pairs = @job.active_record_relations_enumerator(FakeRelation.new([10, 20, 30]), cursor: nil, batch_size: 2).to_a

    assert_equal([FakeRelation, FakeRelation], pairs.map { |rel, _| rel.class })
    assert_equal([10, 30], pairs.map { |_, cur| cur })
  end

  # --- drop-in alias ----------------------------------------------------

  def test_iterable_namespace_aliases_resolve
    assert_same Wurk::IterableJob::CsvEnumerator, Sidekiq::Job::Iterable::CsvEnumerator
    assert_same Wurk::IterableJob::ActiveRecordEnumerator, Sidekiq::Job::Iterable::ActiveRecordEnumerator
  end

  private

  def csv
    CSV.new("a,b\n1,2\n3,4\n5,6\n", headers: true)
  end

  # Forces the (possibly lazy) enumerator and maps each [item, cursor] pair.
  def collect(enum, &)
    enum.to_a.map(&)
  end
end
