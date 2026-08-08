# frozen_string_literal: true

require_relative '../test_helper'

# Guards the gemspec against the "works under Rails, explodes standalone" trap.
#
# wurk requires a few libraries that Ruby has moved OUT of the default gems
# (base64 in 3.4, logger in 3.5). A Rails app pulls them in transitively, so a
# missing runtime dep is invisible in-suite and only blows up for a non-Rails
# consumer at `require "wurk"`. This test pins those deps so a future cleanup
# can't silently drop them again (#237).
class PackagingTest < Wurk::Test::UnitCase
  parallelize_me!

  GEMSPEC = Gem::Specification.load(File.expand_path('../../wurk.gemspec', __dir__))

  # require '<name>' in lib/ → the gem that ships it once it leaves stdlib.
  EXTRACTED_STDLIB = {
    'base64' => 'base64', # left default gems in Ruby 3.4
    'logger' => 'logger'  # bundled gem in Ruby 3.5 (deprecation warnings in 3.4)
  }.freeze

  def runtime_dep_names
    GEMSPEC.runtime_dependencies.map(&:name)
  end

  def test_extracted_stdlib_requires_are_declared_runtime_deps
    libdir = File.expand_path('../../lib', __dir__)
    required = Dir[File.join(libdir, '**', '*.rb')].flat_map do |f|
      File.readlines(f).filter_map { |l| l[/^\s*require\s+['"]([a-z0-9_]+)['"]/, 1] }
    end.uniq

    EXTRACTED_STDLIB.each do |lib, gem_name|
      next unless required.include?(lib)

      assert_includes runtime_dep_names, gem_name,
                      "lib/ requires '#{lib}' but #{gem_name} is not a gemspec runtime " \
                      'dependency — `require "wurk"` will LoadError on a Ruby version ' \
                      "where #{lib} has left the default gems (non-Rails apps, #237)."
    end
  end

  # The whole point is the gem loads with ONLY its declared deps present, not
  # whatever Rails happens to drag in. Assert the two known-risky ones are there.
  def test_base64_and_logger_are_runtime_dependencies
    assert_includes runtime_dep_names, 'base64'
    assert_includes runtime_dep_names, 'logger'
  end
end
