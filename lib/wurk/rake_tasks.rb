# frozen_string_literal: true

require 'rake'

# Wurk's host-facing rake tasks. The railtie loads this file for Rails apps; a
# plain-Ruby app adds `require "wurk/rake_tasks"` to its Rakefile after
# configuring Wurk's Redis connection.
namespace :wurk do
  namespace :import do
    desc 'Import sidekiq-cron schedules as native periodic loops (dry run; APPLY=1 writes)'
    task :cron do
      Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
      require_relative '../wurk'
      require_relative 'import/sidekiq_cron'
      Wurk::Import::SidekiqCron.new.run(apply: ENV['APPLY'] == '1')
    end
  end
end
