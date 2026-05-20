# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

GEM_ROOT = File.expand_path(__dir__)
FRONTEND_DIR = File.join(GEM_ROOT, "frontend")
VENDOR_ASSETS_DIR = File.join(GEM_ROOT, "vendor", "assets")

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
  end

  desc "Vite dev server (set WURK_VITE_DEV=1 in the dummy to use it)"
  task :dev do
    sh "npm", "run", "dev", chdir: FRONTEND_DIR
  end
end

namespace :release do
  desc "Build frontend, bake into vendor/assets, build the gem, push to RubyGems"
  task full: ["frontend:build", "build", "push"]
end

desc "Lint the gem"
task :rubocop do
  sh "bundle", "exec", "rubocop"
end

task default: :test
