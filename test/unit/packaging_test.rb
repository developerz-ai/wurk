# frozen_string_literal: true

require_relative '../test_helper'
require 'rubygems/package'
require 'tmpdir'

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

  def test_concurrent_ruby_is_not_a_direct_runtime_dependency
    refute_includes runtime_dep_names, 'concurrent-ruby'
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

  # The built-in dashboard partials. Wurk::Web::Extension::Action::BUILTIN_VIEWS
  # resolves them by name at render time, so a gem that ships neither raises
  # "extension <name> has no view _paging" in the consumer's app — the docs
  # advertise `erb :_paging` / `erb :_job_info` as built in.
  BUILTIN_PARTIALS = %w[
    lib/wurk/web/views/_paging.erb
    lib/wurk/web/views/_job_info.erb
  ].freeze

  # The gemspec's file list is the first half of the contract: the partials
  # must be NAMED there, not merely present on disk in a source checkout.
  def test_gemspec_files_include_the_builtin_erb_partials
    missing = BUILTIN_PARTIALS - GEMSPEC.files

    assert_empty missing,
                 "missing from the gemspec's file list: #{missing.join(', ')} — the built " \
                 'gem ships without them and `erb :_paging` / `erb :_job_info` raise ' \
                 '"extension <name> has no view _paging" in the consumer\'s app.'
  end

  # The second half, and the one that actually pins the regression: the
  # BUILT gem's file list. A source checkout has the partials on disk, so
  # only the packaged artifact proves they ship.
  def test_built_gem_ships_the_builtin_erb_partials
    missing = BUILTIN_PARTIALS - built_gem_contents

    assert_empty missing,
                 "missing from the built gem: #{missing.join(', ')} — the installed gem " \
                 'raises "extension <name> has no view _paging" for the built-in partials.'
  end

  # The lookup directory the runtime actually reads: the partials must be
  # readable THERE, so the advertised `erb :_paging` / `erb :_job_info` resolve
  # from an installed gem and not only from this checkout.
  def test_builtin_views_dir_holds_readable_erb_partials
    views = Wurk::Web::Extension::Action::BUILTIN_VIEWS

    BUILTIN_PARTIALS.each do |path|
      partial = File.join(views, File.basename(path))

      assert File.file?(partial),
             "#{partial} is missing from the built-in views dir — `erb :_paging` / " \
             '`erb :_job_info` raise "extension <name> has no view _paging".'
      refute_empty File.read(partial)
    end
  end

  private

  # Build the REAL gem from wurk.gemspec and return the packaged file list.
  #
  # The build must run with the repo root as the working directory: the
  # gemspec's `spec.files` are repo-root-relative paths, and
  # Gem::Package#add_files reads them with File.lstat relative to the cwd.
  # The .gem itself is written to an absolute path inside a tmpdir, so the
  # build leaves no artifact in the checkout.
  def built_gem_contents
    root = File.expand_path('../..', __dir__)

    Dir.mktmpdir('wurk-gem') do |dir|
      gem_path = File.join(dir, 'wurk-built.gem')

      Dir.chdir(root) do
        spec = Gem::Specification.load('wurk.gemspec')
        with_silent_gem_ui { Gem::Package.build(spec, true, false, gem_path) }
      end

      return Gem::Package.new(gem_path).contents
    end
  end

  # Gem::Package.build narrates through Gem's global UI; swap it for a silent
  # one so the build doesn't spam test output (and doesn't memoize a stream
  # we close).
  def with_silent_gem_ui
    orig = Gem::DefaultUserInteraction.ui
    silent = Gem::SilentUI.new
    Gem::DefaultUserInteraction.ui = silent
    yield
  ensure
    Gem::DefaultUserInteraction.ui = orig
    silent&.close
  end
end
