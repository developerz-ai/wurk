# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'wurk/version'
require_relative '../../tasks/release_helpers'

# The `sidekiq` shim gem is consumed from git, so nothing but its own gemspec
# ties it to a wurk release. It depends on exactly the wurk it was cut with,
# and every doc recipe pins `tag:` to the current release, so a floating
# `main` checkout or a one-sided `bundle update` cannot mix the two.
class ShimPinTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  SHIM = File.join(ROOT, 'ecosystem/sidekiq-shim')
  RECIPE = %r{gem "sidekiq", github: "developerz-ai/wurk",[^\n`]*glob: "ecosystem/sidekiq-shim/\*\.gemspec"}

  def shim_spec
    Dir.chdir(SHIM) { Gem::Specification.load('sidekiq.gemspec') }
  end

  def test_shim_depends_on_exactly_this_wurk
    dep = shim_spec.dependencies.find { |d| d.name == 'wurk' }

    assert dep, 'the shim must depend on wurk'
    assert_equal Gem::Requirement.new("= #{Wurk::VERSION}"), dep.requirement
  end

  # wurk ships `sidekiq` itself; a second provider in the bundle would fight
  # over the binstub.
  def test_shim_ships_no_executable
    assert_empty shim_spec.executables
  end

  def test_every_doc_recipe_pins_the_current_tag
    tag = ReleaseHelpers.git_tag_for(Wurk::VERSION)
    ReleaseHelpers::SHIM_RECIPE_FILES.each do |rel|
      recipes = File.read(File.join(ROOT, rel)).scan(RECIPE)

      refute_empty recipes, "#{rel} is listed as holding the shim recipe but has none"
      recipes.each { |r| assert_includes r, %(tag: "#{tag}"), "#{rel}: #{r}" }
    end
  end

  def test_no_doc_outside_the_list_prints_the_recipe
    docs = Dir.glob(%w[README.md docs/**/*.md docs/site/*.txt ecosystem/**/*.md], base: ROOT)
    holders = docs.reject { |rel| rel.start_with?('docs/plans/', 'docs/changelog/') }
                  .select { |rel| File.read(File.join(ROOT, rel)).match?(RECIPE) }

    assert_equal ReleaseHelpers::SHIM_RECIPE_FILES.sort, holders.sort
  end

  def test_stamp_rewrites_each_recipe_to_the_release_tag
    Dir.mktmpdir do |root|
      ReleaseHelpers::SHIM_RECIPE_FILES.each do |rel|
        FileUtils.mkdir_p(File.join(root, File.dirname(rel)))
        recipe = %(gem "sidekiq", github: "developerz-ai/wurk", tag: "v1.0.0", glob: "ecosystem/sidekiq-shim/*.gemspec")
        File.write(File.join(root, rel), "#{recipe}\n")
      end

      ReleaseHelpers.stamp_shim_recipes!(root, '2.0.0.rc1')

      ReleaseHelpers::SHIM_RECIPE_FILES.each do |rel|
        assert_includes File.read(File.join(root, rel)), 'tag: "v2.0.0-rc1", glob:'
      end
    end
  end
end
