# frozen_string_literal: true

module Wurk
  # Runs each job inside the host's `Rails.application.reloader`, whose executor
  # hooks enable the query cache, reset CurrentAttributes, release the thread's
  # Active Record connection and, in development, reload changed code.
  #
  # Installed as `config[:reloader]` by RailsBoot when the railtie is loaded.
  # `wurk` / `wurkswarm` load the host app with no railtie (see the note at the
  # end of lib/wurk.rb), so Processor also asks `.default` for itself.
  class RailsReloader
    # The source Rails' error reporter tags these failures with. Subscribers
    # filter on the name, so it stays the one a Sidekiq app already matches.
    SOURCE = 'job.sidekiq'

    # @return [RailsReloader, nil] nil unless this process has a Rails
    #   application, which is what keeps a plain Ruby worker free of any per-job
    #   wrapping.
    def self.default
      return unless defined?(::Rails) && ::Rails.respond_to?(:application)

      app = ::Rails.application
      new(app) if app
    end

    def initialize(app)
      @app = app
      # Rails 7.0's reloader takes no keywords.
      takes_source = app.reloader.method(:wrap).parameters.any? { |kind, _| %i[key keyreq keyrest].include?(kind) }
      @wrap_options = takes_source ? { source: SOURCE }.freeze : {}.freeze
      # A host can start embedded workers from an initializer, while the app is
      # still booting and its reloader hooks aren't installed. Those jobs run bare
      # until boot reaches after_initialize. Not `app.initialized?`: a swarm child
      # forked during boot never returns to where Rails would set it.
      @ready = false
      ::ActiveSupport.on_load(:after_initialize, yield: true) { @ready = true }
    end

    def call(&)
      return yield unless @ready

      @app.reloader.wrap(**@wrap_options, &)
    end

    # The default `as_json` walks instance variables, and the Application's never
    # end. Configuration holds this object, so serializing that would overflow too.
    def as_json(*) = {}

    def inspect = "#<#{self.class.name} app=#{@app.class.name}>"
  end
end
