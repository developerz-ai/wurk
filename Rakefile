# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require_relative 'lib/wurk/version'
require_relative 'tasks/release_helpers'

GEM_ROOT = File.expand_path(__dir__)
FRONTEND_DIR = File.join(GEM_ROOT, 'frontend')
VENDOR_ASSETS_DIR = File.join(GEM_ROOT, 'vendor', 'assets')
DASHBOARD_BUNDLE_DIR = File.join(VENDOR_ASSETS_DIR, 'dashboard')

# --- release:check helpers ---------------------------------------------
# The raising assertions live in tasks/release_helpers.rb (testable, not
# shipped in the gem). Only the clean-tree check stays here — it shells out to
# git and is meaningful only from a working tree. The dashboard bundle is built,
# not committed, so the clean-tree check ignores vendor/. We match "vendor/"
# (not "vendor/assets/") on purpose: if the tracked vendor/assets/dashboard/.keep
# placeholder ever goes missing, vendor/ holds no tracked file and git collapses
# the whole built bundle to a single "?? vendor/" line — which "vendor/assets/"
# wouldn't catch, failing the release on its own build output (see #272 fallout).
def release_tree_clean!
  dirty = `git status --porcelain`.lines.reject { |line| line.include?('vendor/') }
  return if dirty.empty?

  abort "release:check ✗ working tree has uncommitted changes:\n#{dirty.join}"
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList[
    'test/unit/**/*_test.rb',
    'test/integration/**/*_test.rb',
    'test/engine/**/*_test.rb'
  ]
  t.verbose = false
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << 'test' << 'lib'
    t.test_files = FileList['test/unit/**/*_test.rb']
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << 'test' << 'lib'
    t.test_files = FileList['test/integration/**/*_test.rb']
  end

  Rake::TestTask.new(:engine) do |t|
    t.libs << 'test' << 'lib'
    t.test_files = FileList['test/engine/**/*_test.rb']
  end

  Rake::TestTask.new(:parity) do |t|
    t.libs << 'test' << 'lib'
    t.test_files = FileList['test/parity/**/*_test.rb']
    t.description = 'Run Sidekiq parity tests ' \
                    '(independently written oracles ' \
                    'for the documented Sidekiq behaviour, ' \
                    'pinned to the upstream revision in test/parity/.sidekiq_sha)'
  end

  desc 'Run ecosystem gem suites against Wurk (sidekiq-cron, sidekiq-unique-jobs, ...)'
  task :ecosystem do
    sh 'bin/test-ecosystem'
  end

  desc 'Coverage gate: branch coverage on lib/ must stay >= 90%'
  task :coverage do
    ENV['COVERAGE'] = '1'
    Rake::Task['test'].invoke
  end
end

# YARD API docs. Generates into docs/site/api (gitignored) so the pages
# workflow can publish them alongside the static landing page. The whole config
# lives in .yardopts; this task just shells out so `bin/rake yard` works without
# requiring yard/rake/yardoctask at load time (yard is a dev-only dep).
desc 'Generate YARD API docs into docs/site/api (config in .yardopts)'
task :yard do
  sh 'yard', 'doc'
end

namespace :yard do
  desc 'Report public-API doc coverage (undocumented objects)'
  task :stats do
    sh 'yard', 'stats', '--list-undoc'
  end
end

namespace :docs do
  desc 'Generate docs/site/llms-full.txt (single-fetch full docs for AI agents)'
  task :llms_full do
    require_relative 'tasks/llms_full'
    out = WurkDocs::LlmsFull.write(GEM_ROOT)
    puts "wrote #{out}"
  end
end

# `rake bench` is the REGRESSION gate — its output is fed to bin/bench-compare
# to diff head against main, so it may only contain benchmark/ips-shaped, wurk-
# only scripts. Every other bench/*.rb is picked up by the glob automatically,
# so anything that reports in a different shape has to opt out here or it joins
# the gate and bin/bench-compare reads it as a vanished benchmark:
#
#   vs_sidekiq.rb    — comparison against another engine, minutes not seconds,
#                      prints a Markdown table. `rake bench:vs_sidekiq`.
#   command_count.rb — INFO commandstats table plus a per-job budget assertion,
#                      no i/s at all. `rake bench:command_count`.
#   fetch_capped.rb  — prototype fetch-under-a-cap probe for slice 10
#                      (docs/plans/2026/08/07/101-beyond-sidekiq/10-global-
#                      concurrency.md, step 1: "measure first"). It gates
#                      nothing today — there is no real cap to regress against,
#                      only a stand-in Lua slot script — so it stays out of the
#                      regression gate until slice 10 lands a real gate and
#                      decides ship-vs-defer on these numbers. `rake
#                      bench:fetch_capped`.
#   debounce_enqueue.rb — reports what a debounce policy itself costs (a Lua
#                      round trip in place of the plain LPUSH pipeline); the
#                      "no policy" side of that same comparison is already
#                      bench/enqueue.rb, which stays in the gate. There is no
#                      plain-push baseline for the debounce number to regress
#                      against — a whole extra round trip is the policy's
#                      point, not a regression — so it is read, not diffed.
#                      `rake bench:debounce_enqueue`.
BENCH_SCRIPTS = Dir.glob(File.join(GEM_ROOT, 'bench', '*.rb'))
                   .grep_v(%r{/support\.rb\z})
                   .freeze
UNGATED_SCRIPTS = %w[vs_sidekiq.rb command_count.rb fetch_capped.rb debounce_enqueue.rb].freeze
GATE_SCRIPTS = BENCH_SCRIPTS.reject { |s| UNGATED_SCRIPTS.include?(File.basename(s)) }.freeze

desc 'Run the benchmark gate (enqueue, fetch+execute, bulk enqueue, swarm boot, memory)'
task :bench do
  GATE_SCRIPTS.each do |script|
    puts "\n=== #{File.basename(script)} ==="
    sh 'ruby', '-Ilib', script
  end
end

namespace :bench do
  BENCH_SCRIPTS.each do |script|
    name = File.basename(script, '.rb')
    desc "Run bench/#{name}.rb"
    task name do
      sh 'ruby', '-Ilib', script
    end
  end

  # Named "feature disabled" gates for docs/plans/2026/08/07/101-beyond-
  # sidekiq/overview.md slices 06, 09, 10 — see bench/command_count.rb for why
  # these are separate names running the same script today. Each slice's PR
  # narrows its own task to the real off-state once the feature exists; until
  # then this IS that off-state, because there is nothing yet to turn on.
  {
    command_count_tracked_off: '06-job-status-results: untracked worker',
    command_count_policy_off: '09-debounce-throttle: no unique policy set',
    command_count_cap_off: '10-global-concurrency: no cap configured'
  }.each do |name, off_state|
    desc "Command-count gate (#{off_state}) — bench/command_count.rb"
    task name do
      sh 'ruby', '-Ilib', File.join(GEM_ROOT, 'bench', 'command_count.rb')
    end
  end
end

namespace :frontend do
  desc 'Install JS deps for the dashboard'
  task :install do
    sh 'bun', 'install', '--frozen-lockfile', chdir: FRONTEND_DIR
  end

  desc 'Build the SolidJS SPA into vendor/assets/'
  task :build do
    sh 'bun', 'install', '--frozen-lockfile', chdir: FRONTEND_DIR
    sh 'bun', 'run', 'build', chdir: FRONTEND_DIR
    # Vite's --emptyOutDir wipes the tracked .keep; restore it so the dir stays
    # in git and `rake release`'s guard_clean sees a clean tree.
    touch File.join(VENDOR_ASSETS_DIR, 'dashboard', '.keep')
  end

  desc 'Vite dev server (set WURK_VITE_DEV=1 in the dummy to use it)'
  task :dev do
    sh 'bun', 'run', 'dev', chdir: FRONTEND_DIR
  end

  # Build the SPA only when it isn't there yet.
  #
  # The dashboard controller raises when the precompiled index.html is missing,
  # so the engine tests need a bundle on disk. The bundle is built, not
  # committed (.gitignore), which means a *fresh clone* has none and `rake test`
  # died with two errors before running a single engine test. CI never saw it:
  # the workflow runs `rake frontend:build` first. The contributor following
  # CONTRIBUTING step 3 is exactly who hit it.
  #
  # Conditional on purpose. An unconditional prerequisite would re-run the ~4s
  # install+vite build on every `rake test`, including in CI where the workflow
  # has already built it in a separate `bundle exec rake` invocation (so Rake's
  # once-per-run memo doesn't help). Someone changing frontend code still
  # rebuilds explicitly with `rake frontend:build`; this only rescues the
  # "there is nothing at all" case.
  task :ensure_build do # rubocop:disable Rake/Desc
    next if File.exist?(File.join(DASHBOARD_BUNDLE_DIR, 'index.html'))

    puts 'frontend: precompiled SPA missing — building it once (rake frontend:build)'
    Rake::Task['frontend:build'].invoke
  end
end

# Engine tests render the dashboard shell, so they need the built SPA present.
# Attached here rather than inside the TestTask blocks so the dependency reads
# next to the task that satisfies it.
task test: 'frontend:ensure_build' # rubocop:disable Rake/Desc
task 'test:engine' => 'frontend:ensure_build' # rubocop:disable Rake/Desc

namespace :release do
  desc 'Pre-release gate: tag matches version, bundle present, version matches CHANGELOG, clean tree, tests green'
  task :check do
    version = Wurk::VERSION
    puts "release:check — Wurk #{version}"
    ReleaseHelpers.tag_matches_version!(version)
    ReleaseHelpers.dashboard_bundle_present!(DASHBOARD_BUNDLE_DIR)
    ReleaseHelpers.changelog_has_version!(File.read(File.join(GEM_ROOT, 'CHANGELOG.md')), version)
    release_tree_clean!
    puts 'release:check — static checks passed; running tests…'
    Rake::Task['test'].invoke
    puts "release:check ✓ ready to release v#{version}"
  end

  desc 'Build the gem into pkg/ and assert the precompiled dashboard ships inside it'
  task :package do
    version = Wurk::VERSION
    ReleaseHelpers.dashboard_bundle_present!(DASHBOARD_BUNDLE_DIR)
    mkdir_p File.join(GEM_ROOT, 'pkg')
    gem_path = File.join(GEM_ROOT, 'pkg', "wurk-#{version}.gem")
    sh 'gem', 'build', 'wurk.gemspec', '--output', gem_path
    ReleaseHelpers.gem_contains_dashboard!(gem_path)
    puts "release:package ✓ #{File.basename(gem_path)} ships the dashboard bundle"
  end

  desc 'Build frontend, bake into vendor/assets, build the gem, push to RubyGems'
  task full: ['frontend:build', 'build', 'push']
end

desc 'Lint the gem'
task :rubocop do
  sh 'bundle', 'exec', 'rubocop'
end

task default: :test
