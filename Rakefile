# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require_relative "lib/wurk/version"

GEM_ROOT = File.expand_path(__dir__)
FRONTEND_DIR = File.join(GEM_ROOT, "frontend")
VENDOR_ASSETS_DIR = File.join(GEM_ROOT, "vendor", "assets")

# --- release:check helpers ---------------------------------------------
# Each aborts (non-zero exit) with an actionable message so the gate fails
# loudly in CI and locally. The dashboard bundle is built, not committed, so
# the clean-tree check ignores vendor/assets/.
def release_dashboard_bundle_present!
  dir = File.join(VENDOR_ASSETS_DIR, "dashboard")
  index = File.join(dir, "index.html")
  scripts = Dir.glob(File.join(dir, "assets", "*.js"))
  return if File.file?(index) && scripts.any? { |f| File.size(f).positive? }

  abort "release:check ✗ dashboard bundle missing in vendor/assets/dashboard " \
        "(run `bundle exec rake frontend:build` first)"
end

def release_changelog_has_version!(version)
  changelog = File.read(File.join(GEM_ROOT, "CHANGELOG.md"))
  return if changelog.match?(/^## \[#{Regexp.escape(version)}\]/)

  abort "release:check ✗ CHANGELOG.md has no `## [#{version}]` section " \
        "matching Wurk::VERSION"
end

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
  desc "Pre-release gate: dashboard bundle present, version matches CHANGELOG, clean tree, tests green"
  task :check do
    version = Wurk::VERSION
    puts "release:check — Wurk #{version}"
    release_dashboard_bundle_present!
    release_changelog_has_version!(version)
    release_tree_clean!
    puts "release:check — static checks passed; running tests…"
    Rake::Task["test"].invoke
    puts "release:check ✓ ready to release v#{version}"
  end

  desc "Build frontend, bake into vendor/assets, build the gem, push to RubyGems"
  task full: ["frontend:build", "build", "push"]
end

desc "Lint the gem"
task :rubocop do
  sh "bundle", "exec", "rubocop"
end

task default: :test
