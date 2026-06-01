# frozen_string_literal: true

module Demo
  # Always fails with no retries, so it lands in the Dead set on the first
  # attempt — gives the Dead widget signal within seconds of cold start.
  class PoisonJob
    include Wurk::Job

    sidekiq_options retry: 0

    def perform(*)
      raise 'poison: permanent failure'
    end
  end
end
