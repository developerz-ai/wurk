# frozen_string_literal: true

# examples/capistrano/wurk.rake
#
# Deploy hooks for Wurk under systemd (examples/wurk.service). Copy to
# lib/capistrano/tasks/wurk.rake; Capistrano loads it from the Capfile's
# `Dir.glob('lib/capistrano/tasks/*.rake')`.
#
#   set :wurk_roles, :worker            # hosts that run workers
#   set :wurk_services, %w[wurk]        # or %w[wurk@1 wurk@2] for a template unit
#   set :wurk_systemctl, %i[sudo systemctl]  # or %i[systemctl --user]
#
# The deploy quiets the old workers as soon as it starts (they finish what they
# hold and fetch nothing new), then restarts them on the new release once it is
# published. A restart is TERM, a drain up to `-t`, and a fresh start: the new
# code only loads in a new process. SIGUSR1 (wurkswarm's rolling restart) forks
# replacements from the running parent, which still holds the old release, so
# it is not a deploy.

namespace :wurk do
  # Runs on the SSHKit host (instance_exec inside `on`), where `execute` lives.
  systemctl = lambda do |*args|
    fetch(:wurk_services, %w[wurk]).each do |service|
      execute(*fetch(:wurk_systemctl, %i[sudo systemctl]), *args, service)
    end
  end

  desc 'Quiet the workers: stop fetching, let in-flight jobs finish (TSTP)'
  task :quiet do
    # Main process only: a wurkswarm parent relays TSTP to its children itself.
    on(roles(fetch(:wurk_roles, :worker))) { instance_exec(:kill, '--signal=TSTP', '--kill-who=main', &systemctl) }
  end

  desc 'Restart the workers on the current release (TERM, drain, start)'
  task :restart do
    on(roles(fetch(:wurk_roles, :worker))) { instance_exec(:restart, &systemctl) }
  end

  desc 'Stop the workers (TERM, drain up to -t)'
  task :stop do
    on(roles(fetch(:wurk_roles, :worker))) { instance_exec(:stop, &systemctl) }
  end

  desc 'Start the workers'
  task :start do
    on(roles(fetch(:wurk_roles, :worker))) { instance_exec(:start, &systemctl) }
  end
end

after 'deploy:starting', 'wurk:quiet'
after 'deploy:published', 'wurk:restart'
after 'deploy:failed', 'wurk:restart'
