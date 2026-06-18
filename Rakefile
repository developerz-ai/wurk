# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require_relative "lib/wurk/version"
require_relative "tasks/release_helpers"

GEM_ROOT = File.expand_path(__dir__)
FRONTEND_DIR = File.join(GEM_ROOT, "frontend")
VENDOR_ASSETS_DIR = File.join(GEM_ROOT, "vendor", "assets")
DASHBOARD_BUNDLE_DIR = File.join(VENDOR_ASSETS_DIR, "dashboard")

# --- release:check helpers ---------------------------------------------
# The raising assertions live in tasks/release_helpers.rb (testable, not
# shipped in the gem). Only the clean-tree check stays here — it shells out to
# git and is meaningful only from a working tree. The dashboard bundle is built,
# not committed, so the clean-tree check ignores vendor/assets/.
def release_tree_clean!
  dirty = `git status --porcelain`.lines.reject { |line| line.include?("vendor/assets/") }
  return if dirty.empty?

  abort "release:check ✗ working tree has uncommitted changes:\n#{dirty.join}"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList[
    "test/unit/**/*_test.rb",
    "test/integration/**/*_test.rb",
    "test/engine/**/*_test.rb"
  ]
  t.verbose = false
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/unit/**/*_test.rb"]
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/integration/**/*_test.rb"]
  end

  Rake::TestTask.new(:engine) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/engine/**/*_test.rb"]
  end

  Rake::TestTask.new(:parity) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/parity/**/*_test.rb"]
    t.description = "Run Sidekiq parity tests (lifted from upstream, SHA pinned in test/parity/.sidekiq_sha)"
  end

  desc "Run ecosystem gem suites against Wurk (sidekiq-cron, sidekiq-unique-jobs, ...)"
  task :ecosystem do
    sh "bin/test-ecosystem"
  end

  desc "Coverage gate: branch coverage on lib/ must stay >= 90%"
  task :coverage do
    ENV["COVERAGE"] = "1"
    Rake::Task["test"].invoke
  end
end

# YARD API docs. Generates into docs/site/api (gitignored) so the pages
# workflow can publish them alongside the static landing page. The whole config
# lives in .yardopts; this task just shells out so `bin/rake yard` works without
# requiring yard/rake/yardoctask at load time (yard is a dev-only dep).
desc "Generate YARD API docs into docs/site/api (config in .yardopts)"
task :yard do
  sh "yard", "doc"
end

namespace :yard do
  desc "Report public-API doc coverage (undocumented objects)"
  task :stats do
    sh "yard", "stats", "--list-undoc"
  end
end

namespace :docs do
  desc "Generate docs/site/llms-full.txt (single-fetch full docs for AI agents)"
  task :llms_full do
    require_relative "tasks/llms_full"
    out = WurkDocs::LlmsFull.write(GEM_ROOT)
    puts "wrote #{out}"
  end
end

desc "Run all benchmarks (enqueue, fetch+execute, bulk enqueue, swarm boot, memory)"
task :bench do
  Dir.glob(File.join(GEM_ROOT, "bench", "*.rb")).sort.each do |script|
    puts "\n=== #{File.basename(script)} ==="
    sh "ruby", "-Ilib", script
  end
end

namespace :bench do
  Dir.glob(File.join(GEM_ROOT, "bench", "*.rb")).sort.each do |script|
    name = File.basename(script, ".rb")
    desc "Run bench/#{name}.rb"
    task name do
      sh "ruby", "-Ilib", script
    end
  end
end

namespace :frontend do
  desc "Install JS deps for the dashboard"
  task :install do
    sh "npm", "ci", chdir: FRONTEND_DIR
  end

  desc "Build the React SPA into vendor/assets/"
  task :build do
    sh "npm", "ci", chdir: FRONTEND_DIR
    sh "npm", "run", "build", chdir: FRONTEND_DIR
    # Vite's --emptyOutDir wipes the tracked .keep; restore it so the dir stays
    # in git and `rake release`'s guard_clean sees a clean tree.
    touch File.join(VENDOR_ASSETS_DIR, "dashboard", ".keep")
  end

  desc "Vite dev server (set WURK_VITE_DEV=1 in the dummy to use it)"
  task :dev do
    sh "npm", "run", "dev", chdir: FRONTEND_DIR
  end
end

namespace :release do
  desc "Pre-release gate: tag matches version, bundle present, version matches CHANGELOG, clean tree, tests green"
  task :check do
    version = Wurk::VERSION
    puts "release:check — Wurk #{version}"
    ReleaseHelpers.tag_matches_version!(version)
    ReleaseHelpers.dashboard_bundle_present!(DASHBOARD_BUNDLE_DIR)
    ReleaseHelpers.changelog_has_version!(File.read(File.join(GEM_ROOT, "CHANGELOG.md")), version)
    release_tree_clean!
    puts "release:check — static checks passed; running tests…"
    Rake::Task["test"].invoke
    puts "release:check ✓ ready to release v#{version}"
  end

  desc "Build the gem into pkg/ and assert the precompiled dashboard ships inside it"
  task :package do
    version = Wurk::VERSION
    ReleaseHelpers.dashboard_bundle_present!(DASHBOARD_BUNDLE_DIR)
    mkdir_p File.join(GEM_ROOT, "pkg")
    gem_path = File.join(GEM_ROOT, "pkg", "wurk-#{version}.gem")
    sh "gem", "build", "wurk.gemspec", "--output", gem_path
    ReleaseHelpers.gem_contains_dashboard!(gem_path)
    puts "release:package ✓ #{File.basename(gem_path)} ships the dashboard bundle"
  end

  desc "Build frontend, bake into vendor/assets, build the gem, push to RubyGems"
  task full: ["frontend:build", "build", "push"]
end

desc "Lint the gem"
task :rubocop do
  sh "bundle", "exec", "rubocop"
end

task default: :test
